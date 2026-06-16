// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {NonEmptyCalldata} from "contracts/common/L1ContractErrors.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummyDefaultUpgrade is DefaultUpgrade, BaseUpgradeUtils {}

contract DefaultUpgradeTest is BaseUpgrade {
    DummyDefaultUpgrade baseZkSyncUpgrade;
    address mockChainTypeManager = makeAddr("mockChainTypeManager");
    address mockVerifier = makeAddr("mockVerifier");

    function setUp() public {
        baseZkSyncUpgrade = new DummyDefaultUpgrade();

        _prepareProposedUpgrade();
        // `DefaultUpgrade` does not consume `l1ContractsUpgradeCalldata`/`postUpgradeCalldata`, so it requires
        // both to be empty. The shared fixture sets a non-empty `postUpgradeCalldata`; clear it for the
        // happy-path test (the rejection of non-empty calldata is covered by the dedicated tests below).
        proposedUpgrade.l1ContractsUpgradeCalldata = new bytes(0);
        proposedUpgrade.postUpgradeCalldata = new bytes(0);

        baseZkSyncUpgrade.setPriorityTxMaxGasLimit(1 ether);
        baseZkSyncUpgrade.setPriorityTxMaxPubdata(1000000);

        // Set up CTM for verifier lookup
        baseZkSyncUpgrade.setChainTypeManager(mockChainTypeManager);
        baseZkSyncUpgrade.mockProtocolVersionVerifier(protocolVersion, mockVerifier);
    }

    function test_SuccessUpgrade() public {
        bytes32 result = baseZkSyncUpgrade.upgrade(proposedUpgrade);

        assertEq(result, Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);

        assertEq(baseZkSyncUpgrade.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
        assertEq(baseZkSyncUpgrade.getL2DefaultAccountBytecodeHash(), proposedUpgrade.defaultAccountHash);
        assertEq(baseZkSyncUpgrade.getL2BootloaderBytecodeHash(), proposedUpgrade.bootloaderHash);
    }

    /// @dev `DefaultUpgrade` must reject `postUpgradeCalldata` it would otherwise silently discard, instead of
    /// completing the upgrade as a partial no-op.
    function test_RevertWhen_PostUpgradeCalldataNonEmpty() public {
        proposedUpgrade.postUpgradeCalldata = abi.encode(uint256(1));

        vm.expectRevert(NonEmptyCalldata.selector);
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }

    /// @dev Same as above, for `l1ContractsUpgradeCalldata`.
    function test_RevertWhen_L1ContractsUpgradeCalldataNonEmpty() public {
        proposedUpgrade.l1ContractsUpgradeCalldata = abi.encode(uint256(1));

        vm.expectRevert(NonEmptyCalldata.selector);
        baseZkSyncUpgrade.upgrade(proposedUpgrade);
    }
}
