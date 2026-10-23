// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ZKChainBase} from "contracts/state-transition/chain-deps/facets/ZKChainBase.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {LegacyTestAdminFacet} from "contracts/dev-contracts/test/LegacyTestAdminFacet.sol";
import {HashMismatch} from "contracts/common/L1ContractErrors.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

/// @notice Stands in for the engine a legacy-committed edge points at: it only moves the chain's
///         version, which is all the cut-taking entrypoint checks after running the cut.
contract VersionBumpInitForTest is ZKChainBase {
    function bump(uint256 _newProtocolVersion) external returns (bytes32) {
        s.protocolVersion = _newProtocolVersion;
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

/// @notice The CTM owner's checked crossing of a chain still on a pre-v35 Admin facet
///         (`upgradeChainFromVersion(chainId, old, cut)`): the CTM hands the cut to the chain's
///         cut-taking entrypoint, which checks it against the cut hash the legacy commit stored.
/// @dev The chain is a fixture diamond with `LegacyTestAdminFacet` installed, the facet the anvil
///      bootstrap stage also uses to stand in for a pre-v35 Admin facet. The real bootstrap edge
///      crossed this way is covered in `UpgradeTest_Local.t.sol`.
contract UpgradeChainFromVersionWithCutTest is ChainTypeManagerTest {
    uint256 internal constant NEW_VERSION = 1 << 32;
    uint256 internal constant OLD_VERSION_DEADLINE = 1000;

    address internal chainAddress;
    address internal versionBumpInit;

    function setUp() public {
        deploy();
        chainAddress = createNewChain(getDiamondCutData(diamondInit));
        _mockGetZKChainFromBridgehub(chainAddress);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = LegacyTestAdminFacet.upgradeChainFromVersion.selector;
        Diamond.FacetCut[] memory legacyFacet = new Diamond.FacetCut[](1);
        legacyFacet[0] = Diamond.FacetCut({
            facet: address(new LegacyTestAdminFacet()),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors
        });
        vm.prank(governor);
        chainContractAddress.executeUpgrade(
            chainId,
            Diamond.DiamondCutData({facetCuts: legacyFacet, initAddress: address(0), initCalldata: ""})
        );

        versionBumpInit = address(new VersionBumpInitForTest());
        vm.prank(governor);
        chainContractAddress.setNewVersionUpgrade(
            _bumpCut(NEW_VERSION),
            0,
            OLD_VERSION_DEADLINE,
            _releaseAt(NEW_VERSION)
        );
    }

    function _bumpCut(uint256 _newProtocolVersion) internal view returns (Diamond.DiamondCutData memory) {
        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: versionBumpInit,
                initCalldata: abi.encodeCall(VersionBumpInitForTest.bump, (_newProtocolVersion))
            });
    }

    function test_theOwnerCrossesAPreV35ChainWithTheCommittedCut() public {
        Diamond.DiamondCutData memory committedCut = _bumpCut(NEW_VERSION);
        vm.expectEmit(true, true, true, true, chainAddress);
        emit LegacyTestAdminFacet.ExecuteUpgrade(committedCut);
        vm.prank(governor);
        chainContractAddress.upgradeChainFromVersion(chainId, 0, committedCut);

        assertEq(IGetters(chainAddress).getProtocolVersion(), NEW_VERSION, "the chain crossed the edge");
    }

    function test_revertWhen_theHandedCutIsNotTheCommittedOne() public {
        Diamond.DiamondCutData memory otherCut = _bumpCut(SemVer.packSemVer(0, 2, 0));

        vm.expectRevert(
            abi.encodeWithSelector(
                HashMismatch.selector,
                chainContractAddress.upgradeCutHash(0),
                keccak256(abi.encode(otherCut))
            )
        );
        vm.prank(governor);
        chainContractAddress.upgradeChainFromVersion(chainId, 0, otherCut);

        assertEq(IGetters(chainAddress).getProtocolVersion(), 0, "the chain did not move");
    }

    function test_revertWhen_theCallerIsNotTheOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        chainContractAddress.upgradeChainFromVersion(chainId, 0, _bumpCut(NEW_VERSION));

        assertEq(IGetters(chainAddress).getProtocolVersion(), 0, "the chain did not move");
    }
}
