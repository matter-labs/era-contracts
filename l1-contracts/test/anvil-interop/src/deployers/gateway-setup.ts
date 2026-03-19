import { Contract, ethers, providers } from "ethers";
import * as path from "path";
import type { CoreDeployedAddresses, CTMDeployedAddresses } from "../core/types";
import { GatewayDeployer } from "./gateway-deployer";
import { getAbi } from "../core/contracts";
import {
  ETH_TOKEN_ADDRESS,
  L1_CHAIN_ID,
  L2_BRIDGEHUB_ADDR,
  ANVIL_DEFAULT_ACCOUNT_ADDR,
  SYSTEM_CONTEXT_ADDR,
} from "../core/const";
import { applyL1ToL2Alias, impersonateAndRun, scanAndRelayPriorityRequests, timeIt } from "../core/utils";
import { encodeNtvAssetId } from "../core/data-encoding";
import { migrateTokenBalanceToGW } from "../helpers/token-balance-migration-helper";
import { setSettlementLayerViaBootloader, transferOwnable2Step } from "../helpers/harness-shims";
import {
  mergeGatewayVoteOutput,
  prepareGatewayChainConfig,
  prepareGatewayVoteConfig,
  prepareMergedToml,
} from "../core/toml-handling";
import { runForgeScript } from "../core/forge";
import {
  ANVIL_INTEROP_GATEWAY_CHAIN_CONFIG_RELATIVE,
  ANVIL_INTEROP_GATEWAY_MERGED_OUTPUT_RELATIVE,
  ANVIL_INTEROP_GATEWAY_SCRIPT_PATH,
  ANVIL_INTEROP_GATEWAY_VOTE_CONFIG_RELATIVE,
  ANVIL_INTEROP_GATEWAY_VOTE_OUTPUT_RELATIVE,
  ANVIL_INTEROP_GATEWAY_VOTE_SCRIPT_PATH,
  ANVIL_INTEROP_PERMANENT_VALUES_RELATIVE,
} from "../core/paths";

const gwTimeIt = (label: string) => timeIt(label, "   ⏱️  [GW]");

interface GatewayContext {
  gwProvider: providers.JsonRpcProvider;
  gwDiamondProxy: string;
}

export class GatewaySetup {
  private l1Addresses: CoreDeployedAddresses;
  private ctmAddresses: CTMDeployedAddresses;
  private l1RpcUrl: string;
  private l1Provider: providers.JsonRpcProvider;
  private projectRoot: string;
  private outputDir: string;
  private providerCache = new Map<string, providers.JsonRpcProvider>();
  private l1Bridgehub?: Contract;
  private readonly l1BridgehubAbi = getAbi("L1Bridgehub");
  private readonly ownable2StepAbi = getAbi("Ownable2Step");
  private readonly systemContextAbi = getAbi("SystemContext");

  constructor(l1RpcUrl: string, l1Addresses: CoreDeployedAddresses, ctmAddresses: CTMDeployedAddresses) {
    this.l1RpcUrl = l1RpcUrl;
    this.l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
    this.l1Addresses = l1Addresses;
    this.ctmAddresses = ctmAddresses;
    this.projectRoot = path.resolve(__dirname, "../../../..");
    this.outputDir = path.join(__dirname, "../../outputs");
  }

