// hardhat import should be the first import in the file
import * as hre from "hardhat";
import { Command } from "commander";
import { readCanonicalArtifact, writeCanonicalArtifact } from "./utils";

async function main() {
  const program = new Command();

  program
    .version("0.1.0")
    .name("check canonical bytecode")
    .description("Checks that the locally built artifacts match the canonical bytecode");

  program.command("check").action(async () => {
    const compiledBytecode = (await hre.artifacts.readArtifact("GasBoundCaller")).bytecode;
    const canonicalBytecode = readCanonicalArtifact();

    if (compiledBytecode.toLocaleLowerCase() != canonicalBytecode.toLocaleLowerCase()) {
      throw new Error("Compiled bytecode is not correct");
    }
  });

  program.command("fix").action(async () => {
    const compiledBytecode = (await hre.artifacts.readArtifact("GasBoundCaller")).bytecode;
    const canonicalBytecode = readCanonicalArtifact();

    if (compiledBytecode.toLocaleLowerCase() != canonicalBytecode.toLocaleLowerCase()) {
      writeCanonicalArtifact(compiledBytecode);
    } else {
      console.log("There is nothing to fix");
    }
  });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });
