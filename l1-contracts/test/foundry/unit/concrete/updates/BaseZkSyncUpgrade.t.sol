// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {BaseZkSyncUpgrade, ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {MAX_NEW_FACTORY_DEPS, SYSTEM_UPGRADE_L2_TX_TYPE, MAX_ALLOWED_PROTOCOL_VERSION_DELTA} from "contracts/common/Config.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeSetters} from "./_SharedBaseUpgradeSetters.t.sol";

contract DummyBaseZkSyncUpgrade is BaseZkSyncUpgrade, BaseUpgradeSetters {}

contract BaseZkSyncUpgradeTest is BaseUpgrade {
    DummyBaseZkSyncUpgrade baseZkSyncUpgrade;

    function setUp() public {
        baseZkSyncUpgrade = new DummyBaseZkSyncUpgrade();

        _prepereProposedUpgrade();

        baseZkSyncUpgrade.setPriorityTxMaxGasLimit(1 ether);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(1000000);
    }

    // Upgrade is not ready yet
    function test_revertWhen_UpgradeIsNotReady(uint256 upgradeTimestamp) public {
        vm.assume(upgradeTimestamp > block.timestamp);

        proposedUpgrade.upgradeTimestamp = upgradeTimestamp;

        vm.expectRevert(bytes("Upgrade is not ready yet"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // New protocol version is not greater than the current one
    function test_revertWhen_newProtocolVersionIsNotGreaterThanTheCurrentOne(
        uint256 currentProtocolVersion,
        uint256 newProtocolVersion
    ) public {
        baseZkSyncUpgrade.setProtocolVersion(currentProtocolVersion);

        vm.assume(newProtocolVersion <= currentProtocolVersion && newProtocolVersion > 0);

        proposedUpgrade.newProtocolVersion = newProtocolVersion;

        vm.expectRevert(bytes("New protocol version is not greater than the current one"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Protocol version difference is too big
    function test_revertWhen_tooBigProtocolVersionDifference(uint256 newProtocolVersion) public {
        vm.assume(newProtocolVersion > MAX_ALLOWED_PROTOCOL_VERSION_DELTA);

        proposedUpgrade.newProtocolVersion = newProtocolVersion;

        vm.expectRevert(bytes("Too big protocol version difference"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Previous upgrade has not been finalized
    function test_revertWhen_previousUpgradeHasNotBeenFinalized() public {
        baseZkSyncUpgrade.setL2SystemContractsUpgradeTxHash(bytes32(bytes("txHash")));

        vm.expectRevert(bytes("Previous upgrade has not been finalized"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Batch number of the previous upgrade has not been cleaned
    function test_revertWhen_batchNumberOfThePreviousUpgradeHasNotBeenCleaned(uint256 batchNumber) public {
        vm.assume(batchNumber > 0);

        baseZkSyncUpgrade.setL2SystemContractsUpgradeBatchNumber(batchNumber);

        vm.expectRevert(bytes("The batch number of the previous upgrade has not been cleaned"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // L2 system upgrade tx type is wrong
    function test_revertWhen_L2SystemUpgradeTxTypeIsWrong(uint256 newTxType) public {
        vm.assume(newTxType != SYSTEM_UPGRADE_L2_TX_TYPE && newTxType > 0);

        proposedUpgrade.l2ProtocolUpgradeTx.txType = newTxType;

        vm.expectRevert(bytes("L2 system upgrade tx type is wrong"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // The new protocol version should be included in the L2 system upgrade tx
    function test_revertWhen_NewProtocolVersionIsNotIncludedInL2SystemUpgradeTx(
        uint256 currentProtocolVersion,
        uint256 newProtocolVersion,
        uint256 nonce
    ) public {
        baseZkSyncUpgrade.setProtocolVersion(currentProtocolVersion);

        vm.assume(
            newProtocolVersion > currentProtocolVersion &&
                newProtocolVersion - currentProtocolVersion < MAX_ALLOWED_PROTOCOL_VERSION_DELTA
        );
        vm.assume(nonce != newProtocolVersion && nonce > 0);

        proposedUpgrade.newProtocolVersion = newProtocolVersion;
        proposedUpgrade.l2ProtocolUpgradeTx.nonce = nonce;

        vm.expectRevert(bytes("The new protocol version should be included in the L2 system upgrade tx"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Wrong number of factory deps
    function test_revertWhen_WrongNumberOfFactoryDeps() public {
        proposedUpgrade.factoryDeps = new bytes[](1);
        proposedUpgrade.l2ProtocolUpgradeTx.factoryDeps = new uint256[](2);

        vm.expectRevert(bytes("Wrong number of factory deps"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Factory deps can be at most 32
    function test_revertWhen_FactoryDepsCanBeAtMost32(uint8 maxNewFactoryDeps) public {
        vm.assume(maxNewFactoryDeps > MAX_NEW_FACTORY_DEPS);

        proposedUpgrade.factoryDeps = new bytes[](maxNewFactoryDeps);
        proposedUpgrade.l2ProtocolUpgradeTx.factoryDeps = new uint256[](maxNewFactoryDeps);

        vm.expectRevert(bytes("Factory deps can be at most 32"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    // Wrong factory dep hash
    function test_revertWhen_WrongFactoryDepHash() public {
        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = "11111111111111111111111111111111";

        proposedUpgrade.factoryDeps = factoryDeps;
        proposedUpgrade.l2ProtocolUpgradeTx.factoryDeps = new uint256[](1);

        vm.expectRevert(bytes("Wrong factory dep hash"));
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_SuccessWith_VerifierAddressIsZero() public {
        proposedUpgrade.verifier = address(0);

        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_SuccessWith_NewVerifierParamsIsZero() public {
        proposedUpgrade.verifierParams = VerifierParams({
            recursionNodeLevelVkHash: bytes32(0),
            recursionLeafLevelVkHash: bytes32(0),
            recursionCircuitsSetVksHash: bytes32(0)
        });

        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_SuccessWith_L2BootloaderBytecodeHashIsZero() public {
        proposedUpgrade.bootloaderHash = bytes32(0);

        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_SuccessWith_L2DefaultAccountBytecodeHashIsZero() public {
        proposedUpgrade.defaultAccountHash = bytes32(0);

        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_SuccessWith_TxTypeIsZero() public {
        proposedUpgrade.l2ProtocolUpgradeTx.txType = 0;

        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    function test_SuccessUpdate() public {
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }
}
