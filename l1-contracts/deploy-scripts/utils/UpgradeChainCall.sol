// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";

/// @notice The cut-TAKING entrypoint, which v31 through v34 expose. v35 replaced it with the
///         cut-reading form on `IAdmin`.
interface IAdminWithCut {
    function upgradeChainFromVersion(
        address _chainAddress,
        uint256 _protocolVersion,
        Diamond.DiamondCutData calldata _cutData
    ) external;
}

/// @title Upgrade-call encoder for the chain diamonds this tooling supports.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice From v35 the chain reads the cut from its own ChainTypeManager, so the call carries no
///         cut at all; v31 through v34 are handed one.
/// @dev Calling the wrong shape hits the DiamondProxy fallback and reverts with `"F"`, so the
///      selection is by the version the chain is CURRENTLY on, never the one it moves to.
/// @dev The cut-reading 2-arg form first ships with the v35 facets: v31-v34 chains all route the
///      3-arg cut-taking form (the shipped v32 release kept it), so the boundary is the version
///      that first ships the new Admin facet, not the one where the CTM stopped needing the cut.
library UpgradeChainCall {
    uint256 internal constant V35_THRESHOLD = uint256(35) << 32;

    /// @notice Whether a chain on `_protocolVersion` must be HANDED the cut. False from v35: the
    ///         chain reads it from its own ChainTypeManager, so a caller must not reconstruct one
    ///         (registry-driven edges commit no `NewUpgradeCutData` log to reconstruct it from).
    function requiresCut(uint256 _protocolVersion) internal pure returns (bool) {
        return _protocolVersion < V35_THRESHOLD;
    }

    /// @notice The cut-READING call of a v35+ chain.
    function encodeWithoutCut(address _chainAddress, uint256 _protocolVersion) internal pure returns (bytes memory) {
        require(!requiresCut(_protocolVersion), "chain predates the cut-reading entrypoint");
        return abi.encodeCall(IAdmin.upgradeChainFromVersion, (_chainAddress, _protocolVersion));
    }

    /// @notice The upgrade call for a caller holding the cut in its ABI-encoded form.
    /// @dev Decodes `_encodedCutData` only on the generations that are HANDED a cut. A v35+ chain
    ///      reads its committed cut on-chain, so the bytes are never touched and a caller that has
    ///      none may pass empty ones — decoding first would revert on exactly the supported path.
    function encodeFromEncodedCut(
        address _chainAddress,
        uint256 _protocolVersion,
        bytes memory _encodedCutData
    ) internal pure returns (bytes memory) {
        if (!requiresCut(_protocolVersion)) {
            return encodeWithoutCut(_chainAddress, _protocolVersion);
        }
        return encode(_chainAddress, _protocolVersion, abi.decode(_encodedCutData, (Diamond.DiamondCutData)));
    }

    function encode(
        address _chainAddress,
        uint256 _protocolVersion,
        Diamond.DiamondCutData memory _cutData
    ) internal pure returns (bytes memory) {
        if (requiresCut(_protocolVersion)) {
            return abi.encodeCall(IAdminWithCut.upgradeChainFromVersion, (_chainAddress, _protocolVersion, _cutData));
        }
        return abi.encodeCall(IAdmin.upgradeChainFromVersion, (_chainAddress, _protocolVersion));
    }
}
