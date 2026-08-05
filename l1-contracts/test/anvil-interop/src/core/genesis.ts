import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import { SEMVER_MAJOR_OFFSET, SEMVER_MINOR_OFFSET } from "./const";

// src/core → l1-contracts/test/anvil-interop/src/core, so five levels up is the repo root.
const contractsRootDir = path.resolve(__dirname, "../../../../..");

type SemanticVersion = { major: number; minor: number; patch: number };

/**
 * Path of the genesis config that the deploy/upgrade scripts read for this VM flavour.
 * Mirrors `Utils.genesisConfigPath` (deploy-scripts/utils/Utils.sol).
 */
export function genesisConfigPath(isZKsyncOS: boolean): string {
  return path.join(contractsRootDir, "configs", "genesis", isZKsyncOS ? "zksync-os" : "era", "latest.json");
}

/** Semantic protocol version declared by the genesis config — the source of truth. */
export function getGenesisSemanticVersion(isZKsyncOS: boolean): SemanticVersion {
  const genesis = JSON.parse(fs.readFileSync(genesisConfigPath(isZKsyncOS), "utf-8"));
  return genesis.protocol_semantic_version;
}

/**
 * Genesis protocol version packed the way the protocol stores it (see `SemVer.sol`):
 * `patch | minor << 32 | major << 64`.
 *
 * This is the value the v31 upgrade ends up writing on-chain, because
 * `DefaultCoreUpgrade.loadProtocolVersionFromGenesis()` reads the very same config.
 * Deriving it here keeps the tests correct across version bumps — e.g. a patch bump
 * for regenerated verifier keys.
 */
export function getGenesisProtocolVersion(isZKsyncOS: boolean): ethers.BigNumber {
  const { major, minor, patch } = getGenesisSemanticVersion(isZKsyncOS);
  return ethers.BigNumber.from(patch)
    .add(ethers.BigNumber.from(minor).shl(SEMVER_MINOR_OFFSET))
    .add(ethers.BigNumber.from(major).shl(SEMVER_MAJOR_OFFSET));
}

/** Genesis protocol version as the `vMAJOR.MINOR.PATCH` string used to name chain-state dirs. */
export function getGenesisProtocolVersionString(isZKsyncOS: boolean): string {
  const { major, minor, patch } = getGenesisSemanticVersion(isZKsyncOS);
  return `v${major}.${minor}.${patch}`;
}
