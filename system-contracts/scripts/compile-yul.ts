import * as hre from "hardhat";

import { getZksolcUrl, saltFromUrl } from "@matterlabs/hardhat-zksync-solc";
import { spawn as _spawn } from "child_process";
import * as fs from "fs";
import { getCompilersDir } from "hardhat/internal/util/global-dir";
import path from "path";

const COMPILER_VERSION = "1.3.14";
const IS_COMPILER_PRE_RELEASE = false;

async function compilerLocation(): Promise<string> {
  const compilersCache = await getCompilersDir();

  let salt = "";

  if (IS_COMPILER_PRE_RELEASE) {
    // @ts-ignore
    const url = getZksolcUrl("https://github.com/matter-labs/zksolc-prerelease", hre.config.zksolc.version);
    salt = saltFromUrl(url);
  }

  return path.join(compilersCache, "zksolc", `zksolc-v${COMPILER_VERSION}${salt ? "-" : ""}${salt}`);
}

// executes a command in a new shell
// but pipes data to parent's stdout/stderr
export function spawn(command: string) {
  command = command.replace(/\n/g, " ");
  const child = _spawn(command, { stdio: "inherit", shell: true });
  return new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (code) => {
      code == 0 ? resolve(code) : reject(`Child process exited with code ${code}`);
    });
  });
}

export async function compileYul(path: string, files: string[], outputDirName: string | null) {
  if (!files.length) {
    console.log(`No test files provided in folder ${path}.`);
    return;
  }
  const paths = preparePaths(path, files, outputDirName);

  const zksolcLocation = await compilerLocation();
  await spawn(
    `${zksolcLocation} ${paths.absolutePathSources}/${paths.outputDir} --optimization 3 --system-mode --yul --bin --overwrite -o ${paths.absolutePathArtifacts}/${paths.outputDir}`
  );
}

export async function compileYulFolder(path: string) {
  const files: string[] = (await fs.promises.readdir(path)).filter((fn) => fn.endsWith(".yul"));
  for (const file of files) {
    await compileYul(path, [file], `${file}`);
  }
}

function preparePaths(path: string, files: string[], outputDirName: string | null): CompilerPaths {
  const filePaths = files
    .map((val) => {
      return `sources/${val}`;
    })
    .join(" ");
  const currentWorkingDirectory = process.cwd();
  console.log(`Yarn project directory: ${currentWorkingDirectory}`);

  const outputDir = outputDirName || files[0];
  // This script is located in `system-contracts/scripts`, so we get one directory back.
  const absolutePathSources = `${__dirname}/../${path}`;
  const absolutePathArtifacts = `${__dirname}/../${path}/artifacts`;

  return new CompilerPaths(filePaths, outputDir, absolutePathSources, absolutePathArtifacts);
}

class CompilerPaths {
  public filePath: string;
  public outputDir: string;
  public absolutePathSources: string;
  public absolutePathArtifacts: string;
  constructor(filePath: string, outputDir: string, absolutePathSources: string, absolutePathArtifacts: string) {
    this.filePath = filePath;
    this.outputDir = outputDir;
    this.absolutePathSources = absolutePathSources;
    this.absolutePathArtifacts = absolutePathArtifacts;
  }
}

async function main() {
  await compileYulFolder("contracts");
  await compileYulFolder("contracts/precompiles");
  await compileYulFolder("bootloader/build");
  await compileYulFolder("bootloader/tests");
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });
