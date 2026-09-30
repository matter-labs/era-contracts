// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseZkSyncUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {V34UpgradeZKsyncOS} from "contracts/upgrades/V34UpgradeZKsyncOS.sol";
import {NotAllBatchesExecuted} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {DEFAULT_PRIORITY_TX_MAX_PUBDATA, PRIORITY_TX_MAX_GAS_LIMIT} from "contracts/common/Config.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {TEST_CHAIN_CONFIG_UPGRADE_VERSION} from "../../TestConstants.sol";
import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

// Isolate upgrade behavior from batch proving and CTM verifier registration.
contract V34UpgradeTestUtils is BaseUpgradeUtils {
    function setBatchCounters(uint256 _committed, uint256 _verified, uint256 _executed) external {
        s.totalBatchesCommitted = _committed;
        s.totalBatchesVerified = _verified;
        s.totalBatchesExecuted = _executed;
    }

    function getBatchCounters() external view returns (uint256, uint256, uint256) {
        return (s.totalBatchesCommitted, s.totalBatchesVerified, s.totalBatchesExecuted);
    }

    function getUpgradeTxHash() external view returns (bytes32) {
        return s.l2SystemContractsUpgradeTxHash;
    }
}

contract DummyV34Upgrade is V34UpgradeZKsyncOS, V34UpgradeTestUtils {}

contract V34UpgradeZKsyncOSTest is BaseUpgrade {
    DummyV34Upgrade internal upgrade;
    address internal mockVerifier = makeAddr("verifier");
    uint256 internal previousVersion;

    function setUp() public {
        upgrade = new DummyV34Upgrade();
        _prepareEmptyProposedUpgrade();
        previousVersion = SemVer.packSemVer(0, TEST_CHAIN_CONFIG_UPGRADE_VERSION - 1, 0);
        protocolVersion = SemVer.packSemVer(0, TEST_CHAIN_CONFIG_UPGRADE_VERSION, 0);
        proposedUpgrade.newProtocolVersion = protocolVersion;
        upgrade.setProtocolVersion(previousVersion);
        upgrade.setChainTypeManager(makeAddr("ctm"));
        upgrade.mockProtocolVersionVerifier(protocolVersion, mockVerifier);
    }

    // v34 inherits the default all-executed boundary: proved-but-unexecuted batches block the upgrade too.
    function testFuzz_RevertsWithUnexecutedBatches(uint64 _committed, uint64 _verified, uint64 _executed) public {
        uint256 committed = bound(_committed, 1, type(uint64).max);
        uint256 verified = bound(_verified, 0, committed);
        uint256 executed = bound(_executed, 0, verified == committed ? committed - 1 : verified);
        upgrade.setBatchCounters(committed, verified, executed);

        vm.recordLogs();
        vm.expectRevert(NotAllBatchesExecuted.selector);
        upgrade.upgrade(proposedUpgrade);

        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(upgrade.getProtocolVersion(), previousVersion);
        assertEq(upgrade.getVerifier(), address(0));
        _assertCounters(committed, verified, executed);
    }

    function test_RevertsWithVerifiedButUnexecutedBatch() public {
        upgrade.setBatchCounters(1, 1, 0);

        vm.expectRevert(NotAllBatchesExecuted.selector);
        upgrade.upgrade(proposedUpgrade);

        assertEq(upgrade.getProtocolVersion(), previousVersion);
        _assertCounters(1, 1, 0);
    }

    function testFuzz_UpgradesWithExecutedBatches(uint64 _batches) public {
        upgrade.setBatchCounters(_batches, _batches, _batches);
        _upgradeSuccessfully();
        _assertCounters(_batches, _batches, _batches);
    }

    function test_UpgradesWithoutBatches() public {
        _upgradeSuccessfully();
        _assertCounters(0, 0, 0);
    }

    function test_PreservesL2UpgradeTransaction() public {
        _prepareProposedUpgrade();
        protocolVersion = SemVer.packSemVer(0, TEST_CHAIN_CONFIG_UPGRADE_VERSION, 0);
        proposedUpgrade.newProtocolVersion = protocolVersion;
        proposedUpgrade.l2ProtocolUpgradeTx.nonce = TEST_CHAIN_CONFIG_UPGRADE_VERSION;
        proposedUpgrade.l2ProtocolUpgradeTx.to = uint256(uint160(L2_COMPLEX_UPGRADER_ADDR));
        proposedUpgrade.l2ProtocolUpgradeTx.data = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (new IComplexUpgrader.UniversalContractUpgradeInfo[](0), address(0), bytes(""))
        );
        upgrade.setPriorityTxMaxGasLimit(PRIORITY_TX_MAX_GAS_LIMIT);
        upgrade.setPriorityTxMaxPubdata(DEFAULT_PRIORITY_TX_MAX_PUBDATA);
        upgrade.setBatchCounters(1, 1, 1);

        _upgradeSuccessfully();
        assertEq(upgrade.getUpgradeTxHash(), keccak256(abi.encode(proposedUpgrade.l2ProtocolUpgradeTx)));
        _assertCounters(1, 1, 1);
    }

    function _upgradeSuccessfully() internal {
        vm.expectEmit(true, true, false, true, address(upgrade));
        emit BaseZkSyncUpgrade.NewProtocolVersion(previousVersion, protocolVersion);
        vm.expectEmit(true, true, false, true, address(upgrade));
        emit BaseZkSyncUpgrade.NewVerifier(address(0), mockVerifier);
        assertEq(upgrade.upgrade(proposedUpgrade), Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);
        assertEq(upgrade.getProtocolVersion(), protocolVersion);
        assertEq(upgrade.getVerifier(), mockVerifier);
    }

    function _assertCounters(uint256 _committed, uint256 _verified, uint256 _executed) internal view {
        (uint256 committed, uint256 verified, uint256 executed) = upgrade.getBatchCounters();
        assertEq(committed, _committed);
        assertEq(verified, _verified);
        assertEq(executed, _executed);
    }
}
