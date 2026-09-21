import * as hre from "hardhat";
import "@matterlabs/hardhat-zksync-solc";
import assert from "assert";
import { readFileSync } from "fs";
import { execFileSync } from "child_process";

const source = readFileSync("bootloader/bootloader.yul", "utf8");
// LLVM silently ignores an unmatched target; runtime tests additionally prove effectiveness.
const helper = "$llvm_NoInline_llvm$_unoptimized";
const options = [`-force-attribute=${helper}:optnone`];
assert(source.includes(`function ${helper}(`), "Missing LLVM attribute target");
assert(!source.includes("function $llvm_NoInline_llvm$_storeVmHookMemory("), "Hook store must stay in caller");
assert.deepStrictEqual((hre.config.zksolc.settings as { llvmOptions?: string[] }).llvmOptions, options);
for (const profile of ["default", "test"]) {
  const foundry = JSON.parse(
    execFileSync("forge", ["config", "--json"], {
      encoding: "utf8",
      env: { ...process.env, FOUNDRY_PROFILE: profile },
    })
  );
  assert.deepStrictEqual(foundry.zksync.llvm_options, options);
}
console.log("Bootloader helper and normal compiler configurations agree");
