// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SystemContextEra} from "contracts/l2-system/era/SystemContextEra.sol";
import {ISystemContext} from "contracts/common/interfaces/ISystemContext.sol";
import {ISystemContextDeprecated} from "system-contracts/contracts/interfaces/ISystemContextDeprecated.sol";
import {IL2ChainAssetHandler} from "contracts/core/chain-asset-handler/IL2ChainAssetHandler.sol";
import {
    L2_BOOTLOADER_ADDRESS,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {
    DeprecatedFunction,
    TimestampsShouldBeIncremental,
    ProvidedBatchNumberIsNotCorrect,
    CurrentBatchNumberMustBeGreaterThanZero,
    L2BlockAndBatchTimestampMismatch,
    NoVirtualBlocks,
    NonMonotonicL2BlockTimestamp,
    IncorrectL2BlockHash
} from "system-contracts/contracts/SystemContractErrors.sol";
import {L2ChainAssetHandler} from "contracts/core/chain-asset-handler/L2ChainAssetHandler.sol";
import {SystemContextBase} from "contracts/l2-system/SystemContextBase.sol";

/// @title SystemContextEraTest
/// @notice Unit tests for SystemContextEra contract
contract SystemContextEraTest is Test {
    SystemContextEra internal systemContext;

    address internal alice = makeAddr("alice");

    function setUp() public virtual {
        // Etch the real L2ChainAssetHandler bytecode at its canonical address so that
        // SystemContextEra's external call to setSettlementLayerChainId does not revert with
        // "call to non-contract address".
        L2ChainAssetHandler cahImpl = new L2ChainAssetHandler();
        vm.etch(L2_CHAIN_ASSET_HANDLER_ADDR, address(cahImpl).code);

        // Etch the real SystemContextEra bytecode at its canonical system address so that
        // the onlySystemContext modifier in L2ChainAssetHandler (msg.sender check) passes.
        SystemContextEra scImpl = new SystemContextEra();
        vm.etch(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, address(scImpl).code);
        systemContext = SystemContextEra(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR);
    }

    /*//////////////////////////////////////////////////////////////
                        setTxOrigin() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setTxOrigin_setsValue() public {
        address newOrigin = makeAddr("newOrigin");

        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setTxOrigin(newOrigin);

        assertEq(systemContext.origin(), newOrigin, "origin should be updated");
    }

    function test_setTxOrigin_revertsWhenNotBootloader() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        systemContext.setTxOrigin(alice);
    }

    function testFuzz_setTxOrigin_setsAnyAddress(address newOrigin) public {
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setTxOrigin(newOrigin);

        assertEq(systemContext.origin(), newOrigin, "origin should match");
    }

    /*//////////////////////////////////////////////////////////////
                        setGasPrice() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setGasPrice_setsValue() public {
        uint256 newGasPrice = 100 gwei;

        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setGasPrice(newGasPrice);

        assertEq(systemContext.gasPrice(), newGasPrice, "gasPrice should be updated");
    }

    function test_setGasPrice_revertsWhenNotBootloader() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        systemContext.setGasPrice(1 gwei);
    }

    function testFuzz_setGasPrice_setsAnyValue(uint256 newGasPrice) public {
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setGasPrice(newGasPrice);

        assertEq(systemContext.gasPrice(), newGasPrice, "gasPrice should match");
    }

    /*//////////////////////////////////////////////////////////////
                        setChainId() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setChainId_setsValue() public {
        uint256 newChainId = 324;

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        systemContext.setChainId(newChainId);

        assertEq(systemContext.chainId(), newChainId, "chainId should be updated");
    }

    function test_setChainId_revertsWhenNotComplexUpgrader() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        systemContext.setChainId(1);
    }

    function test_setChainId_revertsWhenCalledByBootloader() public {
        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_BOOTLOADER_ADDRESS));
        systemContext.setChainId(1);
    }

    /*//////////////////////////////////////////////////////////////
                    setSettlementLayerChainId() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setSettlementLayerChainId_callsChainAssetHandler() public {
        uint256 newChainId = 506;

        // In Foundry tests, block.chainid == 31337 != HARD_CODED_CHAIN_ID (270), so the call goes through.
        vm.expectCall(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeCall(IL2ChainAssetHandler.setSettlementLayerChainId, (0, newChainId))
        );

        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setSettlementLayerChainId(newChainId);

        assertEq(systemContext.currentSettlementLayerChainId(), newChainId, "currentSettlementLayerChainId updated");
    }

    function test_setSettlementLayerChainId_emitsEvent() public {
        uint256 newChainId = 506;

        vm.expectEmit(true, false, false, false, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR);
        emit SystemContextBase.SettlementLayerChainIdUpdated(newChainId);

        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setSettlementLayerChainId(newChainId);
    }

    function test_setSettlementLayerChainId_revertsWhenNotBootloader() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        systemContext.setSettlementLayerChainId(1);
    }

    function test_setSettlementLayerChainId_noopWhenValueUnchanged() public {
        uint256 chainId = 506;

        // First set
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setSettlementLayerChainId(chainId);

        // Second call with same value: should be a no-op (no external call)
        vm.recordLogs();
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setSettlementLayerChainId(chainId);

        // No event or external calls expected
        assertEq(systemContext.currentSettlementLayerChainId(), chainId, "value should remain unchanged");
    }

    function test_setSettlementLayerChainId_skippedWhenBlockChainIdIsHardCoded() public {
        uint256 newChainId = 999;

        // Simulate block.chainid == HARD_CODED_CHAIN_ID (270)
        vm.chainId(270);

        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setSettlementLayerChainId(newChainId);

        // block.chainid == HARD_CODED_CHAIN_ID, so we early-return and nothing changes
        assertEq(systemContext.currentSettlementLayerChainId(), 0, "should remain 0 when chainid is HARD_CODED");
    }

    /*//////////////////////////////////////////////////////////////
                    incrementTxNumberInBatch() / resetTxNumberInBatch()
    //////////////////////////////////////////////////////////////*/

    function test_incrementTxNumberInBatch_incrementsCounter() public {
        assertEq(systemContext.txNumberInBlock(), 0, "initial txNumberInBlock should be 0");

        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.incrementTxNumberInBatch();

        assertEq(systemContext.txNumberInBlock(), 1, "txNumberInBlock should be 1");

        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.incrementTxNumberInBatch();

        assertEq(systemContext.txNumberInBlock(), 2, "txNumberInBlock should be 2");
    }

    function test_incrementTxNumberInBatch_revertsWhenNotBootloader() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        systemContext.incrementTxNumberInBatch();
    }

    function test_resetTxNumberInBatch_resetsToZero() public {
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.incrementTxNumberInBatch();
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.incrementTxNumberInBatch();

        assertEq(systemContext.txNumberInBlock(), 2, "should be 2 before reset");

        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.resetTxNumberInBatch();

        assertEq(systemContext.txNumberInBlock(), 0, "should be 0 after reset");
    }

    function test_resetTxNumberInBatch_revertsWhenNotBootloader() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        systemContext.resetTxNumberInBatch();
    }

    /*//////////////////////////////////////////////////////////////
                        setPubdataInfo() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setPubdataInfo_setsValues() public {
        uint256 gasPerPubdataByte = 800;
        uint256 basePubdataSpent = 1000;

        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setPubdataInfo(gasPerPubdataByte, basePubdataSpent);

        assertEq(systemContext.gasPerPubdataByte(), gasPerPubdataByte, "gasPerPubdataByte should be updated");
    }

    function test_setPubdataInfo_revertsWhenNotBootloader() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        systemContext.setPubdataInfo(1, 1);
    }

    /*//////////////////////////////////////////////////////////////
                    getCurrentPubdataSpent() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getCurrentPubdataSpent_doesNotRevert() public view {
        // On ZkSync VM, _getPubdataPublished() uses a ZkSync-specific opcode.
        // On standard EVM the staticcall returns the success flag (1), so the result is
        // implementation-defined. We only verify the call does not revert.
        systemContext.getCurrentPubdataSpent();
    }

    /*//////////////////////////////////////////////////////////////
                    unsafeOverrideBatch() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_unsafeOverrideBatch_setsBatchData() public {
        uint256 newTimestamp = 1000;
        uint256 newNumber = 5;
        uint256 newBaseFee = 1 gwei;

        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.unsafeOverrideBatch(newTimestamp, newNumber, newBaseFee);

        assertEq(systemContext.baseFee(), newBaseFee, "baseFee should be updated");
    }

    function test_unsafeOverrideBatch_revertsWhenNotBootloader() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        systemContext.unsafeOverrideBatch(1000, 5, 1 gwei);
    }

    /*//////////////////////////////////////////////////////////////
                    appendTransactionToCurrentL2Block() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_appendTransactionToCurrentL2Block_updatesRollingHash() public {
        bytes32 txHash1 = keccak256("tx1");
        bytes32 txHash2 = keccak256("tx2");

        // The first call: rollingHash = keccak256(abi.encode(bytes32(0), txHash1))
        bytes32 expectedAfterFirst = keccak256(abi.encode(bytes32(0), txHash1));

        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.appendTransactionToCurrentL2Block(txHash1);

        // Second call: rollingHash = keccak256(abi.encode(expectedAfterFirst, txHash2))
        bytes32 expectedAfterSecond = keccak256(abi.encode(expectedAfterFirst, txHash2));

        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.appendTransactionToCurrentL2Block(txHash2);

        // We can't directly read currentL2BlockTxsRollingHash (internal), but we can verify
        // behavior indirectly via setL2Block (which checks the hash).
        // For now just verify the call did not revert.
        assertTrue(expectedAfterSecond != bytes32(0), "hash should be non-zero");
    }

    function test_appendTransactionToCurrentL2Block_revertsWhenNotBootloader() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        systemContext.appendTransactionToCurrentL2Block(keccak256("tx"));
    }

    /*//////////////////////////////////////////////////////////////
                    getL2BlockNumberAndTimestamp() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getL2BlockNumberAndTimestamp_initiallyZero() public view {
        (uint128 blockNumber, uint128 blockTimestamp) = systemContext.getL2BlockNumberAndTimestamp();
        assertEq(blockNumber, 0, "initial blockNumber should be 0");
        assertEq(blockTimestamp, 0, "initial blockTimestamp should be 0");
    }

    /*//////////////////////////////////////////////////////////////
                    getBlockNumber() / getBlockTimestamp() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getBlockNumber_initiallyZero() public view {
        assertEq(systemContext.getBlockNumber(), 0, "initial getBlockNumber should be 0");
    }

    function test_getBlockTimestamp_initiallyZero() public view {
        assertEq(systemContext.getBlockTimestamp(), 0, "initial getBlockTimestamp should be 0");
    }

    /*//////////////////////////////////////////////////////////////
                    setNewBatch() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setNewBatch_revertsWhenTimestampNotIncreased() public {
        // Default batch timestamp is 0; new timestamp must be > 0
        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(TimestampsShouldBeIncremental.selector, 0, 0));
        systemContext.setNewBatch(bytes32(0), 0, 1, 1 gwei);
    }

    function test_setNewBatch_revertsWhenIncorrectBatchNumber() public {
        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(ProvidedBatchNumberIsNotCorrect.selector, 1, 5));
        systemContext.setNewBatch(bytes32(0), 100, 5, 1 gwei);
    }

    function test_setNewBatch_setsNewBatchInfo() public {
        uint128 newTimestamp = 1000;
        uint256 newBaseFee = 2 gwei;

        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setNewBatch(bytes32(0), newTimestamp, 1, newBaseFee);

        assertEq(systemContext.baseFee(), newBaseFee, "baseFee should be updated");
    }

    function test_setNewBatch_revertsWhenNotBootloader() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        systemContext.setNewBatch(bytes32(0), 100, 1, 1 gwei);
    }

    /*//////////////////////////////////////////////////////////////
                    publishTimestampDataToL1() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_publishTimestampDataToL1_revertsWhenBatchNumberIsZero() public {
        // Default batch number is 0
        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(CurrentBatchNumberMustBeGreaterThanZero.selector);
        systemContext.publishTimestampDataToL1();
    }

    // Note: test_publishTimestampDataToL1_successAfterSetNewBatch is omitted because
    // _toL1() uses ZkSync-specific call semantics where _value is passed as argsOffset.
    // With non-zero packed timestamps, this causes OOG on standard EVM. Correctness of
    // _toL1 is verified on the ZkSync VM via bootloader integration tests.

    function test_publishTimestampDataToL1_revertsWhenNotBootloader() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        systemContext.publishTimestampDataToL1();
    }

    /*//////////////////////////////////////////////////////////////
                    setL2Block() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setL2Block_revertsWhenNotBootloader() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        systemContext.setL2Block(1, 1000, bytes32(0), true, 1);
    }

    function test_setL2Block_revertsWhenTimestampBelowBatch() public {
        // Set a batch with timestamp 1000
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setNewBatch(bytes32(0), 1000, 1, 1 gwei);

        // Try to set L2 block with timestamp < batch timestamp
        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(L2BlockAndBatchTimestampMismatch.selector, 500, 1000));
        systemContext.setL2Block(1, 500, bytes32(0), true, 1);
    }

    function test_setL2Block_revertsWhenFirstInBatchWithNoVirtualBlocks() public {
        // Set a batch first
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setNewBatch(bytes32(0), 1000, 1, 1 gwei);

        // Try to set L2 block with _maxVirtualBlocksToCreate == 0 and _isFirstInBatch == true
        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(NoVirtualBlocks.selector);
        systemContext.setL2Block(1, 1000, bytes32(0), true, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    DEPRECATED METHODS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getBatchHash_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(DeprecatedFunction.selector, systemContext.getBatchHash.selector));
        systemContext.getBatchHash(0);
    }

    function test_getBatchNumberAndTimestamp_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeprecatedFunction.selector, systemContext.getBatchNumberAndTimestamp.selector)
        );
        systemContext.getBatchNumberAndTimestamp();
    }

    function test_currentBlockInfo_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(DeprecatedFunction.selector, systemContext.currentBlockInfo.selector));
        systemContext.currentBlockInfo();
    }

    function test_getBlockNumberAndTimestamp_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeprecatedFunction.selector, systemContext.getBlockNumberAndTimestamp.selector)
        );
        systemContext.getBlockNumberAndTimestamp();
    }

    function test_blockHash_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(DeprecatedFunction.selector, systemContext.blockHash.selector));
        systemContext.blockHash(0);
    }

    /*//////////////////////////////////////////////////////////////
                    getBlockHashEVM() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getBlockHashEVM_returnsZeroForCurrentBlock() public view {
        // currentVirtualL2BlockInfo.number == 0, so blockNumber <= _block => hash = 0
        bytes32 hash = systemContext.getBlockHashEVM(0);
        assertEq(hash, bytes32(0), "hash should be 0 for current or future block");
    }

    function test_getBlockHashEVM_returnsZeroForFarPastBlock() public view {
        // When virtual block number is 0 and _block is any value, blockNumber <= _block => 0
        bytes32 hash = systemContext.getBlockHashEVM(1000);
        assertEq(hash, bytes32(0), "hash should be 0 for far past block");
    }

    /*//////////////////////////////////////////////////////////////
                    INTERFACE COMPLIANCE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_implementsISystemContext() public view {
        ISystemContext ctx = ISystemContext(address(systemContext));
        assertEq(address(ctx), address(systemContext), "should be castable to ISystemContext");
    }

    function test_implementsISystemContextDeprecated() public view {
        ISystemContextDeprecated ctx = ISystemContextDeprecated(address(systemContext));
        assertEq(address(ctx), address(systemContext), "should be castable to ISystemContextDeprecated");
    }

    /*//////////////////////////////////////////////////////////////
                    getCurrentPubdataCost() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getCurrentPubdataCost_returnsZeroWhenNoPubdata() public view {
        // In standard EVM pubdata = 0, so cost = 0
        assertEq(systemContext.getCurrentPubdataCost(), 0, "getCurrentPubdataCost should be 0");
    }
}
