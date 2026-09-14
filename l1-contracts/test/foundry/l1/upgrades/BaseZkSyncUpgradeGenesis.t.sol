// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BaseZkSyncUpgradeGenesis} from "contracts/upgrades/BaseZkSyncUpgradeGenesis.sol";
import {
    PreviousUpgradeBatchNotCleared,
    PreviousUpgradeNotFinalized,
    ProtocolMajorVersionNotZero,
    ProtocolVersionDeltaTooLarge,
    ProtocolVersionTooSmall
} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";
import {MAX_ALLOWED_MINOR_VERSION_DELTA} from "contracts/common/Config.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummyBaseZkSyncUpgradeGenesis is BaseZkSyncUpgradeGenesis, BaseUpgradeUtils {
    /// @notice The shared storage part, exposed.
    function upgrade(
        uint256 _newProtocolVersion,
        uint256 _upgradeTimestamp,
        address _verifier,
        L2CanonicalTransaction memory _l2ProtocolUpgradeTx
    ) external returns (bytes32) {
        return _upgrade(_newProtocolVersion, _upgradeTimestamp, _verifier, _l2ProtocolUpgradeTx);
    }
}

contract BaseZkSyncUpgradeGenesisTest is BaseUpgrade {
    DummyBaseZkSyncUpgradeGenesis baseZkSyncUpgrade;

    function setUp() public {
        baseZkSyncUpgrade = new DummyBaseZkSyncUpgradeGenesis();

        _prepareUpgrade();

        baseZkSyncUpgrade.setPriorityTxMaxGasLimit(1 ether);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(1000000);
    }

    function _upgrade() internal returns (bytes32) {
        return baseZkSyncUpgrade.upgrade(protocolVersion, upgradeTimestamp, verifier, l2CanonicalTransaction);
    }

    // New protocol version is not greater than the current one
    function test_revertWhen_newProtocolVersionIsNotGreaterThanTheCurrentOne(
        uint32 currentProtocolVersion,
        uint32 newProtocolVersion
    ) public {
        vm.assume(newProtocolVersion < currentProtocolVersion && newProtocolVersion > 0);

        uint256 semVerCurrentProtocolVersion = SemVer.packSemVer(0, currentProtocolVersion, 0);
        uint256 semVerNewProtocolVersion = SemVer.packSemVer(0, newProtocolVersion, 0);

        baseZkSyncUpgrade.setProtocolVersion(semVerCurrentProtocolVersion);

        protocolVersion = semVerNewProtocolVersion;

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolVersionTooSmall.selector,
                semVerCurrentProtocolVersion,
                semVerNewProtocolVersion
            )
        );
        _upgrade();
    }

    // Major version is not zero
    function test_revertWhen_MajorVersionIsNotZero() public {
        baseZkSyncUpgrade.setProtocolVersion(SemVer.packSemVer(1, 0, 0));

        protocolVersion = SemVer.packSemVer(1, 1, 0);

        vm.expectRevert(abi.encodeWithSelector(ProtocolMajorVersionNotZero.selector));
        _upgrade();
    }

    // New major version is not zero
    function test_revertWhen_MajorMustAlwaysBeZero(uint32 newProtocolVersion) public {
        vm.assume(newProtocolVersion > 0);

        protocolVersion = SemVer.packSemVer(1, newProtocolVersion, 0);

        vm.expectRevert(abi.encodeWithSelector(ProtocolMajorVersionNotZero.selector));
        _upgrade();
    }

    // Protocol version difference is too big
    function test_revertWhen_tooBigProtocolVersionDifference(
        uint32 newProtocolVersion,
        uint8 oldProtocolVersion
    ) public {
        vm.assume(newProtocolVersion > MAX_ALLOWED_MINOR_VERSION_DELTA + oldProtocolVersion + 1);
        baseZkSyncUpgrade.setProtocolVersion(SemVer.packSemVer(0, oldProtocolVersion, 0));
        uint256 semVerNewProtocolVersion = SemVer.packSemVer(0, newProtocolVersion, 0);

        protocolVersion = semVerNewProtocolVersion;

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolVersionDeltaTooLarge.selector,
                newProtocolVersion - oldProtocolVersion,
                MAX_ALLOWED_MINOR_VERSION_DELTA
            )
        );
        _upgrade();
    }

    // Previous upgrade has not been finalized
    function test_revertWhen_previousUpgradeHasNotBeenFinalized() public {
        bytes32 l2SystemContractsUpgradeTxHash = bytes32(bytes("txHash"));
        baseZkSyncUpgrade.setL2SystemContractsUpgradeTxHash(l2SystemContractsUpgradeTxHash);

        vm.expectRevert(abi.encodeWithSelector(PreviousUpgradeNotFinalized.selector, l2SystemContractsUpgradeTxHash));
        _upgrade();
    }

    // Batch number of the previous upgrade has not been cleaned
    function test_revertWhen_batchNumberOfThePreviousUpgradeHasNotBeenCleaned(uint256 batchNumber) public {
        vm.assume(batchNumber > 0);

        baseZkSyncUpgrade.setL2SystemContractsUpgradeBatchNumber(batchNumber);

        vm.expectRevert(abi.encodeWithSelector(PreviousUpgradeBatchNotCleared.selector));
        _upgrade();
    }

    function test_SuccessUpgrade() public {
        _upgrade();

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), protocolVersion);
    }

    /// @dev The genesis difference: the version may stay the same (a new chain geneses AT the
    ///      current version), and that is never treated as a patch — the genesis transaction is set.
    function test_SuccessUpgrade_sameVersionStillSetsTheGenesisTransaction() public {
        baseZkSyncUpgrade.setProtocolVersion(protocolVersion);

        bytes32 txHash = _upgrade();

        assertEq(txHash, keccak256(abi.encode(l2CanonicalTransaction)), "the genesis transaction is set");
        assertEq(baseZkSyncUpgrade.getProtocolVersion(), protocolVersion);
    }
}
