 function TEST_safeSub() {
     testing_assertEq(safeSub(10, 7, "err"), 3, "Failed to subtract 7")
     testing_assertEq(safeSub(10, 8, "err"), 2, "Failed to subtract 8")
 }

 function TEST_safeDiv() {
     testing_assertEq(safeDiv(4, 2, "err"), 2, "Simple division")
     testing_assertEq(safeDiv(5, 2, "err"), 2, "Rounding")
     testing_assertEq(safeDiv(5, 3, "err"), 1, "Rounding down")
     testing_assertEq(safeDiv(4, 3, "err"), 1, "Rounding down")
     testing_assertEq(safeDiv(0, 3, "err"), 0, "Rounding down")
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
     testing_assertEq(getGasPerPubdataByteLimit(innerTxDataOffset), 0xC350, "Invalid pubdata limit")
 }

 function TEST_getTransactionUpfrontOverhead() {
     // For very large transactions it should be proportional to the memory,
     // but for small ones, the transaction slots are more important

     let smallTxOverhead := getTransactionUpfrontOverhead(32)
     let largeTxOverhead := getTransactionUpfrontOverhead(1000000)

     testing_assertEq(smallTxOverhead, TX_SLOT_OVERHEAD_GAS(), "Invalid small tx overhead")
     testing_assertEq(largeTxOverhead, mul(1000000, MEMORY_OVERHEAD_GAS()), "Invalid small tx overhead")
 }

 function TEST_getFeeParams_HighPubdataPrice() {
     // Under very large L1 gas price, the L2 base fee will start rising to ensure the
     // boundary on the gasLimit

     // 150k gwei L1 pubdata price
     let veryHighL1PubdataPrice := 150000000000000
     // 0.1 gwei L2 base fee
     let l2GasPrice := 100000000

     let baseFee, gasPricePerPubdata := getFeeParams(
         veryHighL1PubdataPrice,
         // 0.1 gwei L2 base fee
         l2GasPrice
     )

     testing_assertEq(baseFee, ceilDiv(veryHighL1PubdataPrice, MAX_L2_GAS_PER_PUBDATA()), "Invalid base fee")
     testing_assertEq(gasPricePerPubdata, MAX_L2_GAS_PER_PUBDATA(), "Invalid gasPricePerPubdata")
 }

 function TEST_getFeeParams_LowPubdataPrice() {
     // Under low to medium pubdata price, the baseFee is equal to the fair gas price,
     // while the gas per pubdata pubdata is derived by strict division

     // 0.2 gwei L1 pubdata price
     let veryLowL1GasPrice := 200000000
     // 0.1 gwei L2 base fee
     let l2GasPrice := 100000000

     let baseFee, gasPricePerPubdata := getFeeParams(
         veryLowL1GasPrice,
         l2GasPrice
     )

     testing_assertEq(baseFee, l2GasPrice, "Invalid base fee")
     testing_assertEq(gasPricePerPubdata, div(veryLowL1GasPrice, l2GasPrice), "Invalid gasPricePerPubdata")
 }

 function TEST_systemLogKeys() {
     // Test that the values for various system log keys are correct
     let chainedPriorityTxnHashLogKey := chainedPriorityTxnHashLogKey()
     let numberOfLayer1TxsLogKey := numberOfLayer1TxsLogKey()
     let protocolUpgradeTxHashKey := protocolUpgradeTxHashKey()

     testing_assertEq(chainedPriorityTxnHashLogKey, 5, "Invalid priority txn hash log key")
     testing_assertEq(numberOfLayer1TxsLogKey, 6, "Invalid num layer 1 txns log key")
     testing_assertEq(protocolUpgradeTxHashKey, 13, "Invalid protocol upgrade txn hash log key")
 }

 function TEST_safeAdd() {
     testing_assertEq(safeAdd(1, 2, "Addition with overflow"), 3, "Invalid addition")
 }

 function TEST_safeAddAssert() {
     testing_testWillFailWith("Addition with overflow")
     // We use the max value in 256 bit and then add 1 to make it overflow
     let x := 115792089237316195423570985008687907853269984665640564039457584007913129639935
     let y := 1
     safeAdd(x, y, "Addition with overflow")
 }

 function TEST_saturatingSub() {
     testing_assertEq(saturatingSub(4, 2), 2, "Invalid subtraction")
     testing_assertEq(saturatingSub(2, 4), 0, "Invalid subtraction")
 }

 function TEST_ceilDiv() {
     testing_assertEq(ceilDiv(1, 0), 0, "Dividing by 0")
     testing_assertEq(ceilDiv(0, 1), 0, "Dividing with overflow")
     testing_assertEq(ceilDiv(5, 2), 3, "Invalid division")
     testing_assertEq(ceilDiv(6, 2), 3, "Invalid division")
 }

 function TEST_lengthRoundedByWords() {
     testing_assertEq(lengthRoundedByWords(65), 96, "Invalid word length")
 }

 function TEST_getGasPrice() {
     let baseFee := basefee()
     testing_log("Base Fee", baseFee)
     testing_assertEq(getGasPrice(6, 5), baseFee, "Invalid gas price")
 }

//function TEST_getGasPrice_maxPriorityFeeGreaterThenMaxFee() {
//    testing_testWillFailWith(13)
//    getGasPrice(5, 6)
//}

//function TEST_getGasPrice_baseFeeGreaterThenMaxFee() {
//    testing_testWillFailWith("Base fee greater than max fee")
//    let baseFee := basefee()
//    getGasPrice(baseFee, baseFee)
//}

function TEST_getOperatorRefundForTx() {
    let transactionIndex := 10

    let expected := 3872

    testing_assertEq(getOperatorRefundForTx(transactionIndex), mload(expected), "Invalid refound for tx")
}

function TEST_getOperatorOverheadForTx() {
    let transactionIndex := 10

    let expected := 323872

    testing_assertEq(getOperatorOverheadForTx(transactionIndex), mload(expected), "Invalid operator overhead for tx")
}

function TEST_getOperatorTrustedGasLimitForTx() {
    let transactionIndex := 10

    let expected := 643872

    assertEq(getOperatorTrustedGasLimitForTx(transactionIndex), mload(expected), "Invalid trusted gas limit for tx")
}

function TEST_getCurrentCompressedBytecodeHash() {
    let pointer := mload(COMPRESSED_BYTECODES_BEGIN_BYTE())
    let expected := add(COMPRESSED_BYTECODES_BEGIN_BYTE(), pointer)

    testing_assertEq(getCurrentCompressedBytecodeHash(), mload(expected), "Invalid current")
}

function TEST_checkOffset_success() {
    //offset value := 8534624

    checkOffset(8534623)
}

function TEST_checkOffset_callDataEncodingTooBig() {
    //offset value := 8534624
    testing_testWillFailWith("calldataEncoding too big")

    checkOffset(8534625)
}

function TEST_validateOperatorProvidedPrices1() {
    testing_testWillFailWith("Fair pubdata price too high")

    validateOperatorProvidedPrices(10000000000000, 1000000000000001)
}

function TEST_validateOperatorProvidedPrices2() {
    testing_testWillFailWith("L2 fair gas price too high")

    validateOperatorProvidedPrices(10000000000001, 100000000000000)
}

function TEST_validateOperatorProvidedPrices3() {
    validateOperatorProvidedPrices(1000000000000, 100000000000000)
}
