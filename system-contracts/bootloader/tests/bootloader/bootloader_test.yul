function TEST_safeSub() {
    testing_assertEq(safeSub(10, 7, "err"), 3, "Failed to subtract 7")
    testing_assertEq(safeSub(10, 8, "err"), 2, "Failed to subtract 8")
}

function TEST_safeDiv() {
    testing_assertEq(safeDiv(4, 2, "err"), 2, "Simple division")
    testing_assertEq(safeDiv(5, 2, "err"), 2, "Rouding")
    testing_assertEq(safeDiv(5, 3, "err"), 1, "Rouding down")
    testing_assertEq(safeDiv(4, 3, "err"), 1, "Rouding down")
    testing_assertEq(safeDiv(0, 3, "err"), 0, "Rouding down")
}
function TEST_safeDivAssert() {
    testing_testWillFailWith("divByZero")
    safeDiv(4, 0, "divByZero")
}

function TEST_asserts() {
    testing_testWillFailWith("willFail")
    safeSub(10, 12, "willFail")
}

function TEST_safeMul() {
    testing_assertEq(safeMul(4, 2, "err"), 8, "Simple")
    testing_assertEq(safeMul(0, 2, "err"), 0, "With zero")
    testing_assertEq(safeMul(0, 0, "err"), 0, "With zero")
    testing_assertEq(safeMul(2, 0, "err"), 0, "With zero")
}

function TEST_safeMulAssert() {
    testing_testWillFailWith("overflow")
    let left := shl(129, 1)
    testing_log("left", left)
    safeMul(left, left, "overflow")
}

// function TEST_should ignore

function TEST_strLen() {
    testing_assertEq(getStrLen("abcd"), 4, "short string")
    testing_assertEq(getStrLen("00"), 2, "0 filled string")
    testing_assertEq(getStrLen(""), 0, "empty string")
    testing_assertEq(getStrLen("12345678901234567890123456789012"), 32, "max length")
    testing_assertEq(getStrLen("1234567890123456789012345678901234"), 0, "over max length")
}

function TEST_simple_transaction() {
    // We'll test the transaction from 0.json
    let txDataOffset := testing_txDataOffset(0)
    let innerTxDataOffset := add(txDataOffset, 0x20)
    testing_assertEq(getGasPerPubdataByteLimit(innerTxDataOffset), 0xc350, "Invalid pubdata limit")
}
