import { Contract, ethers, providers } from "ethers";
import * as path from "path";
import type { CoreDeployedAddresses, CTMDeployedAddresses } from "../core/types";
import { GatewayDeployer } from "./gateway-deployer";
import { getAbi } from "../core/contracts";
import {
  ETH_TOKEN_ADDRESS,
  L1_CHAIN_ID,
  L2_BRIDGEHUB_ADDR,
  L2_MESSAGE_ROOT_ADDR,
  ANVIL_DEFAULT_ACCOUNT_ADDR,
  SYSTEM_CONTEXT_ADDR,
  L2_BOOTLOADER_ADDR,
} from "../core/const";
import { applyL1ToL2Alias, impersonateAndRun, scanAndRelayPriorityRequests, timeIt } from "../core/utils";
import { encodeNtvAssetId } from "../core/data-encoding";
import { migrateTokenBalanceToGW } from "../helpers/token-balance-migration-helper";
import { prepareMergedToml, prepareGatewayChainConfig } from "../core/toml-handling";
import { runForgeScript } from "../core/forge";

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
      const done = gwTimeIt("verifyGatewayContracts");
      const deployer = new GatewayDeployer(gatewayContext.gwProvider.connection.url, chainId);
      await deployer.verifyGatewayContracts();
      done();
    }

    // Step 2: Transfer bridgehub ownership to Governance contract.
    let done = gwTimeIt("transferBridgehubOwnershipToGovernance");
    await this.transferBridgehubOwnershipToGovernance();
    done();

    // Step 3: Prepare config files for Forge scripts
    prepareMergedToml(this.outputDir);
    prepareGatewayChainConfig(this.outputDir, chainId);

    // Step 4: Register GW as settlement layer on L1 (pure L1 call via Governance)
    done = gwTimeIt("forge: runGovernanceRegisterGateway");
    await this.runForgeGatewayScript("runGovernanceRegisterGateway()");
    done();
    console.log(`   Settlement layer status set for chain ${chainId}`);

    // Step 5: Full gateway registration (includes L1→L2 governance calls)
    if (gatewayContext) {
      // Transfer GW L2Bridgehub ownership from the aliased CTM governance (set during genesis)
      // to the aliased ecosystem governance (used by fullRegistration priority requests).
      // The CTM deploys its own per-chain Governance, but fullRegistration sends calls from
      // the ecosystem Governance contract. Without this transfer, addChainTypeManager etc. fail.
      done = gwTimeIt("transferGwL2BridgehubOwnership");
      await this.transferGwL2BridgehubOwnership(gatewayContext.gwProvider);
      done();

      const startBlock = await this.l1Provider.getBlockNumber();
      done = gwTimeIt("forge: runFullRegistration");
      await this.runForgeGatewayScript("runFullRegistration()");
      done();

      done = gwTimeIt("relay: fullRegistration → GW");
      const latestBlock = await this.l1Provider.getBlockNumber();
      await this.relayPriorityRequestsToGateway(gatewayContext, startBlock + 1, latestBlock);
      done();
    } else {
      done = gwTimeIt("forge: runFullRegistration");
      await this.runForgeGatewayScript("runFullRegistration()");
      done();
    }

    // Step 6: Pre-register chains on GW Bridgehub (before migration relay)
    if (gatewayContext && gwSettledChainIds && gwSettledChainIds.length > 0) {
      done = gwTimeIt("registerChainsOnGateway");
      await this.registerChainsOnGateway(gatewayContext.gwProvider, gwSettledChainIds);
      done();
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
    const scriptPath = "test/foundry/l1/integration/_GatewayPreparationForTests.sol:GatewayPreparationForTests";

    // Paths relative to project root (with leading /)
    const mergedOutputRelative = "/test/anvil-interop/outputs/gateway-merged-output.toml";
    const gwChainConfigRelative = "/test/anvil-interop/outputs/gateway-chain-config.toml";

    const envVars: Record<string, string> = {
      CTM_OUTPUT: mergedOutputRelative,
      GATEWAY_AS_CHAIN_CONFIG: gwChainConfigRelative,
      PERMANENT_VALUES_INPUT: "/test/anvil-interop/config/permanent-values.toml",
    };

    return runForgeScript({
      scriptPath,
      envVars,
      rpcUrl: this.l1RpcUrl,
      senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
      projectRoot: this.projectRoot,
      sig,
      args,
    });
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
      this.l1Bridgehub = new Contract(this.l1Addresses.bridgehub, getAbi("L1Bridgehub"), this.l1Provider);
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
      let done = gwTimeIt(`forge: runPauseAndMigrateChain(${chainId})`);
      await this.runForgeGatewayScript("runPauseAndMigrateChain(uint256)", String(chainId));
      done();

      // Confirm migration on L1
      const latestBlockAfterMigrate = await this.l1Provider.getBlockNumber();
      done = gwTimeIt(`forge: runConfirmMigration(${chainId})`);
      await this.confirmMigrationOnL1(
        this.l1Provider,
        chainId,
        gatewayChainId,
        migrationStartBlock + 1,
        latestBlockAfterMigrate
      );
      done();
    }

    // Phase 2: Relay L1→L2 priority requests to GW chain (sequential — same GW impersonated addresses)
    if (gatewayContext) {
      const done = gwTimeIt("relay: migration → GW (all chains)");
      const latestBlock = await this.l1Provider.getBlockNumber();
      await this.relayPriorityRequestsToGateway(gatewayContext, migrationPhaseStartBlock + 1, latestBlock);
      done();
    }

    // Phase 3: Notify L2 chains about settlement layer change (parallel — different L2 chains)
    {
      const done = gwTimeIt(`notifyL2SettlementLayerChange (${gwSettledChainIds.length} chains, parallel)`);
      await Promise.all(
        gwSettledChainIds
          .filter((chainId) => l2ChainRpcUrls?.has(chainId))
          .map(async (chainId) => {
            const l2Provider = this.getProvider(l2ChainRpcUrls!.get(chainId)!);
            await this.notifyL2SettlementLayerChange(l2Provider, gatewayChainId, chainId);
          })
      );
      done();
    }

    // Phase 4: ETH TBM for each chain (sequential — L1 nonce + GW relay conflicts)
    for (const chainId of gwSettledChainIds) {
      if (l2ChainRpcUrls?.has(chainId) && gatewayContext) {
        const done = gwTimeIt(`ETH TBM chain ${chainId}`);
        const l2Provider = this.getProvider(l2ChainRpcUrls.get(chainId)!);
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
        const contract = new Contract(c.addr, getAbi("Ownable2Step"), l1Provider);
        const currentOwner: string = await contract.owner();

        if (currentOwner.toLowerCase() === governanceAddr.toLowerCase()) {
          console.log(`   ${c.name} owner is already Governance`);
          continue;
        }

        const tx = await contract.connect(govSigner).acceptOwnership({ gasLimit: 500_000 });
        await tx.wait();
        console.log(`   ${c.name} ownership transferred to Governance`);
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
  private async transferGwL2BridgehubOwnership(gwProvider: providers.JsonRpcProvider): Promise<void> {
    const l2Bridgehub = new Contract(L2_BRIDGEHUB_ADDR, getAbi("Ownable2Step"), gwProvider);
    const currentOwner: string = await l2Bridgehub.owner();
    const targetOwner = applyL1ToL2Alias(this.l1Addresses.governance);

    if (currentOwner.toLowerCase() === targetOwner.toLowerCase()) {
      console.log("   GW L2Bridgehub already owned by aliased ecosystem governance");
      return;
    }

    // Step 1: current owner calls transferOwnership(targetOwner)
    await impersonateAndRun(gwProvider, currentOwner, async (signer) => {
      const tx = await l2Bridgehub.connect(signer).transferOwnership(targetOwner, { gasLimit: 500_000 });
      await tx.wait();
    });

    // Step 2: target owner calls acceptOwnership()
    await impersonateAndRun(gwProvider, targetOwner, async (signer) => {
      const tx = await l2Bridgehub.connect(signer).acceptOwnership({ gasLimit: 500_000 });
      await tx.wait();
    });

    console.log(`   GW L2Bridgehub ownership transferred to aliased ecosystem governance (${targetOwner})`);
  }

  /**
   * Register GW-settled chains on the gateway's L2Bridgehub and L2MessageRoot.
   *
   * Pre-registering ensures getZKChain(chainId) != address(0) in forwardedBridgeMint,
   * so IChainTypeManager(ctm).forwardedBridgeMint() is never called (the crash path).
   */
  private async registerChainsOnGateway(gwProvider: providers.JsonRpcProvider, chainIds: number[]): Promise<void> {
    const bridgehub = new Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), gwProvider);
    const messageRoot = new Contract(L2_MESSAGE_ROOT_ADDR, getAbi("L2MessageRoot"), gwProvider);

    // Read the chainAssetHandler address from the L2Bridgehub
    const chainAssetHandlerAddr: string = await bridgehub.chainAssetHandler();

    // Impersonate chainAssetHandler for chain registrations
    await impersonateAndRun(gwProvider, chainAssetHandlerAddr, async (signer) => {
      for (const chainId of chainIds) {
        // Register in L2Bridgehub if not already registered
        const existingAddr: string = await bridgehub.getZKChain(chainId);
        if (existingAddr === ethers.constants.AddressZero) {
          // Create a deterministic fake diamond proxy address for this chain
          const fakeProxy = ethers.utils.getAddress(
            ethers.utils
              .keccak256(ethers.utils.defaultAbiCoder.encode(["string", "uint256"], ["fakeZKChain", chainId]))
              .slice(0, 42)
          );
          // Deploy minimal code at the fake proxy so it's a "contract"
          await gwProvider.send("anvil_setCode", [fakeProxy, "0x00"]);

          const tx = await bridgehub.connect(signer).registerNewZKChain(chainId, fakeProxy, false, {
            gasLimit: 1_000_000,
          });
          await tx.wait();
          console.log(`   Registered chain ${chainId} on GW Bridgehub (proxy: ${fakeProxy})`);
        }

        // Register in L2MessageRoot if not already registered
        const registered: boolean = await messageRoot.chainRegistered(chainId);
        if (!registered) {
          const mrTx = await messageRoot.connect(signer).addNewChain(chainId, 0, {
            gasLimit: 1_000_000,
          });
          await mrTx.wait();
          console.log(`   Registered chain ${chainId} on GW MessageRoot`);
        }
      }
    });
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
    const systemContext = new Contract(SYSTEM_CONTEXT_ADDR, getAbi("SystemContext"), l2Provider);

    const current: ethers.BigNumber = await systemContext.currentSettlementLayerChainId();
    if (current.eq(gwChainId)) {
      console.log(`   Chain ${chainId} already knows settlement layer = ${gwChainId}`);
      return;
    }

    await impersonateAndRun(l2Provider, L2_BOOTLOADER_ADDR, async (signer) => {
      const tx = await systemContext.connect(signer).setSettlementLayerChainId(gwChainId, {
        gasLimit: 1_000_000,
      });
      await tx.wait();
      console.log(`   Notified chain ${chainId}: settlement layer changed to ${gwChainId}`);
    });
  }
}
