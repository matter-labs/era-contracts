// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {LEGACY_PRIORITY_TX_MAX_GAS_LIMIT} from "test/foundry/TestConstants.sol";

import {BaseZkSyncUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";

import {
    MAX_ALLOWED_MINOR_VERSION_DELTA,
    MAX_NEW_FACTORY_DEPS,
    PRIORITY_TX_MAX_GAS_LIMIT,
    ProofSystem,
    UPGRADE_TX_MAX_GAS_LIMIT,
    ZKSYNC_OS_MULTI_PROOF_VERIFICATION_TYPE,
    ZKSYNC_OS_PLONK_VERIFICATION_TYPE,
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
    NotMultiProofMode,
    PubdataGreaterThanLimit,
    TimeNotReached,
    TooManyFactoryDeps,
    TooMuchGas,
    ValidateTxnNotEnoughGas,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {ZKSyncOSBytecodeInfo} from "contracts/common/libraries/ZKSyncOSBytecodeInfo.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";
import {ZKsyncOSVerifier} from "contracts/state-transition/verifiers/ZKsyncOSVerifier.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummyBaseZkSyncUpgrade is BaseZkSyncUpgrade, BaseUpgradeUtils {
    /// @notice The shared storage part, exposed.
    function upgrade(
        uint256 _newProtocolVersion,
        uint256 _upgradeTimestamp,
        address _verifier,
        L2CanonicalTransaction memory _l2ProtocolUpgradeTx
    ) external returns (bytes32) {
        return _upgrade(_newProtocolVersion, _upgradeTimestamp, _verifier, _l2ProtocolUpgradeTx);
    }

    /// @notice The verifier installation, exposed: `_upgrade` never hands it a zero verifier.
    function installVerifier(address _verifier) external {
        _setVerifier(IVerifier(_verifier));
    }
}

/// @notice The checks of the shared storage part (`_upgrade`), driven with hand-built inputs.
///         Several of them are unreachable through a `CTMTransition` (the composer fixes the tx type
///         and nonce, the transition caps factory deps and refuses an L2 side on a patch); they
///         stay as the engine's own last line.
contract BaseZkSyncUpgradeTest is BaseUpgrade {
    DummyBaseZkSyncUpgrade internal baseZkSyncUpgrade;

    function setUp() public {
        baseZkSyncUpgrade = new DummyBaseZkSyncUpgrade();

        _prepareUpgrade();

        // Isolate the upgrade from the admin setter to model pre-upgrade chain storage.
        baseZkSyncUpgrade.setPriorityTxMaxGasLimit(LEGACY_PRIORITY_TX_MAX_GAS_LIMIT);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(1000000);
    }

    function _upgrade() internal returns (bytes32) {
        return baseZkSyncUpgrade.upgrade(protocolVersion, upgradeTimestamp, verifier, l2CanonicalTransaction);
    }

    /// @dev A chain whose verifier is zero can never prove a batch again.
    function test_revertWhen_aZeroVerifierIsInstalled() public {
        address verifierBefore = makeAddr("installedVerifier");
        baseZkSyncUpgrade.setVerifier(verifierBefore);

        vm.expectRevert(ZeroAddress.selector);
        baseZkSyncUpgrade.installVerifier(address(0));

        assertEq(baseZkSyncUpgrade.getVerifier(), verifierBefore, "the installed verifier is unchanged");
    }

    function test_revertWhen_UpgradeExceedsUpgradeGasCeiling() public {
        _assertUpgradeGasLimitRejected(UPGRADE_TX_MAX_GAS_LIMIT + 1);
    }

    function testFuzz_revertWhen_UpgradeExceedsUpgradeGasCeiling(uint256 _gasLimit) public {
        _assertUpgradeGasLimitRejected(bound(_gasLimit, UPGRADE_TX_MAX_GAS_LIMIT + 1, type(uint256).max));
    }

    function _assertUpgradeGasLimitRejected(uint256 _gasLimit) internal {
        l2CanonicalTransaction.gasLimit = _gasLimit;
        uint256 versionBefore = baseZkSyncUpgrade.getProtocolVersion();
        address verifierBefore = baseZkSyncUpgrade.getVerifier();

        vm.expectRevert(TooMuchGas.selector);
        _upgrade();

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
        l2CanonicalTransaction.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT + 1;
        _assertUpgradePreservesGasLimit(PRIORITY_TX_MAX_GAS_LIMIT);
    }

    function testFuzz_UpgradeAbovePriorityCeiling(uint256 _gasLimit) public {
        l2CanonicalTransaction.gasLimit = bound(_gasLimit, PRIORITY_TX_MAX_GAS_LIMIT + 1, UPGRADE_TX_MAX_GAS_LIMIT);
        _assertUpgradePreservesGasLimit(PRIORITY_TX_MAX_GAS_LIMIT);
    }

    function test_revertWhen_UpgradeExceedsPubdataLimit() public {
        uint256 requiredPubdata = UPGRADE_TX_MAX_GAS_LIMIT / l2CanonicalTransaction.gasPerPubdataByteLimit;
        uint32 maxPubdata = uint32(requiredPubdata - 1);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(maxPubdata);

        vm.expectRevert(abi.encodeWithSelector(PubdataGreaterThanLimit.selector, maxPubdata, requiredPubdata));
        _upgrade();

        assertEq(baseZkSyncUpgrade.getL2SystemContractsUpgradeTxHash(), bytes32(0));
        assertEq(baseZkSyncUpgrade.getPriorityTxMaxGasLimit(), LEGACY_PRIORITY_TX_MAX_GAS_LIMIT);
    }

    function test_revertWhen_UpgradeBelowMinimumGas() public {
        l2CanonicalTransaction.gasLimit = 0;

        vm.expectRevert(ValidateTxnNotEnoughGas.selector);
        _upgrade();

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
        bytes32 expectedTxHash = keccak256(abi.encode(l2CanonicalTransaction));
        vm.recordLogs();
        vm.expectEmit(true, true, false, true, address(baseZkSyncUpgrade));
        emit BaseZkSyncUpgrade.UpgradeComplete(protocolVersion, expectedTxHash, l2CanonicalTransaction);

        bytes32 txHash = _upgrade();

        assertEq(txHash, expectedTxHash);
        assertEq(baseZkSyncUpgrade.getL2SystemContractsUpgradeTxHash(), expectedTxHash);
        assertEq(baseZkSyncUpgrade.getPriorityTxMaxGasLimit(), _storedLimit);
        assertEq(baseZkSyncUpgrade.getProtocolVersion(), protocolVersion);
        assertEq(baseZkSyncUpgrade.getVerifier(), verifier);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], IAdmin.NewPriorityTxMaxGasLimit.selector);
        }
    }

    // Upgrade is not ready yet
    function test_revertWhen_UpgradeIsNotReady(uint256 _upgradeTimestamp) public {
        vm.assume(_upgradeTimestamp > block.timestamp);

        upgradeTimestamp = _upgradeTimestamp;

        vm.expectRevert(abi.encodeWithSelector(TimeNotReached.selector, _upgradeTimestamp, block.timestamp));
        _upgrade();
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

    // Previous major version is not zero
    function test_revertWhen_MajorVersionIsNotZero() public {
        baseZkSyncUpgrade.setProtocolVersion(SemVer.packSemVer(1, 0, 0));

        protocolVersion = SemVer.packSemVer(1, 1, 0);

        vm.expectRevert(abi.encodeWithSelector(PreviousProtocolMajorVersionNotZero.selector));
        _upgrade();
    }

    // New major version is not zero
    function test_revertWhen_MajorMustAlwaysBeZero(uint32 newProtocolVersion) public {
        vm.assume(newProtocolVersion > 0);

        protocolVersion = SemVer.packSemVer(1, newProtocolVersion, 0);

        vm.expectRevert(abi.encodeWithSelector(NewProtocolMajorVersionNotZero.selector));
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
                ProtocolVersionMinorDeltaTooBig.selector,
                MAX_ALLOWED_MINOR_VERSION_DELTA,
                newProtocolVersion - oldProtocolVersion
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

        vm.expectRevert(abi.encodeWithSelector(PreviousUpgradeNotCleaned.selector));
        _upgrade();
    }

    // L2 system upgrade tx type is wrong
    function test_revertWhen_InvalidTxType(uint256 newTxType) public {
        vm.assume(newTxType != ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE && newTxType > 0);
        l2CanonicalTransaction.txType = newTxType;

        vm.expectRevert(abi.encodeWithSelector(InvalidTxType.selector, newTxType));
        _upgrade();
    }

    // Patch upgrade can't set upgrade txn
    function test_revertWhen_PatchCantSetUpgradeTxn() public {
        uint256 newVersion = SemVer.packSemVer(0, 1, 1);
        baseZkSyncUpgrade.setProtocolVersion(SemVer.packSemVer(0, 1, 0));
        protocolVersion = newVersion;

        vm.expectRevert(abi.encodeWithSelector(PatchCantSetUpgradeTxn.selector));
        _upgrade();
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
        protocolVersion = semVerNewProtocolVersion;
        l2CanonicalTransaction.nonce = nonce;

        vm.expectRevert(
            abi.encodeWithSelector(L2UpgradeNonceNotEqualToNewProtocolVersion.selector, nonce, newProtocolVersion)
        );
        _upgrade();
    }

    // Factory deps can be at most 64 (MAX_NEW_FACTORY_DEPS)
    function test_revertWhen_FactoryDepsCanBeAtMost64(uint8 maxNewFactoryDeps) public {
        vm.assume(maxNewFactoryDeps > MAX_NEW_FACTORY_DEPS);

        l2CanonicalTransaction.factoryDeps = new uint256[](maxNewFactoryDeps);

        vm.expectRevert(abi.encodeWithSelector(TooManyFactoryDeps.selector));
        _upgrade();
    }

    // Upgrade with a factory dep hash
    function test_upgrade_WithFactoryDepHash() public {
        bytes memory factoryDep = hex"6001600055";
        l2CanonicalTransaction.factoryDeps = new uint256[](1);
        l2CanonicalTransaction.factoryDeps[0] = uint256(ZKSyncOSBytecodeInfo.hashEVMBytecode(factoryDep));
        bytes32 expectedTxHash = keccak256(abi.encode(l2CanonicalTransaction));

        bytes32 txHash = _upgrade();

        assertEq(txHash, expectedTxHash);
        assertEq(baseZkSyncUpgrade.getProtocolVersion(), protocolVersion);
    }

    function test_SuccessWith_TxTypeIsZero() public {
        l2CanonicalTransaction.txType = 0;

        bytes32 txHash = _upgrade();

        assertEq(txHash, bytes32(0), "no transaction was set");
        assertEq(baseZkSyncUpgrade.getProtocolVersion(), protocolVersion);
        assertEq(baseZkSyncUpgrade.getL2SystemContractsUpgradeTxHash(), bytes32(0));
    }

    function test_SuccessUpgrade() public {
        bytes32 expectedHash = keccak256(abi.encode(l2CanonicalTransaction));
        L2CanonicalTransaction memory expectedTx = l2CanonicalTransaction;

        vm.expectEmit(address(baseZkSyncUpgrade));
        emit BaseZkSyncUpgrade.NewProtocolVersion(0, protocolVersion);
        vm.expectEmit(address(baseZkSyncUpgrade));
        emit BaseZkSyncUpgrade.NewVerifier(address(0), verifier);
        vm.expectEmit(address(baseZkSyncUpgrade));
        emit BaseZkSyncUpgrade.UpgradeComplete(protocolVersion, expectedHash, expectedTx);
        bytes32 txHash = _upgrade();

        assertEq(txHash, expectedHash, "the hash of the committed transaction is returned");
        assertEq(baseZkSyncUpgrade.getProtocolVersion(), protocolVersion);
        assertEq(baseZkSyncUpgrade.getVerifier(), verifier);
        assertEq(baseZkSyncUpgrade.getL2SystemContractsUpgradeTxHash(), expectedHash);
    }

    /// @dev A zero verifier means "leave unchanged" — it is how the genesis upgrade runs after
    ///      `DiamondInit` has already installed the release's verifier.
    function test_zeroVerifierLeavesTheInstalledOneUnchanged() public {
        // Install a verifier first (genesis does this via `DiamondInit`), then upgrade with zero.
        _upgrade();
        address installed = baseZkSyncUpgrade.getVerifier();
        assertEq(installed, verifier, "the first upgrade must install the verifier");

        // A patch bump: same minor, so no L2 upgrade transaction has to be finalized first.
        protocolVersion = protocolVersion + 1;
        verifier = address(0);
        delete l2CanonicalTransaction;

        _upgrade();

        assertEq(baseZkSyncUpgrade.getVerifier(), installed, "zero must not clear the verifier");
    }

    /// @notice A chain that required its second proof system can't upgrade to a verifier without it.
    /// See {protocol-docs/interop-gating.md#second-proof-system-requirement}.
    function test_revertWhen_RequiringChainUpgradesToSingleProofVerifier() public {
        verifier = _singleProofVerifier();
        baseZkSyncUpgrade.setSecondProofSystemRequired(true);
        uint256 versionBefore = baseZkSyncUpgrade.getProtocolVersion();
        address verifierBefore = baseZkSyncUpgrade.getVerifier();

        vm.expectRevert(abi.encodeWithSelector(NotMultiProofMode.selector, ZKSYNC_OS_PLONK_VERIFICATION_TYPE));
        _upgrade();

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), versionBefore);
        assertEq(baseZkSyncUpgrade.getVerifier(), verifierBefore);
    }

    function test_RequiringChainUpgradesToMultiProofVerifier() public {
        _assertRequiringChainUpgradesToMultiProofVerifier(0);
    }

    /// @notice The requirement checks what the new verifier supports, not the chain's current disable flags, so a
    /// chain under it still upgrades after governance switched ZiSK off, and ZiSK stays off.
    function test_RequiringChainUpgradesAfterEmergencyZiskOff() public {
        _assertRequiringChainUpgradesToMultiProofVerifier(uint8(1 << uint8(ProofSystem.Zisk)));
    }

    function test_UnlockedChainUpgradesToSingleProofVerifier() public {
        verifier = _singleProofVerifier();

        _upgrade();

        assertEq(baseZkSyncUpgrade.getVerifier(), verifier);
        assertEq(baseZkSyncUpgrade.getProtocolVersion(), protocolVersion);
    }

    /// @notice An upgrade that keeps the installed verifier runs no check: the requirement was met when it was installed.
    function test_RequiringChainUpgradesKeepingItsVerifier() public {
        address multiProofVerifier = _multiProofVerifier();
        baseZkSyncUpgrade.setVerifier(multiProofVerifier);
        baseZkSyncUpgrade.setSecondProofSystemRequired(true);
        verifier = address(0);

        _upgrade();

        assertEq(baseZkSyncUpgrade.getVerifier(), multiProofVerifier);
        assertEq(baseZkSyncUpgrade.getProtocolVersion(), protocolVersion);
    }

    function _assertRequiringChainUpgradesToMultiProofVerifier(uint8 _disabledProofSystems) internal {
        address multiProofVerifier = _multiProofVerifier();
        verifier = multiProofVerifier;
        baseZkSyncUpgrade.setSecondProofSystemRequired(true);
        baseZkSyncUpgrade.setDisabledProofSystems(_disabledProofSystems);
        address verifierBefore = baseZkSyncUpgrade.getVerifier();

        vm.expectEmit(true, true, false, true, address(baseZkSyncUpgrade));
        emit BaseZkSyncUpgrade.NewVerifier(verifierBefore, multiProofVerifier);
        _upgrade();

        assertEq(baseZkSyncUpgrade.getVerifier(), multiProofVerifier);
        assertEq(baseZkSyncUpgrade.getProtocolVersion(), protocolVersion);
        assertTrue(baseZkSyncUpgrade.getSecondProofSystemRequired(), "the upgrade must keep the requirement");
        assertEq(baseZkSyncUpgrade.getDisabledProofSystems(), _disabledProofSystems, "the upgrade keeps the flags");
        assertEq(
            baseZkSyncUpgrade.getProofMode(),
            _disabledProofSystems == 0 ? ZKSYNC_OS_MULTI_PROOF_VERIFICATION_TYPE : ZKSYNC_OS_PLONK_VERIFICATION_TYPE
        );
    }

    function _singleProofVerifier() internal returns (address) {
        return address(new ZKsyncOSVerifier(IVerifier(makeAddr("airbenderPlonk"))));
    }

    function _multiProofVerifier() internal returns (address) {
        return
            address(
                new MultiProofVerifier(IVerifier(makeAddr("airbenderVerifier")), IVerifier(makeAddr("ziskVerifier")))
            );
    }
}
