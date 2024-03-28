// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { program } from "commander";
import { command as facetCuts } from "./facets";
import { command as verifier } from "./verifier";
const COMMANDS = [facetCuts, verifier];

async function main() {
  const ZKSYNC_HOME = process.env.ZKSYNC_HOME;

  if (!ZKSYNC_HOME) {
    throw new Error("Please set $ZKSYNC_HOME to the root of zkSync repo!");
  } else {
    process.chdir(ZKSYNC_HOME);
  }
  program.version("0.1.0").name("upgrade-system").description("set of tools for upgrade l1 part of the system");

  for (const command of COMMANDS) {
    program.addCommand(command);
  }
  await program.parseAsync(process.argv);
}

main().catch((err: Error) => {
  console.error("Error:", err.message || err);
  process.exitCode = 1;
});
