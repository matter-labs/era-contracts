import { PROTOCOL_OPS_MEMORY_LIMIT } from "./constants";
import { runCommand } from "./common";

export async function prepareUpgrade(params: {
  protocolOps: string;
  environment: string;
  bridgehub: string;
  rpcUrl: string;
  deployer: string;
  outputDirectory: string;
}): Promise<void> {
  await runCommand(params.protocolOps, [
    "ecosystem",
    "upgrade-prepare-all",
    "--env",
    params.environment,
    "--bridgehub",
    params.bridgehub,
    "--l1-rpc-url",
    params.rpcUrl,
    "--deployer-address",
    params.deployer,
    "--out",
    params.outputDirectory,
    `--additional-args=--memory-limit=${PROTOCOL_OPS_MEMORY_LIMIT}`,
  ]);
}

export async function broadcastUpgrade(params: {
  protocolOps: string;
  manifestPath: string;
  rpcUrl: string;
  outputPath: string;
  deployer?: string;
  privateKey?: string;
}): Promise<void> {
  const args = [
    "ecosystem",
    "upgrade-broadcast",
    "--manifest",
    params.manifestPath,
    "--l1-rpc-url",
    params.rpcUrl,
    "--out",
    params.outputPath,
  ];
  if (params.privateKey) {
    if (!params.deployer) throw new Error("deployer is required when broadcasting with a private key");
    args.push("--key", `${params.deployer}=${params.privateKey}`, "--skip-unkeyed");
  } else {
    args.push("--unlocked");
  }
  await runCommand(params.protocolOps, args);
}

export async function verifyUpgrade(params: {
  protocolOps: string;
  environment: string;
  ecosystemTomlPath: string;
  rpcUrl: string;
  gatewayRpcUrl: string;
  transactionsLogPath: string;
  zkGovernanceCommit: string;
}): Promise<void> {
  await runCommand(params.protocolOps, [
    "ecosystem",
    "verify-upgrade",
    "--env",
    params.environment,
    "--ecosystem-toml",
    params.ecosystemTomlPath,
    "--l1-rpc-url",
    params.rpcUrl,
    "--gw-rpc-url",
    params.gatewayRpcUrl,
    "--transactions-log",
    params.transactionsLogPath,
    "--zk-governance-commit",
    params.zkGovernanceCommit,
  ]);
}
