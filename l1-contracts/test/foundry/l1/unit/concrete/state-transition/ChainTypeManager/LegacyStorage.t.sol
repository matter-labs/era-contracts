// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {ICommittedUpgrade} from "contracts/upgrades/registry/objects/ICommittedUpgrade.sol";
import {L2UpgradePlan} from "contracts/upgrades/registry/RegistryTypes.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";

/// @notice The registry fields sit past the v34 layout, whose last slots live CTMs still hold
///         values in: the `__DEPRECATED_` declarations reserve them.
/// @dev Slot numbers are the `forge inspect ... storageLayout` of `ChainTypeManager` on
///      `draft/v0.34.0`: `protocolVersionVerifier` at 168 and `defaultUpgrade` at 169, the last
///      v34 slot.
contract ChainTypeManagerLegacyStorageTest is ChainTypeManagerTest {
    uint256 internal constant V34_DEFAULT_UPGRADE_SLOT = 169;
    uint256 internal constant CURRENT_RELEASE_SLOT = 170;
    uint256 internal constant UPGRADE_TRANSITION_SLOT = 171;

    uint256 internal constant NEW_VERSION = uint256(1) << 32;

    function setUp() public {
        deploy();
    }

    /// @dev Pins the registry fields' slots, so a declaration added above them fails here rather
    ///      than on a live CTM.
    function test_registryFieldsSitPastTheV34Layout() public {
        address newRelease = _releaseAt(NEW_VERSION);
        ICTMTransition transition = ICTMTransition(makeAddr("transition"));
        vm.etch(address(transition), hex"00");
        vm.mockCall(
            address(transition),
            abi.encodeCall(ICTMTransition.fromRelease, ()),
            abi.encode(Utils.TEST_GENESIS_REGISTRY)
        );
        vm.mockCall(address(transition), abi.encodeCall(ICTMTransition.oldProtocolVersion, ()), abi.encode(0));
        vm.mockCall(
            address(transition),
            abi.encodeCall(ICTMTransition.newProtocolVersion, ()),
            abi.encode(NEW_VERSION)
        );
        vm.mockCall(address(transition), abi.encodeCall(ICTMTransition.newRelease, ()), abi.encode(newRelease));
        vm.mockCall(
            address(transition),
            abi.encodeCall(ICTMTransition.chainUpgradeEngine, ()),
            abi.encode(makeAddr("chainUpgradeEngine"))
        );
        vm.mockCall(address(transition), abi.encodeCall(ICTMTransition.validate, ()), "");
        L2UpgradePlan memory emptyPlan;
        vm.mockCall(address(transition), abi.encodeCall(ICommittedUpgrade.l2Plan, ()), abi.encode(emptyPlan));

        vm.prank(governor);
        chainContractAddress.setNewVersionUpgradeFromTransition(transition);

        assertEq(
            vm.load(address(chainContractAddress), bytes32(CURRENT_RELEASE_SLOT)),
            bytes32(uint256(uint160(newRelease))),
            "currentRelease slot"
        );
        assertEq(
            vm.load(address(chainContractAddress), keccak256(abi.encode(uint256(0), UPGRADE_TRANSITION_SLOT))),
            bytes32(uint256(uint160(address(transition)))),
            "upgradeTransition slot"
        );
        assertEq(
            vm.load(address(chainContractAddress), bytes32(V34_DEFAULT_UPGRADE_SLOT)),
            bytes32(0),
            "the registry model never writes the v34 defaultUpgrade slot"
        );
    }
}
