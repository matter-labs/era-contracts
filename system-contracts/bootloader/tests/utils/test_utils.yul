

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

function testing_testTransactionWillFailWith(message) {
    storeTestHookParam(0, $llvm_NoInline_llvm$_unoptimized(message))
    setTestHook(105)
}
// Post-execution expectations: test bodies run before the loop, so the runner checks these after.

// Transaction `index` failed with empty returndata: a near-call panic, not a revert.
function testing_expectTxPanic(index) {
    storeTestHookParam(0, $llvm_NoInline_llvm$_unoptimized(index))
    setTestHook(106)
}

// The bootloader sent exactly one such L2->L1 log.
function testing_expectBootloaderLog(key, value) {
    storeTestHookParam(0, $llvm_NoInline_llvm$_unoptimized(key))
    storeTestHookParam(1, $llvm_NoInline_llvm$_unoptimized(value))
    setTestHook(107)
}

// No such log. Unlike `expectNoBootloaderLogKey`, forbids one value under a key another log owns.
function testing_expectNoBootloaderLog(key, value) {
    storeTestHookParam(0, $llvm_NoInline_llvm$_unoptimized(key))
    storeTestHookParam(1, $llvm_NoInline_llvm$_unoptimized(value))
    setTestHook(110)
}

// The bootloader sent this system log; priority-queue accounting leaves the batch this way.
function testing_expectSystemLog(key, value) {
    storeTestHookParam(0, $llvm_NoInline_llvm$_unoptimized(key))
    storeTestHookParam(1, $llvm_NoInline_llvm$_unoptimized(value))
    setTestHook(111)
}

// No bootloader log under this key at all.
function testing_expectNoBootloaderLogKey(key) {
    storeTestHookParam(0, $llvm_NoInline_llvm$_unoptimized(key))
    setTestHook(109)
}

// `account` holds exactly `balance` base token when the batch ends.
function testing_expectBalance(account, balance) {
    storeTestHookParam(0, $llvm_NoInline_llvm$_unoptimized(account))
    storeTestHookParam(1, $llvm_NoInline_llvm$_unoptimized(balance))
    setTestHook(108)
}

function testing_totalTests(tests) {
    storeTestHookParam(0, $llvm_NoInline_llvm$_unoptimized(tests))
    setTestHook(103)
}

// Description slot of the index transaction; its first word is the server-written `txMeta`.
// Out of range would corrupt bootloader memory, hence the assertion.
function testing_txDescriptionPtr(index) -> txPtr {
    txPtr := add(TX_DESCRIPTION_BEGIN_BYTE(), mul(index, TX_DESCRIPTION_SIZE()))
    if iszero(lt(txPtr, TXS_IN_BATCH_LAST_PTR())) {
        assertionError("txDescriptionPtr OOB")
    }
}

// Returns txDataOffset for the index transaction.
function testing_txDataOffset(index) -> txDataOffset {
    txDataOffset := mload(add(testing_txDescriptionPtr(index), 0x20))
}
