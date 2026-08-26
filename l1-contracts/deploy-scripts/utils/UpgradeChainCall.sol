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
/// @notice `upgradeChainFromVersion` changed shape twice. From v32 the chain reads the cut from
///         its own ChainTypeManager, so the call carries no cut at all.
/// @dev Calling the wrong shape hits the DiamondProxy fallback and reverts with `"F"`, so the
///      selection is by the version the chain is CURRENTLY on, never the one it moves to.
library UpgradeChainCall {
    uint256 internal constant V31_THRESHOLD = uint256(31) << 32;
    uint256 internal constant V32_THRESHOLD = uint256(32) << 32;

    function encode(
        address _chainAddress,
        uint256 _protocolVersion,
        Diamond.DiamondCutData memory _cutData
    ) internal pure returns (bytes memory) {
        if (_protocolVersion < V31_THRESHOLD) {
            return abi.encodeCall(IAdminPreV31.upgradeChainFromVersion, (_protocolVersion, _cutData));
        }
        if (_protocolVersion < V32_THRESHOLD) {
            return abi.encodeCall(IAdminV31.upgradeChainFromVersion, (_chainAddress, _protocolVersion, _cutData));
        }
        return abi.encodeCall(IAdmin.upgradeChainFromVersion, (_chainAddress, _protocolVersion));
    }
}
