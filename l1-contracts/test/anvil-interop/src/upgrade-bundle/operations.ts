import { PROTOCOL_OPS_MEMORY_LIMIT } from "./constants";
import { locateProtocolOps, runCommand } from "./process";

export interface PrepareUpgradeOptions {
  environment: string;
  bridgehub: string;
  rpcUrl: string;
  deployer: string;
  outputDirectory: string;
}

export interface BroadcastUpgradeOptions {
  manifestPath: string;
  rpcUrl: string;
  outputPath: string;
  deployer?: string;
  privateKey?: string;
}

export interface VerifyUpgradeOptions {
  environment: string;
  ecosystemTomlPath: string;
  rpcUrl: string;
  gatewayRpcUrl: string;
  transactionsLogPath: string;
  zkGovernanceCommit: string;
}

export class ProtocolOps {
  public constructor(public readonly executable = locateProtocolOps()) {}

  public prepare(options: PrepareUpgradeOptions): Promise<void> {
    return runCommand(this.executable, [
      "ecosystem",
      "upgrade-prepare-all",
      "--env",
      options.environment,
      "--bridgehub",
      options.bridgehub,
      "--l1-rpc-url",
      options.rpcUrl,
      "--deployer-address",
      options.deployer,
      "--out",
      options.outputDirectory,
      `--additional-args=--memory-limit=${PROTOCOL_OPS_MEMORY_LIMIT}`,
    ]);
  }

  public broadcast(options: BroadcastUpgradeOptions): Promise<void> {
    const args = [
      "ecosystem",
      "upgrade-broadcast",
      "--manifest",
      options.manifestPath,
      "--l1-rpc-url",
      options.rpcUrl,
      "--out",
      options.outputPath,
    ];
    if (options.privateKey) {
      if (!options.deployer) throw new Error("deployer is required when broadcasting with a private key");
      args.push("--key", `${options.deployer}=${options.privateKey}`, "--skip-unkeyed");
    } else {
      args.push("--unlocked");
    }
    return runCommand(this.executable, args);
  }

  public verify(options: VerifyUpgradeOptions): Promise<void> {
    return runCommand(this.executable, [
      "ecosystem",
      "verify-upgrade",
      "--env",
      options.environment,
      "--ecosystem-toml",
      options.ecosystemTomlPath,
      "--l1-rpc-url",
      options.rpcUrl,
      "--gw-rpc-url",
      options.gatewayRpcUrl,
      "--transactions-log",
      options.transactionsLogPath,
      "--zk-governance-commit",
      options.zkGovernanceCommit,
    ]);
  }
}
