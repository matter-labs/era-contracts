// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainConfigTest} from "./_ChainConfig_Shared.t.sol";
import {Utils} from "../Utils/Utils.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {Unauthorized, ZKsyncOSChainConfigUpdateWithUnverifiedBatches} from "contracts/common/L1ContractErrors.sol";

contract LargeContractsTest is ChainConfigTest {
    function test_largeContractsDisabledByDefault() public view {
        assertFalse(getters.isZKsyncOSLargeContractsEnabled());
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
        admin.setZKsyncOSLargeContractsEnabled(_enabled);

        assertFalse(getters.isZKsyncOSLargeContractsEnabled());
    }

    function test_validatorCannotEnableLargeContracts() public {
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, validator));
        admin.setZKsyncOSLargeContractsEnabled(true);

        assertFalse(getters.isZKsyncOSLargeContractsEnabled());
    }

    function test_chainTypeManagerCannotEnableLargeContracts() public {
        address chainTypeManager = getters.getChainTypeManager();
        vm.prank(chainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, chainTypeManager));
        admin.setZKsyncOSLargeContractsEnabled(true);

        assertFalse(getters.isZKsyncOSLargeContractsEnabled());
    }

    function testFuzz_unverifiedBatchesBlockUpdates(bool _oldEnabled, bool _newEnabled) public {
        _setLargeContracts(_oldEnabled);
        _commitFirstBatch();

        vm.prank(getters.getAdmin());
        vm.expectRevert(abi.encodeWithSelector(ZKsyncOSChainConfigUpdateWithUnverifiedBatches.selector, 0, 1));
        admin.setZKsyncOSLargeContractsEnabled(_newEnabled);

        assertEq(getters.isZKsyncOSLargeContractsEnabled(), _oldEnabled);
        assertEq(getters.getTotalBatchesCommitted(), 1);
        assertEq(getters.getTotalBatchesVerified(), 0);
    }

    function test_updateAfterProvingWithBothFlagsDisabled() public {
        _checkUpdateAfterProving(false, false);
    }

    function test_updateAfterProvingWithOnlyLargeContracts() public {
        _checkUpdateAfterProving(true, false);
    }

    function test_updateAfterProvingWithOnlyFiltering() public {
        _checkUpdateAfterProving(false, true);
    }

    function test_updateAfterProvingWithBothFlagsEnabled() public {
        _checkUpdateAfterProving(true, true);
    }

    function testFuzz_updateAfterProving(bool _enabled, bool _filteringEnabled) public {
        _checkUpdateAfterProving(_enabled, _filteringEnabled);
    }

    function _checkUpdateAfterProving(bool _enabled, bool _filteringEnabled) internal {
        vm.prank(getters.getAdmin());
        admin.setZKsyncOSL1TxFiltering(_filteringEnabled);
        _setLargeContracts(_enabled);
        assertEq(getters.isZKsyncOSL1TxFilteringEnabled(), _filteringEnabled);
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
        bool oldEnabled = getters.isZKsyncOSLargeContractsEnabled();
        vm.expectEmit({
            checkTopic1: true,
            checkTopic2: true,
            checkTopic3: true,
            checkData: true,
            emitter: address(admin)
        });
        emit IAdmin.NewZKsyncOSLargeContracts(oldEnabled, _enabled);

        vm.prank(getters.getAdmin());
        admin.setZKsyncOSLargeContractsEnabled(_enabled);

        assertEq(getters.isZKsyncOSLargeContractsEnabled(), _enabled);
    }
}
