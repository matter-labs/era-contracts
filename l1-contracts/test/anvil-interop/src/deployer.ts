import { spawn, exec } from "child_process";
import { promisify } from "util";
import * as path from "path";
import type { CoreDeployedAddresses, CTMDeployedAddresses } from "./types";
import { parseForgeScriptOutput, ensureDirectoryExists } from "./utils";

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
    // First Anvil account address corresponding to the default private key
    this.senderAddress = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    this.projectRoot = path.resolve(__dirname, "../../..");
    this.outputDir = path.join(__dirname, "../outputs");
    ensureDirectoryExists(this.outputDir);
  }

  async deployL1Core(): Promise<CoreDeployedAddresses> {
    console.log("📦 Deploying L1 core contracts...");

    const scriptPath = "deploy-scripts/ecosystem/DeployL1CoreContracts.s.sol:DeployL1CoreContractsScript";
    // Use path from l1-contracts root (must start with / for string.concat in script)
    const configPath = "/scripts/anvil-interop/config/l1-deployment.toml";
    const outputPath = "/scripts/anvil-interop/outputs/l1-core-output.toml";

    const envVars = {
      L1_CONFIG: configPath,
      L1_OUTPUT: outputPath,
      PERMANENT_VALUES_INPUT: "/scripts/anvil-interop/config/permanent-values.toml",
    };

    // Use runForAnvil() which skips the acceptAdmin() step
    await this.runForgeScript(scriptPath, envVars, "runForAnvil()");

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
      l1ERC20Bridge: bridges.erc20_bridge_proxy_addr as string,
      governance: deployed.governance_addr as string,
      transparentProxyAdmin: deployed.transparent_proxy_admin_addr as string,
      blobVersionedHashRetriever: deployed.blob_versioned_hash_retriever_addr as string,
    };
  }

  async deployCTM(bridgehubAddr: string): Promise<CTMDeployedAddresses> {
    console.log("📦 Deploying ChainTypeManager...");

    const scriptPath = "deploy-scripts/ctm/DeployCTM.s.sol:DeployCTMScript";
    // Use path from l1-contracts root (must start with / for string.concat in script)
    const configPath = "/scripts/anvil-interop/config/ctm-deployment.toml";
    const outputPath = "/scripts/anvil-interop/outputs/ctm-output.toml";
    const permanentValuesPath = "/scripts/anvil-interop/config/permanent-values.toml";

    const envVars = {
      CTM_CONFIG: configPath,
      CTM_OUTPUT: outputPath,
      PERMANENT_VALUES_INPUT: permanentValuesPath,
    };

    const sig = "runForTest(address,bool)";
    const args = `${bridgehubAddr} false`;

    await this.runForgeScript(scriptPath, envVars, sig, args);

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

    await this.runForgeScript(scriptPath, envVars, sig, args);

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

  private async runForgeScript(
    scriptPath: string,
    envVars: Record<string, string>,
    sig?: string,
    args?: string
  ): Promise<string> {
    const env = {
      ...process.env,
      ...envVars,
    };

    // Build command arguments array
    const commandArgs = [
      "script",
      scriptPath,
      "--rpc-url",
      this.rpcUrl,
      "--unlocked",
      "--sender",
      this.senderAddress,
      "--broadcast",
      "--slow", // Send transactions one at a time to avoid overwhelming Anvil
      "--legacy",
      "--ffi", // Enable FFI for scripts that need to call external commands
      "--sig",
      sig || "runForTest()",
    ];

    if (sig && args) {
      commandArgs.push(...args.split(" "));
    }

    console.log(`   Running: ${scriptPath}`);
    console.log(`   Command: forge ${commandArgs.join(" ")}`);
    console.log("");

    return new Promise((resolve, reject) => {
      const forgeProcess = spawn("forge", commandArgs, {
        cwd: this.projectRoot,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });

      let stdout = "";
      // eslint-disable-next-line @typescript-eslint/no-unused-vars
      let _stderr = "";

      // Stream stdout in real-time
      forgeProcess.stdout.on("data", (data: Buffer) => {
        const text = data.toString();
        stdout += text;
        process.stdout.write(text);
      });

      // Stream stderr in real-time, but filter warnings
      forgeProcess.stderr.on("data", (data: Buffer) => {
        const text = data.toString();
        _stderr += text;
        // Only show non-warning stderr
        const lines = text.split("\n");
        const nonWarningLines = lines.filter((line: string) => !line.includes("Warning"));
        if (nonWarningLines.length > 0 && nonWarningLines.join("").trim()) {
          process.stderr.write(nonWarningLines.join("\n") + "\n");
        }
      });

      forgeProcess.on("close", (code: number) => {
        console.log("");
        if (code === 0) {
          console.log("✅ Script completed successfully");
          resolve(stdout);
        } else {
          console.error(`❌ Forge script failed with exit code ${code}`);
          reject(new Error(`Forge script exited with code ${code}`));
        }
      });

      forgeProcess.on("error", (error: Error) => {
        console.error("❌ Failed to spawn forge process:", error.message);
        reject(error);
      });
    });
  }
}
