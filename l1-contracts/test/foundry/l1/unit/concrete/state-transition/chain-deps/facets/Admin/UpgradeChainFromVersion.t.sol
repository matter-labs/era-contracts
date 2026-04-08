// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {ProposedUpgrade, ProposedUpgradeLib} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {
    HashMismatch,
    ProtocolIdMismatch,
    ProtocolIdNotGreater,
    Unauthorized,
    UpgradeTimestampNotReached
} from "contracts/common/L1ContractErrors.sol";

contract UpgradeChainFromVersionTest is AdminTest {
    event ExecuteUpgrade(Diamond.DiamondCutData diamondCut);

    function test_revertWhen_calledByNonAdminOrChainTypeManager() public {
        address nonAdminOrChainTypeManager = makeAddr("nonAdminOrChainTypeManager");
        uint256 oldProtocolVersion = 1;
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: new bytes(0)
        });

        vm.startPrank(nonAdminOrChainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdminOrChainTypeManager));
        adminFacet.upgradeChainFromVersion(address(adminFacet), oldProtocolVersion, diamondCutData);
    }

    function test_revertWhen_cutHashMismatch() public {
        address admin = utilsFacet.util_getAdmin();
        address ctm = utilsFacet.util_getChainTypeManager();

        uint256 oldProtocolVersion = 1;
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: new bytes(0)
        });

        utilsFacet.util_setProtocolVersion(oldProtocolVersion);

        bytes32 cutHashInput = keccak256("random");
        vm.mockCall(ctm, abi.encodeWithSelector(IChainTypeManager.upgradeCutHash.selector), abi.encode(cutHashInput));

        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(HashMismatch.selector, cutHashInput, keccak256(abi.encode(diamondCutData)))
        );
        adminFacet.upgradeChainFromVersion(address(adminFacet), oldProtocolVersion, diamondCutData);
    }

    function test_revertWhen_ProtocolVersionMismatchWhenUpgrading() public {
        address admin = utilsFacet.util_getAdmin();
        address ctm = utilsFacet.util_getChainTypeManager();

        uint256 oldProtocolVersion = 1;
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: new bytes(0)
        });

        utilsFacet.util_setProtocolVersion(oldProtocolVersion + 1);

        bytes32 cutHashInput = keccak256(abi.encode(diamondCutData));
        vm.mockCall(ctm, abi.encodeWithSelector(IChainTypeManager.upgradeCutHash.selector), abi.encode(cutHashInput));

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(ProtocolIdMismatch.selector, uint256(2), oldProtocolVersion));
        adminFacet.upgradeChainFromVersion(address(adminFacet), oldProtocolVersion, diamondCutData);
    }

    function test_revertWhen_ProtocolVersionMismatchAfterUpgrading() public {
        address admin = utilsFacet.util_getAdmin();
        address ctm = utilsFacet.util_getChainTypeManager();

        uint256 oldProtocolVersion = 1;
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: new bytes(0)
        });

        utilsFacet.util_setProtocolVersion(oldProtocolVersion);

        bytes32 cutHashInput = keccak256(abi.encode(diamondCutData));
        vm.mockCall(ctm, abi.encodeWithSelector(IChainTypeManager.upgradeCutHash.selector), abi.encode(cutHashInput));

        vm.startPrank(admin);
        vm.expectRevert(ProtocolIdNotGreater.selector);
        adminFacet.upgradeChainFromVersion(address(adminFacet), oldProtocolVersion, diamondCutData);
    }

    // ============ Time-gate logic tests ============

    function test_revertWhen_validatorCallsBeforeTimestamp() public {
        address admin = utilsFacet.util_getAdmin();
        address ctm = utilsFacet.util_getChainTypeManager();
        address validatorAddr = makeAddr("validator");

        uint256 oldProtocolVersion = 1;
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: new bytes(0)
        });

        utilsFacet.util_setProtocolVersion(oldProtocolVersion);
        utilsFacet.util_setValidator(validatorAddr, true);

        bytes32 cutHashInput = keccak256(abi.encode(diamondCutData));
        vm.mockCall(ctm, abi.encodeWithSelector(IChainTypeManager.upgradeCutHash.selector), abi.encode(cutHashInput));

        // Set upgrade timestamp to 1000, current time is 500 (before timestamp)
        uint256 upgradeTimestamp = 1000;
        vm.warp(500);
        vm.mockCall(
            admin,
            abi.encodeWithSelector(IChainAdmin.protocolVersionToUpgradeTimestamp.selector, oldProtocolVersion),
            abi.encode(upgradeTimestamp)
        );

        vm.startPrank(validatorAddr);
        vm.expectRevert(abi.encodeWithSelector(UpgradeTimestampNotReached.selector, upgradeTimestamp, 500));
        adminFacet.upgradeChainFromVersion(address(adminFacet), oldProtocolVersion, diamondCutData);
    }

    function test_revertWhen_validatorCallsWithTimestampZero() public {
        address admin = utilsFacet.util_getAdmin();
        address ctm = utilsFacet.util_getChainTypeManager();
        address validatorAddr = makeAddr("validator");

        uint256 oldProtocolVersion = 1;
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: new bytes(0)
        });

        utilsFacet.util_setProtocolVersion(oldProtocolVersion);
        utilsFacet.util_setValidator(validatorAddr, true);

        bytes32 cutHashInput = keccak256(abi.encode(diamondCutData));
        vm.mockCall(ctm, abi.encodeWithSelector(IChainTypeManager.upgradeCutHash.selector), abi.encode(cutHashInput));

        // Timestamp 0 means no timestamp was set -- validator should NOT be able to upgrade
        vm.warp(1000);
        vm.mockCall(
            admin,
            abi.encodeWithSelector(IChainAdmin.protocolVersionToUpgradeTimestamp.selector, oldProtocolVersion),
            abi.encode(uint256(0))
        );

        vm.startPrank(validatorAddr);
        vm.expectRevert(abi.encodeWithSelector(UpgradeTimestampNotReached.selector, uint256(0), uint256(1000)));
        adminFacet.upgradeChainFromVersion(address(adminFacet), oldProtocolVersion, diamondCutData);
    }

    function test_validatorCallsAfterTimestamp() public {
        address admin = utilsFacet.util_getAdmin();
        address ctm = utilsFacet.util_getChainTypeManager();
        address validatorAddr = makeAddr("validator");
        address mockVerifier = makeAddr("mockVerifier");

        uint256 oldProtocolVersion = 1;
        uint256 newProtocolVersion = SemVer.packSemVer(0, 1, 0);

        // Build a real upgrade via DefaultUpgrade that bumps the protocol version
        DefaultUpgrade defaultUpgrade = new DefaultUpgrade();
        ProposedUpgrade memory proposedUpgrade = ProposedUpgradeLib.emptyProposedUpgrade(newProtocolVersion);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(defaultUpgrade),
            initCalldata: abi.encodeCall(IDefaultUpgrade.upgrade, (proposedUpgrade))
        });

        utilsFacet.util_setProtocolVersion(oldProtocolVersion);
        utilsFacet.util_setValidator(validatorAddr, true);

        bytes32 cutHashInput = keccak256(abi.encode(diamondCutData));
        vm.mockCall(
            ctm,
            abi.encodeWithSelector(IChainTypeManager.upgradeCutHash.selector, oldProtocolVersion),
            abi.encode(cutHashInput)
        );
        vm.mockCall(
            ctm,
            abi.encodeWithSelector(IChainTypeManager.protocolVersionVerifier.selector, newProtocolVersion),
            abi.encode(mockVerifier)
        );

        // Set upgrade timestamp to 1000, warp to exactly that time
        uint256 upgradeTimestamp = 1000;
        vm.warp(upgradeTimestamp);
        vm.mockCall(
            admin,
            abi.encodeWithSelector(IChainAdmin.protocolVersionToUpgradeTimestamp.selector, oldProtocolVersion),
            abi.encode(upgradeTimestamp)
        );

        vm.startPrank(validatorAddr);
        adminFacet.upgradeChainFromVersion(address(adminFacet), oldProtocolVersion, diamondCutData);

        // Verify the protocol version was actually bumped
        assertEq(utilsFacet.util_getProtocolVersion(), newProtocolVersion);
    }

    function test_adminBypassesTimeGate() public {
        address admin = utilsFacet.util_getAdmin();
        address ctm = utilsFacet.util_getChainTypeManager();

        uint256 oldProtocolVersion = 1;
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: new bytes(0)
        });

        utilsFacet.util_setProtocolVersion(oldProtocolVersion);

        bytes32 cutHashInput = keccak256(abi.encode(diamondCutData));
        vm.mockCall(ctm, abi.encodeWithSelector(IChainTypeManager.upgradeCutHash.selector), abi.encode(cutHashInput));

        // Even though timestamp is not set (0) and block.timestamp is 0,
        // admin should bypass the time-gate entirely.
        vm.warp(0);

        // The diamond cut is a no-op so it will revert with ProtocolIdNotGreater.
        // This proves admin bypasses the time-gate check.
        vm.startPrank(admin);
        vm.expectRevert(ProtocolIdNotGreater.selector);
        adminFacet.upgradeChainFromVersion(address(adminFacet), oldProtocolVersion, diamondCutData);
    }

    function test_chainTypeManagerBypassesTimeGate() public {
        address ctm = utilsFacet.util_getChainTypeManager();

        uint256 oldProtocolVersion = 1;
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: new bytes(0)
        });

        utilsFacet.util_setProtocolVersion(oldProtocolVersion);

        bytes32 cutHashInput = keccak256(abi.encode(diamondCutData));
        vm.mockCall(ctm, abi.encodeWithSelector(IChainTypeManager.upgradeCutHash.selector), abi.encode(cutHashInput));

        vm.warp(0);

        // ChainTypeManager should also bypass the time-gate.
        vm.startPrank(ctm);
        vm.expectRevert(ProtocolIdNotGreater.selector);
        adminFacet.upgradeChainFromVersion(address(adminFacet), oldProtocolVersion, diamondCutData);
    }
}
