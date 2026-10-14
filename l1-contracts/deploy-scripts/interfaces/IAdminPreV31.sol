// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

/// @notice The chain admin facet's upgrade entry point on diamonds without
/// `ProtocolVersionFeatures.UPGRADE_CHAIN_FROM_VERSION_WITH_CHAIN_ADDRESS`.
interface IAdminPreV31 {
    function upgradeChainFromVersion(uint256 _protocolVersion, Diamond.DiamondCutData calldata _cutData) external;
}
