// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {DEPLOYER_SYSTEM_CONTRACT, SYSTEM_CONTEXT_CONTRACT, L2_BRIDGE_HUB, L2_ASSET_ROUTER, L2_MESSAGE_ROOT} from "./Constants.sol";
import {IContractDeployer, ForceDeployment} from "./interfaces/IContractDeployer.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {ISystemContext} from "./interfaces/ISystemContext.sol";
import {IL2GenesisUpgrade} from "./interfaces/IL2GenesisUpgrade.sol";

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @notice The l2 component of the genesis upgrade.
contract L2GenesisUpgrade is IL2GenesisUpgrade {
    /// @notice The function that is delegateCalled from the complex upgrader.
    /// @dev It is used to set the chainId and to deploy the force deployments.
    /// @param _chainId the chain id
    /// @param _ctmDeployer the address of the ctm deployer
    /// @param _forceDeploymentsData the force deployments data
    function genesisUpgrade(
        uint256 _chainId,
        address _ctmDeployer,
        bytes calldata _forceDeploymentsData
    ) external payable {
        // solhint-disable-next-line gas-custom-errors
        require(_chainId != 0, "Invalid chainId");
        ISystemContext(SYSTEM_CONTEXT_CONTRACT).setChainId(_chainId);
        ForceDeployment[] memory forceDeployments = abi.decode(_forceDeploymentsData, (ForceDeployment[]));
        IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses{value: msg.value}(forceDeployments);

        // It is expected that either via to the force deployments above
        // or upon init both the L2 deployment of Bridgehub, AssetRouter and MessageRoot are deployed.
        // (The comment does not mention the exact order in case it changes)
        // However, there is still some follow up finalization that needs to be done.

        address bridgehubOwner = L2_BRIDGE_HUB.owner();

        bytes memory data = abi.encodeCall(
            L2_BRIDGE_HUB.setAddresses,
            (L2_ASSET_ROUTER, _ctmDeployer, address(L2_MESSAGE_ROOT))
        );

        (bool success, bytes memory returnData) = SystemContractHelper.mimicCall(
            address(L2_BRIDGE_HUB),
            bridgehubOwner,
            data
        );
        if (!success) {
            // Propagate revert reason
            assembly {
                revert(add(returnData, 0x20), returndatasize())
            }
        }

        emit UpgradeComplete(_chainId);
    }
}
