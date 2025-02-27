// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {ChainCreationParams} from "../../state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface for the L2GatewaySpecificUpgrader contract.
 */
interface IL2GatewaySpecificUpgrader {
    function upgradeIfGateway(
        address ctmAddress,
        ChainCreationParams memory chainCreationParams,
        Diamond.DiamondCutData memory upgradeCutData,
        uint256 oldProtocolVersion,
        uint256 oldProtocolVersionDeadline,
        uint256 newProtocolVersion
    ) external payable;
}
