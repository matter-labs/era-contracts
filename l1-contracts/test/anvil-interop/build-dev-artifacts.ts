import { spawnSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { getSoliditySourceFileName } from "./src/core/contracts";
import { PREDEPLOY_SYSTEM_CONTRACTS } from "./src/core/predeploys";

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
    reason: "installed at the Gateway ChainAssetHandler address to re-enable chain migrations",
  },
  {
    contractPath: "contracts/dev-contracts/L1ChainAssetHandlerDev.sol",
    reason: "deployed behind the L1 ChainAssetHandler proxy to re-enable chain migrations",
  },
  {
    contractPath: "contracts/dev-contracts/TestnetERC20Token.sol",
    reason: "deployed at test runtime to exercise a freshly registered, migrated chain-native asset",
  },
  {
    contractPath: "contracts/dev-contracts/TransparentUpgradeableProxyForHarness.sol",
    reason: "pulls TransparentUpgradeableProxy into forge out/ for the harness proxy-upgrade ABI",
  },
  {
    contractPath: "contracts/interop/L2InteropRootStorage.sol",
    reason: "spec 13 and the live-interop helpers read the imported (root, timestamp) tuple via its ABI",
  },
  {
    contractPath: "contracts/core/interop-fee/L1InteropFeeManager.sol",
    reason: "spec 14 reads the L1 interop fee manager and round-trips a chain's prepaid balance via its ABI",
  },
  {
    contractPath: "contracts/core/message-root/L1MessageRoot.sol",
    reason: "spec 01 reads which chains have interop enabled via its ABI",
  },
  {
    contractPath: "contracts/core/chain-registration/ChainRegistrationSender.sol",
    reason: "spec 01 reads the allowed interop peers via its ABI",
  },
  {
    contractPath: "lib/openzeppelin-contracts-v4/contracts/proxy/transparent/ProxyAdmin.sol",
    reason: "spec 14 reads the owner of the CTM's ProxyAdmin, which must also own the interop fee manager",
  },
];

/** The source under `contracts/` of each predeploy, found by its file name, which must be unique. */
function findPredeploySources(l1ContractsDir: string): string[] {
  const pathsByFileName = new Map<string, string[]>();
  const walk = (dir: string): void => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const entryPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(entryPath);
      } else {
        pathsByFileName.set(entry.name, [...(pathsByFileName.get(entry.name) ?? []), entryPath]);
      }
    }
  };
  walk(path.join(l1ContractsDir, "contracts"));
  return PREDEPLOY_SYSTEM_CONTRACTS.map(({ contractName }) => {
    const fileName = getSoliditySourceFileName(contractName);
    const matches = pathsByFileName.get(fileName) ?? [];
    if (matches.length !== 1) {
      throw new Error(`Expected exactly one ${fileName} under contracts/, found ${matches.length}`);
    }
    return path.relative(l1ContractsDir, matches[0]);
  });
}

function main(): void {
  const l1ContractsDir = path.resolve(__dirname, "../..");
  const predeploySources = findPredeploySources(l1ContractsDir);
  const contractPaths = [...ANVIL_INTEROP_DEV_ARTIFACTS.map(({ contractPath }) => contractPath), ...predeploySources];

  console.log("Building Anvil interop dev artifacts:");
  for (const { contractPath, reason } of ANVIL_INTEROP_DEV_ARTIFACTS) {
    console.log(`- ${contractPath}: ${reason}`);
  }
  console.log(`- ${predeploySources.length} predeploy sources: spec 01 holds each predeploy's code against out/`);

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
