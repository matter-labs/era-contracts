/**
 * Low-level artifact loading from forge build output.
 *
 * This module is intentionally dependency-free (no imports from ./contracts or ./utils)
 * to serve as the foundation that both contracts.ts and utils.ts can import from
 * without circular dependencies.
 */
import type { JsonFragment } from "@ethersproject/abi";
import * as fs from "fs";
import * as path from "path";

const ZKSTACK_OUT_ROOT = path.resolve(__dirname, "../../../../zkstack-out");
const FORGE_OUT_ROOT = path.resolve(__dirname, "../../../../out");
// Output of the `registry-deterministic` foundry profile (see l1-contracts/foundry.toml):
// CBOR-metadata-free artifacts that are byte-identical across platforms. The registry-driven
// upgrade runner deploys every codehash-pinned implementation from here so that registries
// generated on one machine verify on any other (macOS regen vs Linux CI).
const FORGE_DETERMINISTIC_OUT_ROOT = path.resolve(__dirname, "../../../../out-registry-deterministic");

interface ForgeArtifact {
  abi: JsonFragment[];
  bytecode?: { object?: string };
  deployedBytecode?: { object?: string };
}

function loadArtifactFromOut(artifactRelativePath: string): ForgeArtifact {
  const artifactPath = path.join(FORGE_OUT_ROOT, artifactRelativePath);
  return JSON.parse(fs.readFileSync(artifactPath, "utf-8")) as ForgeArtifact;
}

/**
 * Load an ABI array from compiled artifacts.
 * Prefers zkstack-out/ (committed, ABI-only files) over out/ (forge build output).
 */
export function loadAbiFromOut(artifactRelativePath: string): JsonFragment[] {
  const zkstackPath = path.join(ZKSTACK_OUT_ROOT, artifactRelativePath);
  if (fs.existsSync(zkstackPath)) {
    const content = JSON.parse(fs.readFileSync(zkstackPath, "utf-8"));
    // zkstack-out files can be either raw ABI arrays or full forge artifacts
    return Array.isArray(content) ? content : content.abi;
  }
  return loadArtifactFromOut(artifactRelativePath).abi;
}

/** Load deployed (runtime) bytecode. */
export function loadBytecodeFromOut(artifactRelativePath: string): string {
  const artifact = loadArtifactFromOut(artifactRelativePath);
  return artifact.deployedBytecode?.object || artifact.bytecode?.object || "0x";
}

/**
 * Load creation (init) bytecode — needed for ContractFactory.deploy().
 *
 * Deployment bytecode always comes from forge build output in out/.
 * zkstack-out intentionally stores ABI-oriented artifacts only.
 */
export function loadCreationBytecodeFromOut(artifactRelativePath: string): string {
  const artifact = loadArtifactFromOut(artifactRelativePath);
  return artifact.bytecode?.object || "0x";
}

function loadArtifactFromDeterministicOut(artifactRelativePath: string): ForgeArtifact {
  const artifactPath = path.join(FORGE_DETERMINISTIC_OUT_ROOT, artifactRelativePath);
  if (!fs.existsSync(artifactPath)) {
    throw new Error(
      `Deterministic artifact not found: ${artifactPath}. ` +
        "Run `FOUNDRY_PROFILE=registry-deterministic forge build <sources>` first " +
        "(the registry upgrade runner does this automatically)."
    );
  }
  return JSON.parse(fs.readFileSync(artifactPath, "utf-8")) as ForgeArtifact;
}

/** Load deployed (runtime) bytecode from the deterministic (CBOR-metadata-free) build. */
export function loadDeterministicBytecodeFromOut(artifactRelativePath: string): string {
  const artifact = loadArtifactFromDeterministicOut(artifactRelativePath);
  return artifact.deployedBytecode?.object || artifact.bytecode?.object || "0x";
}

/** Load creation (init) bytecode from the deterministic (CBOR-metadata-free) build. */
export function loadDeterministicCreationBytecodeFromOut(artifactRelativePath: string): string {
  const artifact = loadArtifactFromDeterministicOut(artifactRelativePath);
  return artifact.bytecode?.object || "0x";
}