  async designateAsGateway(
    chainId: number,
    gwRpcUrl?: string,
    gwSettledChainIds?: number[],
    l2ChainRpcUrls?: Map<number, string>
  ): Promise<string> {
    console.log("🌐 Gateway setup for Anvil test environment...");

    const gatewayCTMAddr = this.ctmAddresses.chainTypeManager;
    const gatewayContext = gwRpcUrl ? await this.createGatewayContext(chainId, gwRpcUrl) : undefined;

    // Step 1: Verify GW chain has all required system contracts
    if (gatewayContext) {
      await this.runTimedStep("verifyGatewayContracts", async () => {
        const deployer = new GatewayDeployer(gatewayContext.gwProvider.connection.url, chainId);
        await deployer.verifyGatewayContracts();
      });
    }

    // Step 2: Transfer bridgehub ownership to Governance contract.
    await this.runTimedStep("transferBridgehubOwnershipToGovernance", async () => {
      await this.transferBridgehubOwnershipToGovernance();
    });

    // Step 3: Prepare config files for Forge scripts
    prepareMergedToml(this.outputDir);
    prepareGatewayChainConfig(this.outputDir, chainId);
    prepareGatewayVoteConfig(this.outputDir, chainId);

    if (gatewayContext) {
      // Step 4: Deploy the gateway-side CTM contracts on the GW chain and merge their
      // output back into the harness config before any governance registration uses it.
      const deploymentStartBlock = await this.l1Provider.getBlockNumber();
      await this.runTimedStep("forge: deployGatewayCTM", async () => {
        await this.runForgeGatewayVoteScript("run(address,uint256)", `${this.l1Addresses.bridgehub} 0`);
      });
      const deploymentLatestBlock = await this.l1Provider.getBlockNumber();
      await this.runTimedStep("relay: deployGatewayCTM → GW", async () => {
        await this.relayPriorityRequestsToGateway(gatewayContext, deploymentStartBlock + 1, deploymentLatestBlock);
      });
      mergeGatewayVoteOutput(this.outputDir);
    }

    // Step 5: Register GW as settlement layer on L1 (pure L1 call via Governance)
    await this.runTimedStep("forge: runGovernanceRegisterGateway", async () => {
      await this.runForgeGatewayScript("runGovernanceRegisterGateway()");
    });
    console.log(`   Settlement layer status set for chain ${chainId}`);

    // Step 6: Full gateway registration (includes L1→L2 governance calls)
    if (gatewayContext) {
      // Transfer GW L2Bridgehub ownership from the aliased CTM governance (set during genesis)
      // to the aliased ecosystem governance (used by fullRegistration priority requests).
      // The CTM deploys its own per-chain Governance, but fullRegistration sends calls from
      // the ecosystem Governance contract. Without this transfer, addChainTypeManager etc. fail.
      await this.runTimedStep("transferGwL2BridgehubOwnership", async () => {
        await this.ensureGwL2BridgehubOwnership(gatewayContext.gwProvider);
      });

      const startBlock = await this.l1Provider.getBlockNumber();
      await this.runTimedStep("forge: runFullRegistration", async () => {
        await this.runForgeGatewayScript("runFullRegistration()");
      });

      const latestBlock = await this.l1Provider.getBlockNumber();
      await this.runTimedStep("relay: fullRegistration → GW", async () => {
        await this.relayPriorityRequestsToGateway(gatewayContext, startBlock + 1, latestBlock);
      });
    } else {
      await this.runTimedStep("forge: runFullRegistration", async () => {
        await this.runForgeGatewayScript("runFullRegistration()");
      });
    }

    // Step 7: Migrate chains to gateway via Forge scripts
    if (gwSettledChainIds && gwSettledChainIds.length > 0) {
      await this.migrateChains(chainId, gwSettledChainIds, gatewayContext, l2ChainRpcUrls);
    }

    console.log(`   Using existing CTM: ${gatewayCTMAddr}`);
    console.log("✅ Gateway setup complete");

    return gatewayCTMAddr;
  }

  /**
   * Run a Forge script function on _GatewayPreparationForTests.
   */
  private async runForgeGatewayScript(sig: string, args?: string): Promise<string> {
    const envVars: Record<string, string> = {
      CTM_OUTPUT: ANVIL_INTEROP_GATEWAY_MERGED_OUTPUT_RELATIVE,
      GATEWAY_AS_CHAIN_CONFIG: ANVIL_INTEROP_GATEWAY_CHAIN_CONFIG_RELATIVE,
      PERMANENT_VALUES_INPUT: ANVIL_INTEROP_PERMANENT_VALUES_RELATIVE,
    };

    return runForgeScript({
      scriptPath: ANVIL_INTEROP_GATEWAY_SCRIPT_PATH,
      envVars,
      rpcUrl: this.l1RpcUrl,
      senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
      projectRoot: this.projectRoot,
      sig,
      args,
    });
  }

  private async runForgeGatewayVoteScript(sig: string, args?: string): Promise<string> {
    const envVars: Record<string, string> = {
      GATEWAY_VOTE_PREPARATION_INPUT: ANVIL_INTEROP_GATEWAY_VOTE_CONFIG_RELATIVE,
      GATEWAY_VOTE_PREPARATION_OUTPUT: ANVIL_INTEROP_GATEWAY_VOTE_OUTPUT_RELATIVE,
      PERMANENT_VALUES_INPUT: ANVIL_INTEROP_PERMANENT_VALUES_RELATIVE,
    };

    return runForgeScript({
      scriptPath: ANVIL_INTEROP_GATEWAY_VOTE_SCRIPT_PATH,
      envVars,
      rpcUrl: this.l1RpcUrl,
      senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
      projectRoot: this.projectRoot,
      sig,
      args,
    });
  }

