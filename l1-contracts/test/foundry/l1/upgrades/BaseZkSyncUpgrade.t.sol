// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {LEGACY_PRIORITY_TX_MAX_GAS_LIMIT} from "test/foundry/TestConstants.sol";

import {BaseZkSyncUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";

import {
    MAX_ALLOWED_MINOR_VERSION_DELTA,
    MAX_NEW_FACTORY_DEPS,
    PRIORITY_TX_MAX_GAS_LIMIT,
    UPGRADE_TX_MAX_GAS_LIMIT,
    ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE
} from "contracts/common/Config.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {
    InvalidTxType,
    L2UpgradeNonceNotEqualToNewProtocolVersion,
    NewProtocolMajorVersionNotZero,
    PatchCantSetUpgradeTxn,
    PreviousProtocolMajorVersionNotZero,
    PreviousUpgradeNotCleaned,
    PreviousUpgradeNotFinalized,
    ProtocolVersionMinorDeltaTooBig,
    ProtocolVersionTooSmall
} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";
import {
    PubdataGreaterThanLimit,
    TimeNotReached,
    TooManyFactoryDeps,
    TooMuchGas,
    ValidateTxnNotEnoughGas,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {ZKSyncOSBytecodeInfo} from "contracts/common/libraries/ZKSyncOSBytecodeInfo.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummyBaseZkSyncUpgrade is BaseZkSyncUpgrade, BaseUpgradeUtils {
    function getL2SystemContractsUpgradeTxHash() public view returns (bytes32) {
        return s.l2SystemContractsUpgradeTxHash;
    }
}

