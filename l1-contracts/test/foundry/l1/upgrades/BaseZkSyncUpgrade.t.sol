// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {BaseZkSyncUpgrade, ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {MAX_NEW_FACTORY_DEPS, SYSTEM_UPGRADE_L2_TX_TYPE, MAX_ALLOWED_MINOR_VERSION_DELTA} from "contracts/common/Config.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {ProtocolVersionMinorDeltaTooBig, InvalidTxType, L2UpgradeNonceNotEqualToNewProtocolVersion, ProtocolVersionTooSmall, PreviousUpgradeNotCleaned, PreviousUpgradeNotFinalized, PatchCantSetUpgradeTxn, PreviousProtocolMajorVersionNotZero, NewProtocolMajorVersionNotZero, PatchUpgradeCantSetDefaultAccount, PatchUpgradeCantSetBootloader} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";
import {TooManyFactoryDeps, TimeNotReached} from "contracts/common/L1ContractErrors.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummyBaseZkSyncUpgrade is BaseZkSyncUpgrade, BaseUpgradeUtils {}

contract BaseZkSyncUpgradeTest is BaseUpgrade {
    DummyBaseZkSyncUpgrade baseZkSyncUpgrade;

    function setUp() public {
        baseZkSyncUpgrade = new DummyBaseZkSyncUpgrade();

        _prepareProposedUpgrade();

        baseZkSyncUpgrade.setPriorityTxMaxGasLimit(1 ether);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(1000000);
    }

    // Upgrade is not ready yet
    function test_revertWhen_UpgradeIsNotReady(uint256 upgradeTimestamp) public {
        vm.assume(upgradeTimestamp > block.timestamp);

        proposedUpgrade.upgradeTimestamp = upgradeTimestamp;

        vm.expectRevert(abi.encodeWithSelector(TimeNotReached.selector, upgradeTimestamp, block.timestamp));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // New protocol version is not greater than the current one
    function test_revertWhen_newProtocolVersionIsNotGreaterThanTheCurrentOne(
        uint32 currentProtocolVersion,
        uint32 newProtocolVersion
    ) public {
        vm.assume(newProtocolVersion <= currentProtocolVersion && newProtocolVersion > 0);

        uint256 semVerCurrentProtocolVersion = SemVer.packSemVer(0, currentProtocolVersion, 0);
        uint256 semVerNewProtocolVersion = SemVer.packSemVer(0, newProtocolVersion, 0);

        baseZkSyncUpgrade.setProtocolVersion(semVerCurrentProtocolVersion);

        proposedUpgrade.newProtocolVersion = semVerNewProtocolVersion;

        vm.expectRevert(abi.encodeWithSelector(ProtocolVersionTooSmall.selector));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Previous major version is not zero
    function test_revertWhen_MajorVersionIsNotZero() public {
        baseZkSyncUpgrade.setProtocolVersion(SemVer.packSemVer(1, 0, 0));

        proposedUpgrade.newProtocolVersion = SemVer.packSemVer(1, 1, 0);

        vm.expectRevert(abi.encodeWithSelector(PreviousProtocolMajorVersionNotZero.selector));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // New major version is not zero
    function test_revertWhen_MajorMustAlwaysBeZero(uint32 newProtocolVersion) public {
        vm.assume(newProtocolVersion > 0);

        proposedUpgrade.newProtocolVersion = SemVer.packSemVer(1, newProtocolVersion, 0);

        vm.expectRevert(abi.encodeWithSelector(NewProtocolMajorVersionNotZero.selector));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Protocol version difference is too big
    function test_revertWhen_tooBigProtocolVersionDifference(
        uint32 newProtocolVersion,
        uint8 oldProtocolVersion
    ) public {
        vm.assume(newProtocolVersion > MAX_ALLOWED_MINOR_VERSION_DELTA + oldProtocolVersion + 1);
        baseZkSyncUpgrade.setProtocolVersion(SemVer.packSemVer(0, oldProtocolVersion, 0));
        uint256 semVerNewProtocolVersion = SemVer.packSemVer(0, newProtocolVersion, 0);

        proposedUpgrade.newProtocolVersion = semVerNewProtocolVersion;

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolVersionMinorDeltaTooBig.selector,
                MAX_ALLOWED_MINOR_VERSION_DELTA,
                newProtocolVersion - oldProtocolVersion
            )
        );
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Previous upgrade has not been finalized
    function test_revertWhen_previousUpgradeHasNotBeenFinalized() public {
        bytes32 l2SystemContractsUpgradeTxHash = bytes32(bytes("txHash"));
        baseZkSyncUpgrade.setL2SystemContractsUpgradeTxHash(l2SystemContractsUpgradeTxHash);

        vm.expectRevert(abi.encodeWithSelector(PreviousUpgradeNotFinalized.selector, l2SystemContractsUpgradeTxHash));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Batch number of the previous upgrade has not been cleaned
    function test_revertWhen_batchNumberOfThePreviousUpgradeHasNotBeenCleaned(uint256 batchNumber) public {
        vm.assume(batchNumber > 0);

        baseZkSyncUpgrade.setL2SystemContractsUpgradeBatchNumber(batchNumber);

        vm.expectRevert(abi.encodeWithSelector(PreviousUpgradeNotCleaned.selector));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Patch upgrade can't set bootloader
    function test_revertWhen_PatchUpgradeCantSetBootloader() public {
        baseZkSyncUpgrade.setProtocolVersion(SemVer.packSemVer(0, 1, 0));
        proposedUpgrade.newProtocolVersion = SemVer.packSemVer(0, 1, 1);

        vm.expectRevert(abi.encodeWithSelector(PatchUpgradeCantSetBootloader.selector));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Patch upgrade can't set default account
    function test_revertWhen_PatchUpgradeCantSetDefaultAccount() public {
        baseZkSyncUpgrade.setProtocolVersion(SemVer.packSemVer(0, 1, 0));
        proposedUpgrade.newProtocolVersion = SemVer.packSemVer(0, 1, 1);
        proposedUpgrade.bootloaderHash = bytes32(0);

        vm.expectRevert(abi.encodeWithSelector(PatchUpgradeCantSetDefaultAccount.selector));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // L2 system upgrade tx type is wrong
    function test_revertWhen_InvalidTxType(uint256 newTxType) public {
        vm.assume(newTxType != SYSTEM_UPGRADE_L2_TX_TYPE && newTxType > 0);
        proposedUpgrade.l2ProtocolUpgradeTx.txType = newTxType;

        vm.expectRevert(abi.encodeWithSelector(InvalidTxType.selector, newTxType));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Patch upgrade can't set upgrade txn
    function test_revertWhen_PatchCantSetUpgradeTxn() public {
        // Change basic hashes to 0, to skip previous path only checks
        proposedUpgrade.bootloaderHash = bytes32(0);
        proposedUpgrade.defaultAccountHash = bytes32(0);
        proposedUpgrade.evmEmulatorHash = bytes32(0);

        baseZkSyncUpgrade.setProtocolVersion(SemVer.packSemVer(0, 1, 0));
        proposedUpgrade.newProtocolVersion = SemVer.packSemVer(0, 1, 1);

        vm.expectRevert(abi.encodeWithSelector(PatchCantSetUpgradeTxn.selector));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // L2 upgrade nonce is not equal to the new protocol version
    function test_revertWhen_L2UpgradeNonceIsNotEqualToNewProtocolVersion(
        uint32 newProtocolVersion,
        uint32 nonce
    ) public {
        vm.assume(newProtocolVersion > 0);
        vm.assume(nonce != newProtocolVersion && nonce > 0);

        uint256 semVerNewProtocolVersion = SemVer.packSemVer(0, newProtocolVersion, 0);

        baseZkSyncUpgrade.setProtocolVersion(SemVer.packSemVer(0, newProtocolVersion - 1, 0));

        proposedUpgrade.newProtocolVersion = semVerNewProtocolVersion;
        proposedUpgrade.l2ProtocolUpgradeTx.nonce = nonce;

        vm.expectRevert(
            abi.encodeWithSelector(L2UpgradeNonceNotEqualToNewProtocolVersion.selector, nonce, newProtocolVersion)
        );
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Factory deps can be at most 64 (MAX_NEW_FACTORY_DEPS)
    function test_revertWhen_FactoryDepsCanBeAtMost64(uint8 maxNewFactoryDeps) public {
        vm.assume(maxNewFactoryDeps > MAX_NEW_FACTORY_DEPS);

        proposedUpgrade.l2ProtocolUpgradeTx.factoryDeps = new uint256[](maxNewFactoryDeps);

        vm.expectRevert(abi.encodeWithSelector(TooManyFactoryDeps.selector));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Upgrade with mock factoryDepHash
    function test_upgrade_WithMockFactoryDepHash() public {
        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = "11111111111111111111111111111111";

        proposedUpgrade.l2ProtocolUpgradeTx.factoryDeps = new uint256[](1);

        bytes32 bytecodeHash = L2ContractHelper.hashL2Bytecode(factoryDeps[0]);

        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_SuccessWith_VerifierAddressIsZero() public {
        proposedUpgrade.verifier = address(0);

        baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
        assertEq(baseZkSyncUpgrade.getL2DefaultAccountBytecodeHash(), proposedUpgrade.defaultAccountHash);
        assertEq(baseZkSyncUpgrade.getL2BootloaderBytecodeHash(), proposedUpgrade.bootloaderHash);
    }

    function test_SuccessWith_NewVerifierParamsIsZero() public {
        proposedUpgrade.verifierParams = VerifierParams({
            recursionNodeLevelVkHash: bytes32(0),
            recursionLeafLevelVkHash: bytes32(0),
            recursionCircuitsSetVksHash: bytes32(0)
        });

        baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
        assertEq(baseZkSyncUpgrade.getVerifier(), proposedUpgrade.verifier);
        assertEq(baseZkSyncUpgrade.getL2DefaultAccountBytecodeHash(), proposedUpgrade.defaultAccountHash);
        assertEq(baseZkSyncUpgrade.getL2BootloaderBytecodeHash(), proposedUpgrade.bootloaderHash);
    }

    function test_SuccessWith_L2BootloaderBytecodeHashIsZero() public {
        proposedUpgrade.bootloaderHash = bytes32(0);

        baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
        assertEq(baseZkSyncUpgrade.getVerifier(), proposedUpgrade.verifier);
        assertEq(baseZkSyncUpgrade.getL2DefaultAccountBytecodeHash(), proposedUpgrade.defaultAccountHash);
    }

    function test_SuccessWith_L2DefaultAccountBytecodeHashIsZero() public {
        proposedUpgrade.defaultAccountHash = bytes32(0);

        baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
        assertEq(baseZkSyncUpgrade.getVerifier(), proposedUpgrade.verifier);
        assertEq(baseZkSyncUpgrade.getL2BootloaderBytecodeHash(), proposedUpgrade.bootloaderHash);
    }

    function test_SuccessWith_TxTypeIsZero() public {
        proposedUpgrade.l2ProtocolUpgradeTx.txType = 0;

        baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
        assertEq(baseZkSyncUpgrade.getVerifier(), proposedUpgrade.verifier);
        assertEq(baseZkSyncUpgrade.getL2DefaultAccountBytecodeHash(), proposedUpgrade.defaultAccountHash);
        assertEq(baseZkSyncUpgrade.getL2BootloaderBytecodeHash(), proposedUpgrade.bootloaderHash);
    }

    function test_SuccessUpgrade() public {
        baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
        assertEq(baseZkSyncUpgrade.getVerifier(), proposedUpgrade.verifier);
        assertEq(baseZkSyncUpgrade.getL2DefaultAccountBytecodeHash(), proposedUpgrade.defaultAccountHash);
        assertEq(baseZkSyncUpgrade.getL2BootloaderBytecodeHash(), proposedUpgrade.bootloaderHash);
    }
}
