import assert from "assert";
import { readFileSync } from "fs";
import { assertBootloaderHookHelper, BOOTLOADER_HOOK_HELPER, BOOTLOADER_LLVM_OPTIONS } from "./bootloader-compiler";

const source = readFileSync("bootloader/bootloader.yul", "utf8");
assert.doesNotThrow(() => assertBootloaderHookHelper(source));
assert.throws(
  () => assertBootloaderHookHelper(source.replace(`function ${BOOTLOADER_HOOK_HELPER}(`, "function renamed(")),
  /Missing bootloader LLVM attribute target/
);
assert.throws(
  () => assertBootloaderHookHelper(`${source}\nfunction $llvm_NoInline_llvm$_storeVmHookMemory() {}`),
  /must not run inside a NoInline store helper/
);
assert.strictEqual(BOOTLOADER_LLVM_OPTIONS, `-force-attribute=${BOOTLOADER_HOOK_HELPER}:optnone`);
console.log("Bootloader compiler configuration checks passed");
