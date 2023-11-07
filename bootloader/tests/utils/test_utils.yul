

// We're locating the test hooks 'before' the last free slot.
function TEST_HOOK_PTR() -> ret {
    ret := LAST_FREE_SLOT()
}

function TEST_HOOK_PARAMS_OFFSET() -> ret {
    ret := sub(TEST_HOOK_PTR(), mul(5, 32))
}

function setTestHook(hook) {
    mstore(TEST_HOOK_PTR(), unoptimized(hook))
}   

function storeTestHookParam(paramId, value) {
    let offset := add(TEST_HOOK_PARAMS_OFFSET(), mul(32, paramId))
    mstore(offset, unoptimized(value))
}


function testing_log(msg, data) {
    storeTestHookParam(0, nonOptimized(msg))
    storeTestHookParam(1, nonOptimized(data))
    setTestHook(nonOptimized(100))
}

function testing_start(test_name) {
    storeTestHookParam(0, nonOptimized(test_name))
    setTestHook(nonOptimized(104))
}

function testing_assertEq(a, b, message) {
    if iszero(eq(a, b)) {
        storeTestHookParam(0, nonOptimized(a))
        storeTestHookParam(1, nonOptimized(b))
        storeTestHookParam(2, nonOptimized(message))
        setTestHook(nonOptimized(101))
    }
}

function testing_testWillFailWith(message) {
    storeTestHookParam(0, unoptimized(message))
    setTestHook(nonOptimized(102))
}
function testing_totalTests(tests) {
    storeTestHookParam(0, unoptimized(tests))
    setTestHook(nonOptimized(103))
}

// Returns txDataOffset for the index transaction.
function testing_txDataOffset(index) -> txDataOffset {
    let txPtr := add(TX_DESCRIPTION_BEGIN_BYTE(), mul(index, TX_DESCRIPTION_SIZE()))
    txDataOffset := mload(add(txPtr, 0x20))
}
