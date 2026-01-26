import { exec } from "child_process";
import { promisify } from "util";
import * as path from "path";
import { JsonRpcProvider, Contract, Wallet } from "ethers";
import type { CoreDeployedAddresses, CTMDeployedAddresses } from "./types";
import { parseForgeScriptOutput, ensureDirectoryExists } from "./utils";

const execAsync = promisify(exec);

export class GatewaySetup {
  private l1RpcUrl: string;
  private privateKey: string;
  private l1Provider: JsonRpcProvider;
  private wallet: Wallet;
  private projectRoot: string;
  private outputDir: string;
  private l1Addresses: CoreDeployedAddresses;
  private ctmAddresses: CTMDeployedAddresses;

  constructor(
    l1RpcUrl: string,
    privateKey: string,
    l1Addresses: CoreDeployedAddresses,
    ctmAddresses: CTMDeployedAddresses
  ) {
    this.l1RpcUrl = l1RpcUrl;
    this.privateKey = privateKey;
    this.l1Provider = new JsonRpcProvider(l1RpcUrl);
    this.wallet = new Wallet(privateKey, this.l1Provider);
    this.projectRoot = path.resolve(__dirname, "../../..");
    this.outputDir = path.join(__dirname, "../outputs");
    this.l1Addresses = l1Addresses;
    this.ctmAddresses = ctmAddresses;
    ensureDirectoryExists(this.outputDir);
  }

  async designateAsGateway(chainId: number): Promise<string> {
    console.log(`🌐 Designating chain ${chainId} as Gateway...`);

    const gatewayCTMAddr = await this.deployGatewayCTM();

    await this.registerGatewayCTM(gatewayCTMAddr);

    await this.initializeGateway(chainId, gatewayCTMAddr);

    console.log(`✅ Chain ${chainId} designated as Gateway`);

    return gatewayCTMAddr;
  }

  async deployGatewayCTM(): Promise<string> {
    console.log("   Deploying Gateway ChainTypeManager...");

    const scriptPath = "deploy-scripts/gateway/DeployGatewayCTM.s.sol:DeployGatewayCTMScript";
    const outputPath = path.join(this.outputDir, "gateway-ctm-output.toml");

    const envVars = {
      GATEWAY_CTM_OUTPUT: outputPath,
      BRIDGEHUB_ADDR: this.l1Addresses.bridgehub,
    };

    await this.runForgeScript(scriptPath, envVars);

    const output = parseForgeScriptOutput(outputPath);

    const gatewayCTMAddr = (output.gateway_ctm_addr || output.gateway_chain_type_manager) as string;

    console.log(`   Gateway CTM deployed at: ${gatewayCTMAddr}`);

    return gatewayCTMAddr;
  }

  async registerGatewayCTM(gatewayCTMAddr: string): Promise<void> {
    console.log("   Registering Gateway CTM with Bridgehub...");

    const bridgehubAbi = [
      "function addStateTransitionManager(address stateTransitionManager) external",
      "function setGatewayChainTypeManager(address gatewayChainTypeManager) external",
    ];

    const bridgehub = new Contract(this.l1Addresses.bridgehub, bridgehubAbi, this.wallet);

    const tx1 = await bridgehub.addStateTransitionManager(gatewayCTMAddr);
    await tx1.wait();

    const tx2 = await bridgehub.setGatewayChainTypeManager(gatewayCTMAddr);
    await tx2.wait();

    console.log("   Gateway CTM registered");
  }

  async initializeGateway(chainId: number, gatewayCTMAddr: string): Promise<void> {
    console.log("   Initializing Gateway chain...");

    const scriptPath = "deploy-scripts/gateway/GatewayPreparation.s.sol:GatewayPreparationScript";
    const outputPath = path.join(this.outputDir, `gateway-preparation-${chainId}.toml`);

    const envVars = {
      GATEWAY_CHAIN_ID: chainId.toString(),
      GATEWAY_CTM_ADDR: gatewayCTMAddr,
      GATEWAY_OUTPUT: outputPath,
      BRIDGEHUB_ADDR: this.l1Addresses.bridgehub,
    };

    await this.runForgeScript(scriptPath, envVars);

    console.log("   Gateway initialized");
  }

  private async runForgeScript(scriptPath: string, envVars: Record<string, string>): Promise<string> {
    const env = {
      ...process.env,
      ...envVars,
    };

    const command = `forge script ${scriptPath} --rpc-url ${this.l1RpcUrl} --private-key ${this.privateKey} --broadcast --legacy`;

    try {
      const { stdout, stderr } = await execAsync(command, {
        cwd: this.projectRoot,
        env,
        maxBuffer: 10 * 1024 * 1024,
      });

      if (stderr && !stderr.includes("Warning")) {
        console.warn("   Forge stderr:", stderr);
      }

      return stdout;
    } catch (error) {
      const err = error as { message?: string; stdout?: string; stderr?: string };
      console.error("❌ Forge script failed:");
      console.error("   Command:", command);
      console.error("   Error:", err.message);
      if (err.stdout) {
        console.error("   Stdout:", err.stdout);
      }
      if (err.stderr) {
        console.error("   Stderr:", err.stderr);
      }
      throw error;
    }
  }
}
