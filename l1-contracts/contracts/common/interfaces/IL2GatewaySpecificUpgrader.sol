// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {ChainCreationParams} from "../../state-transition/IChainTypeManager.sol";
import {IL2ContractDeployer} from "../../common/interfaces/IL2ContractDeployer.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface for the L2GatewaySpecificUpgrader contract.
 */
interface IL2GatewaySpecificUpgrader {
    function upgradeIfGateway(
        address ctmAddress,
        ChainCreationParams calldata chainCreationParams,
        Diamond.DiamondCutData calldata upgradeCutData,
        uint256 oldProtocolVersion,
        uint256 oldProtocolVersionDeadline,
        uint256 newProtocolVersion,
        IL2ContractDeployer.ForceDeployment[] calldata
    ) external payable;
}
