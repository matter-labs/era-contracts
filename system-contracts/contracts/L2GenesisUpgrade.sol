// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {SYSTEM_CONTEXT_CONTRACT} from "./Constants.sol";
import {ISystemContext} from "./interfaces/ISystemContext.sol";
import {IL2GenesisUpgrade} from "./interfaces/IL2GenesisUpgrade.sol";

import {L2GatewayUpgradeHelper} from "./L2GatewayUpgradeHelper.sol";

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @notice The contract that can be used for deterministic contract deployment.
contract L2GenesisUpgrade is IL2GenesisUpgrade {
    function genesisUpgrade(
        uint256 _chainId,
        address _ctmDeployer,
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) external payable {
        // solhint-disable-next-line gas-custom-errors
        require(_chainId != 0, "Invalid chainId");
        ISystemContext(SYSTEM_CONTEXT_CONTRACT).setChainId(_chainId);

        L2GatewayUpgradeHelper.performGatewayContractsInit(
            _ctmDeployer,
            _fixedForceDeploymentsData,
            _additionalForceDeploymentsData
        );

        emit UpgradeComplete(_chainId);
    }
}
