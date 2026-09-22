// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ExecutorTest} from "./_Executor_Shared.t.sol";
import {Utils} from "../Utils/Utils.sol";
import {TESTNET_COMMIT_TIMESTAMP_NOT_OLDER, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT} from "contracts/common/Config.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {Unauthorized, ZKsyncOSChainConfigUpdateWithUnverifiedBatches} from "contracts/common/L1ContractErrors.sol";

// The shared fixture isolates DA and cryptographic verification. Batch state advances through
// the real commit/prove/revert entry points to exercise the configuration-update boundary.
contract LargeContractsTest is ExecutorTest {
    function setUp() public {
        vm.warp(TESTNET_COMMIT_TIMESTAMP_NOT_OLDER + 1);
        newCommitBatchInfoZKsyncOS.firstBlockTimestamp = uint64(block.timestamp);
        newCommitBatchInfoZKsyncOS.lastBlockTimestamp = uint64(block.timestamp);
    }

    function test_largeContractsDisabledByDefault() public view {
        assertFalse(getters.getZKsyncOSLargeContracts());
    }

    function testFuzz_adminCanEnableDisableAndRepeat(bool _enabled) public {
        _setLargeContracts(_enabled);
        _setLargeContracts(_enabled);
        _setLargeContracts(!_enabled);
    }

    function testFuzz_nonAdminCannotChangeLargeContracts(address _caller, bool _enabled) public {
        vm.assume(_caller != getters.getAdmin());
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        admin.setZKsyncOSLargeContracts(_enabled);

        assertFalse(getters.getZKsyncOSLargeContracts());
    }

    function test_validatorCannotEnableLargeContracts() public {
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, validator));
        admin.setZKsyncOSLargeContracts(true);

        assertFalse(getters.getZKsyncOSLargeContracts());
    }

    function test_chainTypeManagerCannotEnableLargeContracts() public {
        address chainTypeManager = getters.getChainTypeManager();
        vm.prank(chainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, chainTypeManager));
        admin.setZKsyncOSLargeContracts(true);

        assertFalse(getters.getZKsyncOSLargeContracts());
    }

    function testFuzz_unverifiedBatchesBlockUpdates(bool _oldEnabled, bool _newEnabled) public {
        _setLargeContracts(_oldEnabled);
        _commitFirstBatch();

        vm.prank(getters.getAdmin());
        vm.expectRevert(abi.encodeWithSelector(ZKsyncOSChainConfigUpdateWithUnverifiedBatches.selector, 0, 1));
        admin.setZKsyncOSLargeContracts(_newEnabled);

        assertEq(getters.getZKsyncOSLargeContracts(), _oldEnabled);
        assertEq(getters.getTotalBatchesCommitted(), 1);
        assertEq(getters.getTotalBatchesVerified(), 0);
    }

    function testFuzz_updateAfterProving(bool _enabled, bool _filteringEnabled) public {
        vm.prank(getters.getAdmin());
        admin.setZKsyncOSL1TxFiltering(_filteringEnabled);
        _setLargeContracts(_enabled);
        assertEq(getters.getZKsyncOSL1TxFiltering(), _filteringEnabled);
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = _commitFirstBatch();
        (uint256 from, uint256 to, bytes memory data) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            batches,
            proofInput
        );

        uint256[] memory expectedPublicInputs = new uint256[](1);
        bytes32 chainConfigHash = keccak256(
            abi.encode(
                getters.getChainId(),
                false,
                ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT,
                uint256(0),
                _filteringEnabled,
                _enabled
            )
        );
        expectedPublicInputs[0] = uint256(
            keccak256(
                abi.encode(
                    genesisStoredBatchInfo.batchHash,
                    batches[0].batchHash,
                    chainConfigHash,
                    batches[0].commitment
                )
            )
        );
        vm.expectCall(getters.getVerifier(), abi.encodeCall(IVerifier.verify, (expectedPublicInputs, proofInput)));

        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), from, to, data);

        assertEq(getters.getTotalBatchesCommitted(), 1);
        assertEq(getters.getTotalBatchesVerified(), 1);
        _setLargeContracts(!_enabled);
    }

    function testFuzz_updateAfterReverting(bool _enabled) public {
        _setLargeContracts(_enabled);
        _commitFirstBatch();

        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 0);

        assertEq(getters.getTotalBatchesCommitted(), 0);
        assertEq(getters.getTotalBatchesVerified(), 0);
        _setLargeContracts(!_enabled);
    }

    function _setLargeContracts(bool _enabled) internal {
        bool oldEnabled = getters.getZKsyncOSLargeContracts();
        vm.expectEmit({
            checkTopic1: true,
            checkTopic2: true,
            checkTopic3: true,
            checkData: true,
            emitter: address(admin)
        });
        emit IAdmin.NewZKsyncOSLargeContracts(oldEnabled, _enabled);

        vm.prank(getters.getAdmin());
        admin.setZKsyncOSLargeContracts(_enabled);

        assertEq(getters.getZKsyncOSLargeContracts(), _enabled);
    }

    function _commitFirstBatch() internal returns (IExecutor.StoredBatchInfo memory) {
        return _commitOSBatchGetStored(genesisStoredBatchInfo, newCommitBatchInfoZKsyncOS);
    }
}
