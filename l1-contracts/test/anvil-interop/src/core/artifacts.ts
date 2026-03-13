/**
 * Low-level artifact loading from forge build output.
 *
 * This module is intentionally dependency-free (no imports from ./contracts or ./utils)
 * to serve as the foundation that both contracts.ts and utils.ts can import from
 * without circular dependencies.
 */
import * as fs from "fs";
import * as path from "path";

const ZKSTACK_OUT_ROOT = path.resolve(__dirname, "../../../../zkstack-out");
const FORGE_OUT_ROOT = path.resolve(__dirname, "../../../../out");

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function loadArtifactFromOut(artifactRelativePath: string): any {
  const artifactPath = path.join(FORGE_OUT_ROOT, artifactRelativePath);
  return JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
}

/**
 * Load an ABI array from compiled artifacts.
 * Prefers zkstack-out/ (committed, ABI-only files) over out/ (forge build output).
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function loadAbiFromOut(artifactRelativePath: string): any[] {
  const zkstackPath = path.join(ZKSTACK_OUT_ROOT, artifactRelativePath);
  if (fs.existsSync(zkstackPath)) {
    return JSON.parse(fs.readFileSync(zkstackPath, "utf-8"));
  }
  return loadArtifactFromOut(artifactRelativePath).abi;
}

/** Load deployed (runtime) bytecode. */
export function loadBytecodeFromOut(artifactRelativePath: string): string {
  const artifact = loadArtifactFromOut(artifactRelativePath);
  return artifact.deployedBytecode?.object || artifact.bytecode?.object || "0x";
}

/** Load creation (init) bytecode — needed for ContractFactory.deploy(). */
export function loadCreationBytecodeFromOut(artifactRelativePath: string): string {
  const artifact = loadArtifactFromOut(artifactRelativePath);
  return artifact.bytecode?.object || "0x";
}
