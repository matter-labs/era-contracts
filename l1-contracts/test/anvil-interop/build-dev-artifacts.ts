import { spawnSync } from "child_process";
import * as path from "path";

type DevArtifact = {
  contractPath: string;
  reason: string;
};

const ANVIL_INTEROP_DEV_ARTIFACTS: DevArtifact[] = [
  {
    contractPath: "contracts/dev-contracts/test/DummyInteropRecipient.sol",
    reason: "deployed at test runtime via ContractFactory to receive cross-chain interop bundles",
  },
  {
    contractPath: "contracts/dev-contracts/L2ChainAssetHandlerDev.sol",
    reason:
      "installed at the Gateway ChainAssetHandler address so reverse-TBM setup can bump migrationNumber through onlyUpgrader",
  },
  {
    contractPath: "contracts/dev-contracts/L1ChainAssetHandlerDev.sol",
    reason:
      "deployed behind the L1 ChainAssetHandler proxy so reverse-TBM setup can bump migrationNumber through onlyOwner",
  },
  {
    contractPath: "contracts/dev-contracts/TestnetERC20Token.sol",
    reason: "deployed at test runtime to exercise a freshly registered, migrated chain-native asset",
  },
  {
    contractPath: "contracts/dev-contracts/TransparentUpgradeableProxyForHarness.sol",
    reason: "pulls TransparentUpgradeableProxy into forge out/ for the harness proxy-upgrade ABI",
  },
];

function main(): void {
  const l1ContractsDir = path.resolve(__dirname, "../..");
  const contractPaths = ANVIL_INTEROP_DEV_ARTIFACTS.map(({ contractPath }) => contractPath);

  console.log("Building Anvil interop dev artifacts:");
  for (const { contractPath, reason } of ANVIL_INTEROP_DEV_ARTIFACTS) {
    console.log(`- ${contractPath}: ${reason}`);
  }

  const result = spawnSync("forge", ["build", ...contractPaths], {
    cwd: l1ContractsDir,
    stdio: "inherit",
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

main();
