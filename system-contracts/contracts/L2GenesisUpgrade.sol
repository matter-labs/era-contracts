// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {DEPLOYER_SYSTEM_CONTRACT, SYSTEM_CONTEXT_CONTRACT} from "./Constants.sol";
import {IContractDeployer, ForceDeployment} from "./interfaces/IContractDeployer.sol";
import {ISystemContext} from "./interfaces/ISystemContext.sol";
import {IL2GenesisUpgrade} from "./interfaces/IL2GenesisUpgrade.sol";

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @notice The contract that can be used for deterministic contract deployment.
contract L2GenesisUpgrade is IL2GenesisUpgrade {
    function genesisUpgrade(uint256 _chainId, bytes calldata _forceDeploymentsData) external payable {
        // solhint-disable-next-line gas-custom-errors
        require(_chainId != 0, "Invalid chainId");
        ISystemContext(SYSTEM_CONTEXT_CONTRACT).setChainId(_chainId);
        ForceDeployment[] memory forceDeployments = abi.decode(_forceDeploymentsData, (ForceDeployment[]));
        IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses{value: msg.value}(forceDeployments);
        emit UpgradeComplete(_chainId);
    }
}
