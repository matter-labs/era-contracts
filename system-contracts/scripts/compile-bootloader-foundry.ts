import { execFileSync } from "child_process";
import { readFileSync } from "fs";
import { assertBootloaderHookHelper, BOOTLOADER_LLVM_OPTIONS, BOOTLOADER_VARIANTS } from "./bootloader-compiler";

const sources = BOOTLOADER_VARIANTS.map((name) => `contracts-preprocessed/bootloader/${name}.yul`);
for (const source of sources) {
  assertBootloaderHookHelper(readFileSync(source, "utf8"));
}

// Explicit source paths keep the LLVM option out of unrelated compiler metadata.
execFileSync(
  "forge",
  [
    "build",
    "--zksync",
    "contracts-preprocessed/bootloader/dummy.yul",
    "contracts-preprocessed/bootloader/transfer_test.yul",
  ],
  { stdio: "inherit" }
);
execFileSync("forge", ["build", "--zksync", ...sources, `--zk-llvm-options=${BOOTLOADER_LLVM_OPTIONS}`], {
  stdio: "inherit",
});
