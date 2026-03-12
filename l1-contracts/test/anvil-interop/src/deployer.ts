import { exec } from "child_process";
import { promisify } from "util";
import * as path from "path";
import type { CoreDeployedAddresses, CTMDeployedAddresses } from "./types";
import { parseForgeScriptOutput, ensureDirectoryExists } from "./utils";
import { ANVIL_DEFAULT_ACCOUNT_ADDR } from "./const";
import { runForgeScript } from "./forge";

const execAsync = promisify(exec);

export class ForgeDeployer {
  private rpcUrl: string;
  private privateKey: string;
  private senderAddress: string;
  private projectRoot: string;
  private outputDir: string;

  constructor(rpcUrl: string, privateKey: string) {
    this.rpcUrl = rpcUrl;
    this.privateKey = privateKey;
    this.senderAddress = ANVIL_DEFAULT_ACCOUNT_ADDR;
    this.projectRoot = path.resolve(__dirname, "../../..");
    this.outputDir = path.join(__dirname, "../outputs");
    ensureDirectoryExists(this.outputDir);
  }

  async deployL1Core(): Promise<CoreDeployedAddresses> {
    console.log("📦 Deploying L1 core contracts...");

    const scriptPath = "deploy-scripts/ecosystem/DeployL1CoreContracts.s.sol:DeployL1CoreContractsScript";
    // Use path from l1-contracts root (must start with / for string.concat in script)
    const configPath = "/test/anvil-interop/config/l1-deployment.toml";
    const outputPath = "/test/anvil-interop/outputs/l1-core-output.toml";

    const envVars = {
      L1_CONFIG: configPath,
      L1_OUTPUT: outputPath,
      PERMANENT_VALUES_INPUT: "/test/anvil-interop/config/permanent-values.toml",
      USE_DUMMY_MESSAGE_ROOT: "true",
    };

    // Use runForAnvil() which skips the acceptAdmin() step
    await runForgeScript({
      scriptPath,
      envVars,
      rpcUrl: this.rpcUrl,
      senderAddress: this.senderAddress,
      projectRoot: this.projectRoot,
      sig: "runForAnvil()",
    });

    const fullOutputPath = path.join(this.projectRoot, outputPath);
    const output = parseForgeScriptOutput(fullOutputPath);

    console.log("✅ L1 core contracts deployed");

    // Access nested TOML structure with type assertions
    const deployed = (output.deployed_addresses || {}) as Record<string, unknown>;
    const bridgehub = (deployed.bridgehub || {}) as Record<string, unknown>;
    const bridges = (deployed.bridges || {}) as Record<string, unknown>;

    return {
      bridgehub: bridgehub.bridgehub_proxy_addr as string,
      stateTransitionManager: deployed.state_transition_manager_proxy_addr as string,
      validatorTimelock: deployed.validator_timelock_addr as string,
      l1SharedBridge: bridges.shared_bridge_proxy_addr as string,
      l1NullifierProxy: bridges.l1_nullifier_proxy_addr as string,
      l1NativeTokenVault: deployed.native_token_vault_addr as string,
      l1AssetTracker: bridgehub.l1_asset_tracker_proxy_addr as string,
      l1ERC20Bridge: bridges.erc20_bridge_proxy_addr as string,
      governance: deployed.governance_addr as string,
      transparentProxyAdmin: deployed.transparent_proxy_admin_addr as string,
      blobVersionedHashRetriever: deployed.blob_versioned_hash_retriever_addr as string,
      messageRoot: bridgehub.message_root_proxy_addr as string,
      ctmDeploymentTracker: bridgehub.ctm_deployment_tracker_proxy_addr as string,
      l1ChainAssetHandler: deployed.chain_asset_handler_proxy_addr as string,
      chainRegistrationSender: bridgehub.chain_registration_sender_proxy_addr as string,
    };
  }

