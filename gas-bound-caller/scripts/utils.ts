import * as fs from "fs";

const CANONICAL_BYTECODES_PATH = "./canonical-bytecodes/GasBoundCaller";

export function writeCanonicalArtifact(newBytecode: string) {
  fs.writeFileSync(CANONICAL_BYTECODES_PATH, newBytecode);
}

export function readCanonicalArtifact() {
  return fs.readFileSync(CANONICAL_BYTECODES_PATH).toString();
}
