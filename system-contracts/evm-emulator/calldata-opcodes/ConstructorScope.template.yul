function $llvm_AlwaysInline_llvm$_calldatasize() -> size {
    size := 0
}

function $llvm_AlwaysInline_llvm$_calldatacopy(dstOffset, sourceOffset, truncatedLen) {
    $llvm_AlwaysInline_llvm$_memsetToZero(dstOffset, truncatedLen)
}

function $llvm_AlwaysInline_llvm$_calldataload(calldataOffset) -> res {
    res := 0
}