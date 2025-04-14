function $llvm_AlwaysInline_llvm$_calldatasize() -> size {
    size := calldatasize()
}

function $llvm_AlwaysInline_llvm$_calldatacopy(dstOffset, sourceOffset, truncatedLen) {
    calldatacopy(dstOffset, sourceOffset, truncatedLen)
}

function $llvm_AlwaysInline_llvm$_calldataload(calldataOffset) -> res {
    // EraVM will revert if offset + length overflows uint32
    if lt(calldataOffset, MAX_CALLDATA_OFFSET()) { // in theory we could also copy MAX_CALLDATA_OFFSET slot, but it is unreachable
        res := calldataload(calldataOffset)
    }
}