contract BaseZkSyncUpgradeTest is BaseUpgrade {
    DummyBaseZkSyncUpgrade internal baseZkSyncUpgrade;
    address internal mockChainTypeManager = makeAddr("mockChainTypeManager");
    address internal mockVerifier = makeAddr("mockVerifier");

    function setUp() public {
        baseZkSyncUpgrade = new DummyBaseZkSyncUpgrade();

        _prepareProposedUpgrade();

        // Isolate the upgrade from the admin setter to model pre-upgrade chain storage.
        baseZkSyncUpgrade.setPriorityTxMaxGasLimit(LEGACY_PRIORITY_TX_MAX_GAS_LIMIT);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(1000000);

        // Set up CTM for verifier lookup
        baseZkSyncUpgrade.setChainTypeManager(mockChainTypeManager);
        baseZkSyncUpgrade.mockProtocolVersionVerifier(protocolVersion, mockVerifier);
    }

    function test_revertWhen_UpgradeExceedsUpgradeGasCeiling() public {
        _assertUpgradeGasLimitRejected(UPGRADE_TX_MAX_GAS_LIMIT + 1);
    }

    function testFuzz_revertWhen_UpgradeExceedsUpgradeGasCeiling(uint256 _gasLimit) public {
        _assertUpgradeGasLimitRejected(bound(_gasLimit, UPGRADE_TX_MAX_GAS_LIMIT + 1, type(uint256).max));
    }

    function _assertUpgradeGasLimitRejected(uint256 _gasLimit) internal {
        proposedUpgrade.l2ProtocolUpgradeTx.gasLimit = _gasLimit;
        uint256 versionBefore = baseZkSyncUpgrade.getProtocolVersion();
        address verifierBefore = baseZkSyncUpgrade.getVerifier();

        vm.expectRevert(TooMuchGas.selector);
        baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), versionBefore);
        assertEq(baseZkSyncUpgrade.getVerifier(), verifierBefore);
        assertEq(baseZkSyncUpgrade.getPriorityTxMaxGasLimit(), LEGACY_PRIORITY_TX_MAX_GAS_LIMIT);
        assertEq(baseZkSyncUpgrade.getL2SystemContractsUpgradeTxHash(), bytes32(0));
    }

    // The generic upgrade validates the upgrade tx against its own ceiling and leaves the chain's
    // priority admission limit untouched.
    function test_UpgradeAtUpgradeGasCeiling() public {
        _assertUpgradePreservesGasLimit(LEGACY_PRIORITY_TX_MAX_GAS_LIMIT);
    }

    function test_UpgradeOneGasAbovePriorityCeiling() public {
        proposedUpgrade.l2ProtocolUpgradeTx.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT + 1;
        _assertUpgradePreservesGasLimit(PRIORITY_TX_MAX_GAS_LIMIT);
    }

    function testFuzz_UpgradeAbovePriorityCeiling(uint256 _gasLimit) public {
        proposedUpgrade.l2ProtocolUpgradeTx.gasLimit = bound(
            _gasLimit,
            PRIORITY_TX_MAX_GAS_LIMIT + 1,
            UPGRADE_TX_MAX_GAS_LIMIT
        );
        _assertUpgradePreservesGasLimit(PRIORITY_TX_MAX_GAS_LIMIT);
    }

    function test_revertWhen_UpgradeExceedsPubdataLimit() public {
        uint256 requiredPubdata = UPGRADE_TX_MAX_GAS_LIMIT / proposedUpgrade.l2ProtocolUpgradeTx.gasPerPubdataByteLimit;
        uint32 maxPubdata = uint32(requiredPubdata - 1);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(maxPubdata);

        vm.expectRevert(abi.encodeWithSelector(PubdataGreaterThanLimit.selector, maxPubdata, requiredPubdata));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(baseZkSyncUpgrade.getL2SystemContractsUpgradeTxHash(), bytes32(0));
        assertEq(baseZkSyncUpgrade.getPriorityTxMaxGasLimit(), LEGACY_PRIORITY_TX_MAX_GAS_LIMIT);
    }

    function test_revertWhen_UpgradeBelowMinimumGas() public {
        proposedUpgrade.l2ProtocolUpgradeTx.gasLimit = 0;

        vm.expectRevert(ValidateTxnNotEnoughGas.selector);
        baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(baseZkSyncUpgrade.getL2SystemContractsUpgradeTxHash(), bytes32(0));
        assertEq(baseZkSyncUpgrade.getPriorityTxMaxGasLimit(), LEGACY_PRIORITY_TX_MAX_GAS_LIMIT);
    }

    function test_UpgradePreservesZeroGasLimit() public {
        _assertUpgradePreservesGasLimit(0);
    }

    function testFuzz_UpgradePreservesStoredGasLimit(uint256 _storedLimit) public {
        _assertUpgradePreservesGasLimit(_storedLimit);
    }

    function _assertUpgradePreservesGasLimit(uint256 _storedLimit) internal {
        baseZkSyncUpgrade.setPriorityTxMaxGasLimit(_storedLimit);
        bytes32 expectedTxHash = keccak256(abi.encode(proposedUpgrade.l2ProtocolUpgradeTx));
        vm.recordLogs();
        vm.expectEmit(true, true, false, true, address(baseZkSyncUpgrade));
        emit BaseZkSyncUpgrade.UpgradeComplete(proposedUpgrade.newProtocolVersion, expectedTxHash, proposedUpgrade);

        bytes32 txHash = baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(txHash, expectedTxHash);
        assertEq(baseZkSyncUpgrade.getL2SystemContractsUpgradeTxHash(), expectedTxHash);
        assertEq(baseZkSyncUpgrade.getPriorityTxMaxGasLimit(), _storedLimit);
        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
        assertEq(baseZkSyncUpgrade.getVerifier(), mockVerifier);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], IAdmin.NewPriorityTxMaxGasLimit.selector);
        }
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

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolVersionTooSmall.selector,
                semVerCurrentProtocolVersion,
                semVerNewProtocolVersion
            )
        );
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

    // L2 system upgrade tx type is wrong
    function test_revertWhen_InvalidTxType(uint256 newTxType) public {
        vm.assume(newTxType != ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE && newTxType > 0);
        proposedUpgrade.l2ProtocolUpgradeTx.txType = newTxType;

        vm.expectRevert(abi.encodeWithSelector(InvalidTxType.selector, newTxType));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Patch upgrade can't set upgrade txn
    function test_revertWhen_PatchCantSetUpgradeTxn() public {
        uint256 newVersion = SemVer.packSemVer(0, 1, 1);
        baseZkSyncUpgrade.setProtocolVersion(SemVer.packSemVer(0, 1, 0));
        baseZkSyncUpgrade.mockProtocolVersionVerifier(newVersion, mockVerifier);
        proposedUpgrade.newProtocolVersion = newVersion;

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
        baseZkSyncUpgrade.mockProtocolVersionVerifier(semVerNewProtocolVersion, mockVerifier);

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

    function test_upgrade_WithFactoryDepHash() public {
        bytes memory factoryDep = hex"6001600055";
        proposedUpgrade.l2ProtocolUpgradeTx.factoryDeps = new uint256[](1);
        proposedUpgrade.l2ProtocolUpgradeTx.factoryDeps[0] = uint256(ZKSyncOSBytecodeInfo.hashEVMBytecode(factoryDep));
        bytes32 expectedTxHash = keccak256(abi.encode(proposedUpgrade.l2ProtocolUpgradeTx));

        vm.expectEmit(true, true, false, true, address(baseZkSyncUpgrade));
        emit BaseZkSyncUpgrade.UpgradeComplete(proposedUpgrade.newProtocolVersion, expectedTxHash, proposedUpgrade);
        bytes32 txHash = baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(txHash, expectedTxHash);
        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
    }

    // The EraVM bytecode-hash fields of ProposedUpgrade are dead on the ZKsync OS line. These values
    // deliberately violate the old bytecode-hash format, so the upgrade would revert if it processed them.
    function test_upgrade_IgnoresLegacyBytecodeHashes() public {
        proposedUpgrade.bootloaderHash = bytes32(uint256(1));
        proposedUpgrade.defaultAccountHash = bytes32(uint256(2));
        proposedUpgrade.evmEmulatorHash = bytes32(uint256(3));

        baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
    }

    function test_SuccessWith_TxTypeIsZero() public {
        proposedUpgrade.l2ProtocolUpgradeTx.txType = 0;

        baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
    }

    function test_SuccessUpgrade() public {
        baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
    }

    function test_revertWhen_VerifierIsZeroAddress() public {
        // Mock CTM to return address(0) as verifier for the new protocol version.
        // After the change from silent return to revert, this should now revert with ZeroAddress.
        baseZkSyncUpgrade.mockProtocolVersionVerifier(protocolVersion, address(0));

        vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }
}
