// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {UpgradeChainCall} from "deploy-scripts/utils/UpgradeChainCall.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";

/// @notice The upgrade-call encoder serves only chains that read their cut from their
///         ChainTypeManager (v35+); calling a pre-v35 chain with this shape would hit the
///         DiamondProxy fallback and revert with `"F"`, so the encoder refuses it up front.
contract UpgradeChainCallTest is Test {
    address internal constant CHAIN = address(0xC4A15);

    function _version(uint256 _minor) private pure returns (uint256) {
        return _minor << 32;
    }

    function test_v35EncodesTheCutReadingCall() public pure {
        assertEq(
            UpgradeChainCall.encode(CHAIN, _version(35)),
            abi.encodeCall(IAdmin.upgradeChainFromVersion, (CHAIN, _version(35))),
            "no cut is carried"
        );
    }

    function test_revertWhen_theChainPredatesTheCutReadingEntrypoint() public {
        vm.expectRevert("chain predates the cut-reading entrypoint");
        this.encodeExternal(CHAIN, _version(34));
    }

    /// @dev External so `expectRevert` sees the library's revert at a call boundary.
    function encodeExternal(address _chainAddress, uint256 _protocolVersion) external pure returns (bytes memory) {
        return UpgradeChainCall.encode(_chainAddress, _protocolVersion);
    }
}
