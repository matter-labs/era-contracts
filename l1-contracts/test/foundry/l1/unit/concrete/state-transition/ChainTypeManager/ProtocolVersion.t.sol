// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ProtocolIdNotGreater} from "contracts/common/L1ContractErrors.sol";
import {ProtocolVersionMismatch} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {ProposedUpgrade, ProposedUpgradeLib} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";

contract ProtocolVersion is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    /// @dev Builds a standard upgrade cut (`IDefaultUpgrade.upgrade(ProposedUpgrade)`) whose embedded
    /// `newProtocolVersion` equals `_embeddedVersion`.
    function _upgradeCutWithEmbeddedVersion(uint256 _embeddedVersion) internal returns (Diamond.DiamondCutData memory) {
        ProposedUpgrade memory proposedUpgrade = ProposedUpgradeLib.emptyProposedUpgrade(_embeddedVersion);
        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: address(new DefaultUpgrade()),
                initCalldata: abi.encodeCall(IDefaultUpgrade.upgrade, (proposedUpgrade))
            });
    }

    /// @dev When the upgrade cut is a standard `IDefaultUpgrade.upgrade` call, the protocol version embedded in
    /// the proposal must equal the version being registered. Otherwise the chain would move to the embedded
    /// version (whose deadline is never opened), bricking commits.
    function test_RevertWhen_setNewVersionUpgradeEmbeddedVersionMismatch() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));
        _mockGetZKChainFromBridgehub(chainAddress);
        _mockMigrationPausedFromBridgehub();

        uint256 argVersion = SemVer.packSemVer(0, 1, 0);
        uint256 embeddedVersion = SemVer.packSemVer(0, 2, 0); // intentionally mismatched

        Diamond.DiamondCutData memory cutData = _upgradeCutWithEmbeddedVersion(embeddedVersion);

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(ProtocolVersionMismatch.selector, embeddedVersion, argVersion));
        chainContractAddress.setNewVersionUpgrade(cutData, 0, 1000, argVersion, testnetVerifier);
    }

    /// @dev A matching embedded version is accepted (the common case, and what `createNewPatchUpgrade`
    /// constructs by hand).
    function test_SuccessfulSetNewVersionUpgradeWithMatchingEmbeddedVersion() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));
        _mockGetZKChainFromBridgehub(chainAddress);
        _mockMigrationPausedFromBridgehub();

        uint256 argVersion = SemVer.packSemVer(0, 1, 0);
        Diamond.DiamondCutData memory cutData = _upgradeCutWithEmbeddedVersion(argVersion);

        vm.prank(governor);
        chainContractAddress.setNewVersionUpgrade(cutData, 0, 1000, argVersion, testnetVerifier);

        assertEq(chainContractAddress.protocolVersion(), argVersion);
    }

    // setNewVersionUpgrade
    function test_SuccessfulSetNewVersionUpgrade() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));

        uint256 oldProtocolVersion = chainContractAddress.protocolVersion();
        uint256 oldProtocolVersionDeadline = chainContractAddress.protocolVersionDeadline(oldProtocolVersion);

        assertEq(oldProtocolVersion, 0);
        assertEq(oldProtocolVersionDeadline, type(uint256).max);

        uint256 newProtocolVersionSemVer = SemVer.packSemVer(0, 1, 0);

        _mockGetZKChainFromBridgehub(chainAddress);
        _mockMigrationPausedFromBridgehub();

        vm.startPrank(governor);
        chainContractAddress.setNewVersionUpgrade(
            getDiamondCutData(diamondInit),
            oldProtocolVersion,
            1000,
            newProtocolVersionSemVer,
            testnetVerifier
        );
        vm.stopPrank();

        uint256 newProtocolVersion = chainContractAddress.protocolVersion();
        uint256 newProtocolVersionDeadline = chainContractAddress.protocolVersionDeadline(newProtocolVersion);

        oldProtocolVersionDeadline = chainContractAddress.protocolVersionDeadline(oldProtocolVersion);

        (uint32 major, uint32 minor, uint32 patch) = chainContractAddress.getSemverProtocolVersion();

        assertEq(major, 0);
        assertEq(minor, 1);
        assertEq(patch, 0);
        assertEq(newProtocolVersion, newProtocolVersionSemVer);
        assertEq(newProtocolVersionDeadline, type(uint256).max);
        assertEq(oldProtocolVersionDeadline, 1000);
        assertEq(chainContractAddress.protocolVersionVerifier(newProtocolVersionSemVer), testnetVerifier);
    }

    // protocolVersionIsActive
    function test_SuccessfulProtocolVersionIsActive() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));

        assertEq(chainContractAddress.protocolVersionIsActive(0), true);

        _mockGetZKChainFromBridgehub(chainAddress);
        _mockMigrationPausedFromBridgehub();

        vm.startPrank(governor);
        chainContractAddress.setNewVersionUpgrade(getDiamondCutData(diamondInit), 0, 0, 1, testnetVerifier);
        vm.stopPrank();

        assertEq(chainContractAddress.protocolVersionIsActive(1), true);
    }

    // setProtocolVersionDeadline
    function test_SuccessfulSetProtocolVersionDeadline() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));

        uint256 deadlineBefore = chainContractAddress.protocolVersionDeadline(0);
        assertEq(deadlineBefore, type(uint256).max);

        uint256 newDeadline = 1000;

        _mockGetZKChainFromBridgehub(chainAddress);

        vm.prank(governor);
        chainContractAddress.setProtocolVersionDeadline(0, newDeadline);

        uint256 deadline = chainContractAddress.protocolVersionDeadline(0);
        assertEq(deadline, newDeadline);
    }

    // executeUpgrade
    function test_SuccessfulExecuteUpdate() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));

        Diamond.FacetCut[] memory customFacetCuts = new Diamond.FacetCut[](1);
        customFacetCuts[0] = Diamond.FacetCut({
            facet: facetCuts[2].facet,
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: facetCuts[2].selectors
        });

        _mockGetZKChainFromBridgehub(chainAddress);

        vm.prank(governor);
        chainContractAddress.executeUpgrade(chainId, getDiamondCutDataWithCustomFacets(address(0), customFacetCuts));
    }

    // upgradeChainFromVersion
    function test_SuccessfulUpgradeChainFromVersion() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));

        Diamond.FacetCut[] memory customFacetCuts = new Diamond.FacetCut[](1);
        customFacetCuts[0] = Diamond.FacetCut({
            facet: facetCuts[2].facet,
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: facetCuts[2].selectors
        });

        _mockGetZKChainFromBridgehub(chainAddress);
        _mockMigrationPausedFromBridgehub();

        vm.startPrank(governor);
        chainContractAddress.setNewVersionUpgrade(
            getDiamondCutDataWithCustomFacets(address(0), customFacetCuts),
            0,
            0,
            1,
            testnetVerifier
        );

        vm.expectRevert(ProtocolIdNotGreater.selector);
        chainContractAddress.upgradeChainFromVersion(
            chainId,
            0,
            getDiamondCutDataWithCustomFacets(address(0), customFacetCuts)
        );
    }
}
