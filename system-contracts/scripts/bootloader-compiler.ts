// Scope this workaround to bootloader compilation. LLVM options are part of
// compiler metadata, so applying it to all system contracts changes their hashes.
export const BOOTLOADER_VARIANTS = ["bootloader_test", "proved_batch", "playground_batch", "gas_test", "fee_estimate"];
export const BOOTLOADER_HOOK_HELPER = "$llvm_NoInline_llvm$_unoptimized";
export const BOOTLOADER_LLVM_OPTIONS = `-force-attribute=${BOOTLOADER_HOOK_HELPER}:optnone`;

export function assertBootloaderHookHelper(source: string): void {
  // LLVM silently ignores an unmatched force-attribute target. Fail before
  // compilation if the helper was renamed or the near-call store was restored.
  if (!source.includes(`function ${BOOTLOADER_HOOK_HELPER}(`)) {
    throw new Error(`Missing bootloader LLVM attribute target: ${BOOTLOADER_HOOK_HELPER}`);
  }
  if (source.includes("function $llvm_NoInline_llvm$_storeVmHookMemory(")) {
    throw new Error("Bootloader hook writes must not run inside a NoInline store helper");
  }
}
