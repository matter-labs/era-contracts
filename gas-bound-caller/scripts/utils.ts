import { ethers } from "ethers";
import * as fs from "fs";
import { utils } from "zksync-ethers";

// This factory should be predeployed on each post-v24 zksync network
export const PREDEPLOYED_CREATE2_ADDRESS = "0x0000000000000000000000000000000000010000";

const CANONICAL_BYTECODES_PATH = "./canonical-bytecodes/GasBoundCaller";

export function writeCanonicalArtifact(newBytecode: string) {
  fs.writeFileSync(CANONICAL_BYTECODES_PATH, newBytecode);
}

export function readCanonicalArtifact() {
  return fs.readFileSync(CANONICAL_BYTECODES_PATH).toString();
}

export interface Create2DeploymentInfo {
  bytecode: string;
  bytecodeHash: string;
  expectedAddress: string;
}

export function getCreate2DeploymentInfo(): Create2DeploymentInfo {
  const bytecode = readCanonicalArtifact();
  const bytecodeHash = ethers.utils.hexlify(utils.hashBytecode(bytecode));
  const expectedAddress = utils.create2Address(
    PREDEPLOYED_CREATE2_ADDRESS,
    bytecodeHash,
    ethers.constants.HashZero,
    "0x"
  );

  return {
    bytecode,
    bytecodeHash,
    expectedAddress,
  };
}
