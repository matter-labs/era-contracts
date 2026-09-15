// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IAdminPreV31, IAdminV31, UpgradeChainCall} from "deploy-scripts/utils/UpgradeChainCall.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";

/// @notice The upgrade-call encoder picks its shape from the version the chain is CURRENTLY on;
///         calling the wrong shape hits the DiamondProxy fallback and reverts with `"F"`.
contract UpgradeChainCallTest is Test {
    address internal constant CHAIN = address(0xC4A15);

    function _version(uint256 _minor) private pure returns (uint256) {
        return _minor << 32;
    }

    function _cut() private pure returns (Diamond.DiamondCutData memory) {
        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: address(0xBEEF),
                initCalldata: hex"1234"
            });
    }

    function test_preV31TakesTheTwoArgumentLegacyShape() public pure {
        assertEq(
            UpgradeChainCall.encode(CHAIN, _version(30), _cut()),
            abi.encodeCall(IAdminPreV31.upgradeChainFromVersion, (_version(30), _cut())),
            "a pre-v31 chain is called without its own address"
        );
    }

    function test_v31TakesTheChainAddressedCutShape() public pure {
        assertEq(
            UpgradeChainCall.encode(CHAIN, _version(31), _cut()),
            abi.encodeCall(IAdminV31.upgradeChainFromVersion, (CHAIN, _version(31), _cut())),
            "v31 added the leading chain address"
        );
    }

    /// @dev The three shapes must be mutually distinct — the whole reason the encoder selects by
    ///      the chain's current version rather than encoding one shape for everyone.
    function test_theThreeShapesAreDistinct() public pure {
        bytes4 preV31 = bytes4(UpgradeChainCall.encode(CHAIN, _version(30), _cut()));
        bytes4 v31 = bytes4(UpgradeChainCall.encode(CHAIN, _version(31), _cut()));
        bytes4 v34 = bytes4(UpgradeChainCall.encode(CHAIN, _version(34), _cut()));
        assertTrue(preV31 != v31 && v31 != v34 && preV31 != v34, "shapes must not collide");
    }

    /// @dev v32 and v33 still ship the cut-taking facet, so the boundary is v34 and not the version
    ///      at which the CTM stopped needing a handed cut.
    function test_v33StillTakesTheCut() public pure {
        assertTrue(UpgradeChainCall.requiresCut(_version(33)), "v33 is handed its cut");
        assertFalse(UpgradeChainCall.requiresCut(_version(34)), "v34 reads its own");
    }

    function test_v34EncodesTheCutReadingCall() public pure {
        bytes memory encoded = UpgradeChainCall.encode(CHAIN, _version(34), _cut());
        assertEq(encoded, abi.encodeCall(IAdmin.upgradeChainFromVersion, (CHAIN, _version(34))), "no cut is carried");
    }

    /// @dev The property this encoder exists for: a v34+ caller holds no cut to hand over — a
    ///      registry-driven edge commits no log to reconstruct one from — so the bytes must not be
    ///      decoded before the shape is chosen.
    function test_v34EncodesWithoutTouchingTheEncodedCut() public pure {
        bytes memory encoded = UpgradeChainCall.encodeFromEncodedCut(CHAIN, _version(34), bytes(""));
        assertEq(encoded, UpgradeChainCall.encodeWithoutCut(CHAIN, _version(34)), "empty cut bytes are ignored");
    }

    function test_legacyDecodesTheEncodedCutItIsHanded() public pure {
        bytes memory encodedCut = abi.encode(_cut());
        assertEq(
            UpgradeChainCall.encodeFromEncodedCut(CHAIN, _version(31), encodedCut),
            UpgradeChainCall.encode(CHAIN, _version(31), _cut()),
            "the handed cut reaches the call"
        );
    }

    function test_revertWhen_encodingWithoutACutForAChainThatNeedsOne() public {
        vm.expectRevert("chain predates the cut-reading entrypoint");
        UpgradeChainCall.encodeWithoutCut(CHAIN, _version(33));
    }
}