  async deployCTM(bridgehubAddr: string): Promise<CTMDeployedAddresses> {
    console.log("📦 Deploying ChainTypeManager...");

    const scriptPath = "deploy-scripts/ctm/DeployCTM.s.sol:DeployCTMScript";
    // Use path from l1-contracts root (must start with / for string.concat in script)
    const configPath = "/test/anvil-interop/config/ctm-deployment.toml";
    const outputPath = "/test/anvil-interop/outputs/ctm-output.toml";
    const permanentValuesPath = "/test/anvil-interop/config/permanent-values.toml";

    const envVars = {
      CTM_CONFIG: configPath,
      CTM_OUTPUT: outputPath,
      PERMANENT_VALUES_INPUT: permanentValuesPath,
    };

    const sig = "runForAnvilTest(address,bool)";
    const args = `${bridgehubAddr} false`;

    await runForgeScript({
      scriptPath,
      envVars,
      rpcUrl: this.rpcUrl,
      senderAddress: this.senderAddress,
      projectRoot: this.projectRoot,
      sig,
      args,
    });

    const fullOutputPath = path.join(this.projectRoot, outputPath);
    const output = parseForgeScriptOutput(fullOutputPath);

    // Access nested TOML structure: deployed_addresses.state_transition.*
    const deployedAddresses = (output.deployed_addresses || {}) as Record<string, unknown>;
    const stateTransition = (deployedAddresses.state_transition || {}) as Record<string, unknown>;

    console.log("✅ ChainTypeManager deployed");

    return {
      chainTypeManager: stateTransition.state_transition_proxy_addr as string,
      chainAdmin: (deployedAddresses.chain_admin || output.chain_admin_addr) as string,
      diamondProxy: (output.diamond_proxy_addr || output.diamond_proxy) as string,
      adminFacet: (stateTransition.admin_facet_addr || output.admin_facet) as string,
      gettersFacet: (stateTransition.getters_facet_addr || output.getters_facet) as string,
      mailboxFacet: (stateTransition.mailbox_facet_addr || output.mailbox_facet) as string,
      executorFacet: (stateTransition.executor_facet_addr || output.executor_facet) as string,
      verifier: (stateTransition.verifier_addr || output.verifier) as string,
      validiumL1DAValidator: (deployedAddresses.validium_l1_da_validator_addr ||
        output.validium_l1da_validator) as string,
      rollupL1DAValidator: (deployedAddresses.rollup_l1_da_validator_addr || output.rollup_l1da_validator) as string,
    };
  }

  async registerCTM(bridgehubAddr: string, ctmAddr: string): Promise<void> {
    console.log("📝 Registering ChainTypeManager with Bridgehub...");

    const scriptPath = "deploy-scripts/ecosystem/RegisterCTM.s.sol:RegisterCTM";
    const sig = "runForTest(address,address)";
    const args = `${bridgehubAddr} ${ctmAddr}`;

    const envVars = {
      BRIDGEHUB_ADDR: bridgehubAddr,
      CTM_ADDR: ctmAddr,
    };

    await runForgeScript({
      scriptPath,
      envVars,
      rpcUrl: this.rpcUrl,
      senderAddress: this.senderAddress,
      projectRoot: this.projectRoot,
      sig,
      args,
    });

    console.log("✅ ChainTypeManager registered");
  }

  async acceptBridgehubAdmin(bridgehubAddr: string): Promise<void> {
    console.log("📝 Accepting Bridgehub admin...");

    // Read the ChainAdminOwnable address from L1 output
    const l1OutputPath = path.join(this.outputDir, "l1-core-output.toml");
    const l1Output = parseForgeScriptOutput(l1OutputPath);
    const deployedAddresses = (l1Output.deployed_addresses || {}) as Record<string, unknown>;
    const chainAdminAddr = deployedAddresses.chain_admin as string;

    if (!chainAdminAddr) {
      throw new Error("ChainAdminOwnable address not found in L1 output");
    }

    // Fund the ChainAdminOwnable address with ETH for gas
    const fundCommand = `cast send ${chainAdminAddr} --value 1ether --rpc-url ${this.rpcUrl} --unlocked --from ${this.senderAddress}`;
    await execAsync(fundCommand, {
      cwd: this.projectRoot,
      maxBuffer: 10 * 1024 * 1024,
    });

    // In Anvil, we can impersonate the ChainAdminOwnable contract to call acceptAdmin()
    const command = `cast send ${bridgehubAddr} "acceptAdmin()" --from ${chainAdminAddr} --rpc-url ${this.rpcUrl} --unlocked`;

    try {
      // eslint-disable-next-line @typescript-eslint/no-unused-vars
      const { stdout, stderr } = await execAsync(command, {
        cwd: this.projectRoot,
        maxBuffer: 10 * 1024 * 1024,
      });

      if (stderr && !stderr.includes("Warning")) {
        console.warn("   Cast stderr:", stderr);
      }

      console.log("✅ Bridgehub admin accepted");
    } catch (error) {
      console.error("❌ Failed to accept Bridgehub admin:", error);
      throw error;
    }
  }
}
