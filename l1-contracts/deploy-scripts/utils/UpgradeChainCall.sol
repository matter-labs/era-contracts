// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";

/// @notice Pre-v31 chains expose `upgradeChainFromVersion(uint256,DiamondCutData)`.
interface IAdminPreV31 {
    function upgradeChainFromVersion(uint256 _protocolVersion, Diamond.DiamondCutData calldata _cutData) external;
}

/// @notice v31 chains added the leading `_chainAddress`.
interface IAdminV31 {
    function upgradeChainFromVersion(
        address _chainAddress,
        uint256 _protocolVersion,
        Diamond.DiamondCutData calldata _cutData
    ) external;
}

/// @title Upgrade-call encoder for chain diamonds of any protocol generation.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice `upgradeChainFromVersion` changed shape twice. From v34 the chain reads the cut from
///         its own ChainTypeManager, so the call carries no cut at all.
/// @dev Calling the wrong shape hits the DiamondProxy fallback and reverts with `"F"`, so the
///      selection is by the version the chain is CURRENTLY on, never the one it moves to.
/// @dev The cut-reading 2-arg form first ships with the v34 facets: v31-v33 chains all route the
///      3-arg cut-taking form (the shipped v32 release kept it), so the boundary is the version
///      that first ships the new Admin facet, not the one where the CTM stopped needing the cut.
library UpgradeChainCall {
    uint256 internal constant V31_THRESHOLD = uint256(31) << 32;
    uint256 internal constant V34_THRESHOLD = uint256(34) << 32;

    /// @notice Whether a chain on `_protocolVersion` must be HANDED the cut. False from v34: the
    ///         chain reads it from its own ChainTypeManager, so a caller must not reconstruct one
    ///         (registry-driven edges commit no `NewUpgradeCutData` log to reconstruct it from).
    function requiresCut(uint256 _protocolVersion) internal pure returns (bool) {
        return _protocolVersion < V34_THRESHOLD;
    }

    /// @notice The cut-READING call of a v34+ chain.
    function encodeWithoutCut(address _chainAddress, uint256 _protocolVersion) internal pure returns (bytes memory) {
        require(!requiresCut(_protocolVersion), "chain predates the cut-reading entrypoint");
        return abi.encodeCall(IAdmin.upgradeChainFromVersion, (_chainAddress, _protocolVersion));
    }

    function encode(
        address _chainAddress,
        uint256 _protocolVersion,
        Diamond.DiamondCutData memory _cutData
    ) internal pure returns (bytes memory) {
        if (_protocolVersion < V31_THRESHOLD) {
            return abi.encodeCall(IAdminPreV31.upgradeChainFromVersion, (_protocolVersion, _cutData));
        }
        if (_protocolVersion < V34_THRESHOLD) {
            return abi.encodeCall(IAdminV31.upgradeChainFromVersion, (_chainAddress, _protocolVersion, _cutData));
        }
        return abi.encodeCall(IAdmin.upgradeChainFromVersion, (_chainAddress, _protocolVersion));
    }
}
