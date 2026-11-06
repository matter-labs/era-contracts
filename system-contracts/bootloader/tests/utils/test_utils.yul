

// We're locating the test hooks 'before' the last free slot.
function TEST_HOOK_PTR() -> ret {
    ret := LAST_FREE_SLOT()
}

function TEST_HOOK_PARAMS_OFFSET() -> ret {
    ret := sub(TEST_HOOK_PTR(), mul(5, 32))
}

function setTestHook(hook) {
    mstore(TEST_HOOK_PTR(), $llvm_NoInline_llvm$_unoptimized(hook))
}   

function storeTestHookParam(paramId, value) {
    let offset := add(TEST_HOOK_PARAMS_OFFSET(), mul(32, paramId))
    mstore(offset, $llvm_NoInline_llvm$_unoptimized(value))
}


function testing_log(msg, data) {
    storeTestHookParam(0, msg)
    storeTestHookParam(1, data)
    setTestHook(100)
}

function testing_start(test_name) {
    storeTestHookParam(0, test_name)
    setTestHook(104)
}

function testing_assertEq(a, b, message) {
    if iszero(eq(a, b)) {
        storeTestHookParam(0, a)
        storeTestHookParam(1, b)
        storeTestHookParam(2, message)
        setTestHook(101)
    }
}

function testing_testWillFailWith(message) {
    storeTestHookParam(0, $llvm_NoInline_llvm$_unoptimized(message))
    setTestHook(102)
}
function testing_totalTests(tests) {
    storeTestHookParam(0, $llvm_NoInline_llvm$_unoptimized(tests))
    setTestHook(103)
}

// Returns txDataOffset for the index transaction.
function testing_txDataOffset(index) -> txDataOffset {
    let txPtr := add(TX_DESCRIPTION_BEGIN_BYTE(), mul(index, TX_DESCRIPTION_SIZE()))
    txDataOffset := mload(add(txPtr, 0x20))
}
