// hardhat import should be the first import in the file
import type { CompilerPaths } from "./utils";
import {
  spawn,
  compilerLocation,
  prepareCompilerPaths,
  getSolcLocation,
  needsRecompilation,
  setCompilationTime,
} from "./utils";
import * as fs from "fs";
import { Command } from "commander";
import * as _path from "path";

const COMPILER_VERSION = "1.3.18";
const IS_COMPILER_PRE_RELEASE = true;
const CONTRACTS_DIR = "contracts-preprocessed";
const BOOTLOADER_DIR = "bootloader";
const TIMESTAMP_FILE_YUL = "last_compilation_yul.timestamp";
const TIMESTAMP_FILE_BOOTLOADER = "last_compilation_bootloader.timestamp";

export async function compileYul(paths: CompilerPaths, file: string) {
  const solcCompilerPath = await getSolcLocation();

  const zksolcLocation = await compilerLocation(COMPILER_VERSION, IS_COMPILER_PRE_RELEASE);
  await spawn(
    `${zksolcLocation} ${paths.absolutePathSources}/${file} --solc ${solcCompilerPath} --optimization 3 --system-mode --yul --bin --overwrite -o ${paths.absolutePathArtifacts}`
  );
}

export async function compileYulFolder(path: string) {
  const paths = prepareCompilerPaths(path);
  const files: string[] = (await fs.promises.readdir(path)).filter(
    (fn) => fn.endsWith(".yul") && !fn.endsWith(".template.yul")
  );
  for (const file of files) {
    await compileYul(paths, `${file}`);
  }
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("compile yul").description("publish preimages for the L2 contracts");

  program.command("compile-bootloader").action(async () => {
    const timestampFilePath = _path.join(process.cwd(), TIMESTAMP_FILE_BOOTLOADER);
    const folderToCheck = _path.join(process.cwd(), BOOTLOADER_DIR);

    if (needsRecompilation(folderToCheck, timestampFilePath)) {
      console.log("Compilation needed.");
      await compileYulFolder("bootloader/build");
      await compileYulFolder("bootloader/tests");
      setCompilationTime(timestampFilePath);
    } else {
      console.log("Compilation not needed.");
      return;
    }
  });

  program.command("compile-precompiles").action(async () => {
    const timestampFilePath = _path.join(process.cwd(), TIMESTAMP_FILE_YUL);
    const folderToCheck = _path.join(process.cwd(), CONTRACTS_DIR);

    if (needsRecompilation(folderToCheck, timestampFilePath)) {
      console.log("Compilation needed.");
      await compileYulFolder("contracts-preprocessed");
      await compileYulFolder("contracts-preprocessed/precompiles");
      await compileYulFolder("contracts-preprocessed/precompiles/test-contracts");
      setCompilationTime(timestampFilePath);
    } else {
      console.log("Compilation not needed.");
      return;
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