  private async runTimedStep(label: string, fn: () => Promise<void>): Promise<void> {
    const done = gwTimeIt(label);
    await fn();
    done();
  }

  private getProvider(rpcUrl: string): providers.JsonRpcProvider {
    let provider = this.providerCache.get(rpcUrl);
    if (!provider) {
      provider = new providers.JsonRpcProvider(rpcUrl);
      this.providerCache.set(rpcUrl, provider);
    }
    return provider;
  }

  private getL1Bridgehub(): Contract {
    if (!this.l1Bridgehub) {
      this.l1Bridgehub = new Contract(this.l1Addresses.bridgehub, this.l1BridgehubAbi, this.l1Provider);
    }
    return this.l1Bridgehub;
  }

  private async getGwDiamondProxy(chainId: number): Promise<string> {
    return this.getL1Bridgehub().getZKChain(chainId);
  }

  private async createGatewayContext(chainId: number, gwRpcUrl: string): Promise<GatewayContext> {
    const gwProvider = this.getProvider(gwRpcUrl);
    const gwDiamondProxy = await this.getGwDiamondProxy(chainId);
    console.log(`   GW diamond proxy on L1: ${gwDiamondProxy}`);
    return { gwProvider, gwDiamondProxy };
  }

  private async relayPriorityRequestsToGateway(
    gatewayContext: GatewayContext,
    fromBlock: number,
    toBlock: number
  ): Promise<void> {
    await scanAndRelayPriorityRequests(
      this.l1Provider,
      gatewayContext.gwDiamondProxy,
      gatewayContext.gwProvider,
      fromBlock,
      toBlock,
      (line) => console.log(line)
    );
  }

  /**
   * Migrate chains to gateway using Forge scripts + L1→L2 relay.
   *
   * Structured in phases to maximize parallelism:
   * Phase 1 (L1, sequential): Forge scripts for pause+migrate and confirm for each chain
   * Phase 2 (GW, sequential): Relay L1→L2 priority requests to GW chain
   * Phase 3 (L2, parallel): Notify L2 chains about settlement layer change
   * Phase 4 (mixed, sequential): ETH TBM for each chain (L1 nonce shared)
   */
  private async migrateChains(
    gatewayChainId: number,
    gwSettledChainIds: number[],
    gatewayContext?: GatewayContext,
    l2ChainRpcUrls?: Map<number, string>
  ): Promise<void> {
    const l1Bridgehub = this.getL1Bridgehub();
    const migrationPhaseStartBlock = await this.l1Provider.getBlockNumber();

    // Phase 1: All L1 forge scripts (sequential — shared L1 nonce)
    for (const chainId of gwSettledChainIds) {
      console.log(`   Migrating chain ${chainId} to gateway...`);

      // Run forge script: pause deposits + initiate migration.
      const migrationStartBlock = await this.l1Provider.getBlockNumber();
      await this.runTimedStep(`forge: runPauseAndMigrateChain(${chainId})`, async () => {
        await this.runForgeGatewayScript("runPauseAndMigrateChain(uint256)", String(chainId));
      });

      // Confirm migration on L1
      const latestBlockAfterMigrate = await this.l1Provider.getBlockNumber();
      await this.runTimedStep(`forge: runConfirmMigration(${chainId})`, async () => {
        await this.confirmMigrationOnL1(
          this.l1Provider,
          chainId,
          gatewayChainId,
          migrationStartBlock + 1,
          latestBlockAfterMigrate
        );
      });
    }

    // Phase 2: Relay L1→L2 priority requests to GW chain (sequential — same GW impersonated addresses)
    if (gatewayContext) {
      const latestBlock = await this.l1Provider.getBlockNumber();
      await this.runTimedStep("relay: migration → GW (all chains)", async () => {
        await this.relayPriorityRequestsToGateway(gatewayContext, migrationPhaseStartBlock + 1, latestBlock);
      });
    }

    // Phase 3: Notify L2 chains about settlement layer change (parallel — different L2 chains)
    await this.runTimedStep(
      `notifyL2SettlementLayerChange (${gwSettledChainIds.length} chains, parallel)`,
      async () => {
        await Promise.all(
          gwSettledChainIds
            .filter((chainId) => l2ChainRpcUrls?.has(chainId))
            .map(async (chainId) => {
              const l2Provider = this.getProvider(l2ChainRpcUrls!.get(chainId)!);
              await this.notifyL2SettlementLayerChange(l2Provider, gatewayChainId, chainId);
            })
        );
      }
    );

    // Phase 4: ETH TBM for each chain (sequential — L1 nonce + GW relay conflicts)
    for (const chainId of gwSettledChainIds) {
      if (l2ChainRpcUrls?.has(chainId) && gatewayContext) {
        await this.runEthTbmForChain(chainId, l2ChainRpcUrls.get(chainId)!, gatewayContext, l1Bridgehub);
      }
    }
  }

