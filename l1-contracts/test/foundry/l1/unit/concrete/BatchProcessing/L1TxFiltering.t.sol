// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainConfigTest} from "./_ChainConfig_Shared.t.sol";
import {Utils} from "../Utils/Utils.sol";
import {PRIORITY_EXPIRATION} from "contracts/common/Config.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {
    NotCompatibleWithPriorityMode,
    Unauthorized,
    ZKsyncOSChainConfigUpdateWithUnverifiedBatches
} from "contracts/common/L1ContractErrors.sol";

contract L1TxFilteringTest is ChainConfigTest {
    function test_filteringDisabledByDefault() public view {
        assertFalse(getters.isZKsyncOSL1TxFilteringEnabled());
    }

    function testFuzz_adminCanEnableDisableAndRepeat(bool _enabled) public {
        _setFiltering(_enabled);
        _setFiltering(_enabled);
        _setFiltering(!_enabled);
    }

    function testFuzz_nonAdminCannotChangeFiltering(address _caller, bool _enabled) public {
        vm.assume(_caller != getters.getAdmin());
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        admin.setZKsyncOSL1TxFiltering(_enabled);

        assertFalse(getters.isZKsyncOSL1TxFilteringEnabled());
    }

    function test_validatorCannotEnableFiltering() public {
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, validator));
        admin.setZKsyncOSL1TxFiltering(true);

        assertFalse(getters.isZKsyncOSL1TxFilteringEnabled());
    }

    function test_chainTypeManagerCannotEnableFiltering() public {
        address chainTypeManager = getters.getChainTypeManager();
        vm.prank(chainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, chainTypeManager));
        admin.setZKsyncOSL1TxFiltering(true);

        assertFalse(getters.isZKsyncOSL1TxFilteringEnabled());
    }

    function test_filteringCannotBeEnabledAfterPriorityModeAllowed() public {
        _requestPriorityOp();
        _allowPriorityMode();

        vm.prank(getters.getAdmin());
        vm.expectRevert(NotCompatibleWithPriorityMode.selector);
        admin.setZKsyncOSL1TxFiltering(true);

        assertFalse(getters.isZKsyncOSL1TxFilteringEnabled());
        assertTrue(utilsFacet.util_getPriorityModeCanBeActivated());
        assertFalse(utilsFacet.util_getPriorityModeActivated());
        _setFiltering(false);
    }

    function test_filteringCannotBeEnabledInActivePriorityMode() public {
        vm.prank(getters.getAdmin());
        admin.makePermanentRollup();
        uint256 requestTimestamp = _requestPriorityOp();
        _allowPriorityMode();

        vm.warp(requestTimestamp + PRIORITY_EXPIRATION);
        vm.expectEmit(true, true, true, true, address(admin));
        emit IAdmin.PriorityModeActivated();
        admin.activatePriorityMode();

        vm.prank(getters.getAdmin());
        vm.expectRevert(NotCompatibleWithPriorityMode.selector);
        admin.setZKsyncOSL1TxFiltering(true);

        assertFalse(getters.isZKsyncOSL1TxFilteringEnabled());
        assertTrue(utilsFacet.util_getPriorityModeCanBeActivated());
        assertTrue(utilsFacet.util_getPriorityModeActivated());
        _setFiltering(false);
    }

    function test_priorityModeCannotBeAllowedWhileFilteringEnabled() public {
        _setFiltering(true);
        _requestPriorityOp();

        vm.prank(getters.getAdmin());
        vm.expectRevert(NotCompatibleWithPriorityMode.selector);
        admin.permanentlyAllowPriorityMode();

        assertTrue(getters.isZKsyncOSL1TxFilteringEnabled());
        assertFalse(utilsFacet.util_getPriorityModeCanBeActivated());
        assertFalse(utilsFacet.util_getPriorityModeActivated());
    }

    function test_priorityModeCanBeAllowedAfterDisablingFiltering() public {
        _setFiltering(true);
        _requestPriorityOp();
        _setFiltering(false);
        _allowPriorityMode();

        assertFalse(getters.isZKsyncOSL1TxFilteringEnabled());
        assertFalse(utilsFacet.util_getPriorityModeActivated());
    }

    function test_filteringCanBeEnabledWithPendingPriorityRequest() public {
        _requestPriorityOp();
        uint256 firstUnprocessed = getters.getFirstUnprocessedPriorityTx();
        assertEq(getters.getPriorityQueueSize(), 1);

        _setFiltering(true);

        assertEq(getters.getFirstUnprocessedPriorityTx(), firstUnprocessed);
        assertEq(getters.getPriorityQueueSize(), 1);
    }

    function testFuzz_unverifiedBatchesBlockUpdates(bool _oldEnabled, bool _newEnabled) public {
        _setFiltering(_oldEnabled);
        _commitFirstBatch();

        vm.prank(getters.getAdmin());
        vm.expectRevert(abi.encodeWithSelector(ZKsyncOSChainConfigUpdateWithUnverifiedBatches.selector, 0, 1));
        admin.setZKsyncOSL1TxFiltering(_newEnabled);

        assertEq(getters.isZKsyncOSL1TxFilteringEnabled(), _oldEnabled);
        assertEq(getters.getTotalBatchesCommitted(), 1);
        assertEq(getters.getTotalBatchesVerified(), 0);
    }

    function testFuzz_updateAfterProving(bool _enabled) public {
        _setFiltering(_enabled);
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = _commitFirstBatch();
        (uint256 from, uint256 to, bytes memory data) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            batches,
            proofInput
        );

        uint256[] memory expectedPublicInputs = new uint256[](1);
        bytes32 chainConfigHash = _currentChainConfigHash();
        expectedPublicInputs[0] = uint256(
            keccak256(
                abi.encode(
                    genesisStoredBatchInfo.batchHash,
                    batches[0].batchHash,
                    chainConfigHash,
                    _batchOutputHash(newCommitBatchInfoZKsyncOS, bytes32(0))
                )
            )
        );
        assertEq(batches[0].commitment, bytes32(expectedPublicInputs[0]));
        vm.expectCall(getters.getVerifier(), abi.encodeCall(IVerifier.verify, (expectedPublicInputs, proofInput)));

        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), from, to, data);

        assertEq(getters.getTotalBatchesCommitted(), 1);
        assertEq(getters.getTotalBatchesVerified(), 1);
        _setFiltering(!_enabled);
    }

    function testFuzz_updateAfterReverting(bool _enabled) public {
        _setFiltering(_enabled);
        _commitFirstBatch();

        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 0);

        assertEq(getters.getTotalBatchesCommitted(), 0);
        assertEq(getters.getTotalBatchesVerified(), 0);
        _setFiltering(!_enabled);
    }

    function _allowPriorityMode() internal {
        vm.expectEmit(true, true, true, true, address(admin));
        emit IAdmin.PriorityModeAllowed();
        vm.prank(getters.getAdmin());
        admin.permanentlyAllowPriorityMode();

        assertTrue(utilsFacet.util_getPriorityModeCanBeActivated());
    }

    function _setFiltering(bool _enabled) internal {
        bool oldEnabled = getters.isZKsyncOSL1TxFilteringEnabled();
        vm.expectEmit({
            checkTopic1: true,
            checkTopic2: true,
            checkTopic3: true,
            checkData: true,
            emitter: address(admin)
        });
        emit IAdmin.NewZKsyncOSL1TxFiltering(oldEnabled, _enabled);

        vm.prank(getters.getAdmin());
        admin.setZKsyncOSL1TxFiltering(_enabled);

        assertEq(getters.isZKsyncOSL1TxFilteringEnabled(), _enabled);
    }
}