  /**
   * Confirm migration on L1 after the forge script has broadcasted the migration initiation.
   *
   * The forge script's `runPauseAndMigrateChain` calls `requestL2TransactionTwoBridges` which
   * sets `isMigrationInProgress[chainId] = true`. We need to call `bridgeConfirmTransferResult`
   * to clear it. The canonical L2 tx hash changes between Forge simulation and broadcast, so
   * the confirmation must happen in a separate forge script invocation.
   *
   * We find the actual on-chain canonical tx hash from the `BridgehubDepositFinalized` event
   * emitted by the L1Nullifier, then pass it to the `runConfirmMigration` forge script.
   */
  private async confirmMigrationOnL1(
    l1Provider: providers.JsonRpcProvider,
    chainId: number,
    gatewayChainId: number,
    fromBlock: number,
    toBlock: number
  ): Promise<void> {
    // Find the BridgehubDepositFinalized event to get the canonical L2 tx hash.
    // All three event params are indexed (in topics, not data):
    //   topics[0] = event sig, topics[1] = chainId, topics[2] = txDataHash, topics[3] = l2DepositTxHash
    const depositFinalizedSig = ethers.utils.id("BridgehubDepositFinalized(uint256,bytes32,bytes32)");
    const gatewayChainIdTopic = ethers.utils.hexZeroPad(ethers.utils.hexlify(gatewayChainId), 32);

    const logs = await l1Provider.getLogs({
      address: this.l1Addresses.l1NullifierProxy,
      topics: [depositFinalizedSig, gatewayChainIdTopic],
      fromBlock,
      toBlock,
    });

    if (logs.length === 0) {
      throw new Error(
        `No BridgehubDepositFinalized event found for gateway chain ${gatewayChainId} in blocks [${fromBlock}, ${toBlock}]`
      );
    }

    // Use the last event (most recent migration). Canonical tx hash is topics[3].
    const lastLog = logs[logs.length - 1];
    const canonicalTxHash = lastLog.topics[3];

    console.log(`   Found BridgehubDepositFinalized: canonicalTxHash = ${canonicalTxHash}`);

    // Call forge script to confirm migration using the actual on-chain canonical tx hash
    await this.runForgeGatewayScript("runConfirmMigration(uint256,bytes32)", `${chainId} ${canonicalTxHash}`);
  }

  /**
   * Transfer bridgehub ownership to the Governance contract.
   *
   * DeployL1CoreContracts.updateOwners() calls bridgehub.transferOwnership(governance)
   * which sets pendingOwner = governance. We impersonate the Governance contract on
   * Anvil and call acceptOwnership() to finalize the transfer.
   *
   * This is needed because Utils.executeCalls() calls IOwnable(governor).owner() → EOA,
   * then IGovernance(governor).scheduleTransparent() + execute(). It expects the governor
   * to be a Governance contract, not an EOA.
   */
  private async transferBridgehubOwnershipToGovernance(): Promise<void> {
    const l1Provider = this.l1Provider;
    const governanceAddr = this.l1Addresses.governance;
    // Contracts that need ownership transfer for the gateway setup flow.
    // DeployL1CoreContracts.updateOwners() calls transferOwnership(governance)
    // on all of these, setting pendingOwner. We accept to finalize.
    const contracts = [
      { name: "Bridgehub", addr: this.l1Addresses.bridgehub },
      { name: "L1AssetRouter", addr: this.l1Addresses.l1SharedBridge },
      { name: "CTMDeploymentTracker", addr: this.l1Addresses.ctmDeploymentTracker },
    ];

    await impersonateAndRun(l1Provider, governanceAddr, async (govSigner) => {
      for (const c of contracts) {
        const contract = new Contract(c.addr, this.ownable2StepAbi, l1Provider);
        await this.ensureGovernanceOwnership(contract, c.name, governanceAddr, govSigner);
      }
    });
  }

  /**
   * Transfer GW L2Bridgehub ownership from the aliased CTM governance to the aliased
   * ecosystem governance.
   *
   * The CTM deployment creates a per-chain Governance contract whose aliased address
   * becomes the L2Bridgehub owner during genesis. But fullRegistration sends priority
   * requests from the ecosystem Governance, so L2Bridgehub ownership must match.
   */
  private async ensureGwL2BridgehubOwnership(gwProvider: providers.JsonRpcProvider): Promise<void> {
    const l2Bridgehub = new Contract(L2_BRIDGEHUB_ADDR, this.ownable2StepAbi, gwProvider);
    const currentOwner: string = await l2Bridgehub.owner();
    const targetOwner = applyL1ToL2Alias(this.l1Addresses.governance);

    if (currentOwner.toLowerCase() === targetOwner.toLowerCase()) {
      console.log("   GW L2Bridgehub already owned by aliased ecosystem governance");
      return;
    }

    await transferOwnable2Step(gwProvider, L2_BRIDGEHUB_ADDR, this.ownable2StepAbi, currentOwner, targetOwner);

    console.log(`   GW L2Bridgehub ownership transferred to aliased ecosystem governance (${targetOwner})`);
  }

  /**
   * Simulate the bootloader calling SystemContext.setSettlementLayerChainId() on an L2 chain.
   *
   * On a real ZK chain, the bootloader does this at the start of each batch after migration.
   * This call propagates to L2ChainAssetHandler.setSettlementLayerChainId(), which increments
   * migrationNumber[block.chainid] — required for TBM's initiateL1ToGatewayMigrationOnL2 to
   * emit an L2→L1 message instead of early-returning.
   */
  private async notifyL2SettlementLayerChange(
    l2Provider: providers.JsonRpcProvider,
    gwChainId: number,
    chainId: number
  ): Promise<void> {
    const systemContext = new Contract(SYSTEM_CONTEXT_ADDR, this.systemContextAbi, l2Provider);

    const current: ethers.BigNumber = await systemContext.currentSettlementLayerChainId();
    if (current.eq(gwChainId)) {
      console.log(`   Chain ${chainId} already knows settlement layer = ${gwChainId}`);
      return;
    }

    await setSettlementLayerViaBootloader({
      provider: l2Provider,
      settlementLayerChainId: gwChainId,
    });
    console.log(`   Notified chain ${chainId}: settlement layer changed to ${gwChainId}`);
  }

  private async ensureGovernanceOwnership(
    contract: Contract,
    contractName: string,
    governanceAddr: string,
    govSigner: providers.JsonRpcSigner
  ): Promise<void> {
    const currentOwner: string = await contract.owner();
    if (currentOwner.toLowerCase() === governanceAddr.toLowerCase()) {
      console.log(`   ${contractName} owner is already Governance`);
      return;
    }
    const tx = await contract.connect(govSigner).acceptOwnership({ gasLimit: 500_000 });
    await tx.wait();
    console.log(`   ${contractName} ownership transferred to Governance`);
  }

  private async runEthTbmForChain(
    chainId: number,
    l2RpcUrl: string,
    gatewayContext: GatewayContext,
    l1Bridgehub: Contract
  ): Promise<void> {
    const done = gwTimeIt(`ETH TBM chain ${chainId}`);
    const l2Provider = this.getProvider(l2RpcUrl);
    const ethAssetId = encodeNtvAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);
    const l2DiamondProxy: string = await l1Bridgehub.getZKChain(chainId);
    console.log(`   Running real TBM for ETH on chain ${chainId}...`);
    await migrateTokenBalanceToGW({
      l2Provider,
      l1Provider: this.l1Provider,
      gwProvider: gatewayContext.gwProvider,
      chainId,
      assetId: ethAssetId,
      l1AssetTrackerAddr: this.l1Addresses.l1AssetTracker,
      gwDiamondProxyAddr: gatewayContext.gwDiamondProxy,
      l2DiamondProxyAddr: l2DiamondProxy,
      logger: (line) => console.log(line),
    });
    console.log(`   ETH TBM complete for chain ${chainId}`);
    done();
  }
}
