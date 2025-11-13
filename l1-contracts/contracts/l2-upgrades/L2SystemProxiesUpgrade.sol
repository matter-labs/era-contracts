// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {ISystemContext} from "../state-transition/l2-deps/ISystemContext.sol";
import {IL2GenesisUpgrade} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {L2GenesisForceDeploymentsHelper} from "./L2GenesisForceDeploymentsHelper.sol";

import {InvalidChainId} from "../common/L1ContractErrors.sol";
import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_MESSAGE_ROOT_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_NTV_BEACON_DEPLOYER_ADDR, L2_WRAPPED_BASE_TOKEN_IMPL_ADDR, L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {ISystemContractProxy} from "./ISystemContractProxy.sol";
import {FixedForceDeploymentsData, ZKChainSpecificForceDeploymentsData} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {SystemContractProxyAdmin} from "./SystemContractProxyAdmin.sol";

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @notice The l2 component of the genesis upgrade.
contract L2SystemProxiesUpgrade {
    function _initProxyOnAddress(
        address _address,
        bytes memory _fullBytecodeInfo,
        bytes memory _bytecodeInfoSystemProxy
    ) internal {
        L2GenesisForceDeploymentsHelper.unsafeForceDeployZKsyncOS(_bytecodeInfoSystemProxy, _address);
        ISystemContractProxy(_address).forceInitAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR);

        L2GenesisForceDeploymentsHelper.updateZKsyncOSContract(_fullBytecodeInfo, _address);
    }

    /// @notice The function to be delegate-called by the L2ComplexUpgrader.
    /// @dev It will force deploy system proxies as well as the SystemContractProxyAdmin to ensure
    /// that system contracts will use those for future upgrades.
    /// @dev It is assumed that no additional initialization is needed, all the L2 contracts have been properly initialized and
    /// so it is enough to just:
    /// 1. force deploy the SystemProxy bytecode on top of the current contract as well as the SystemContractProxyAdmin.
    /// 2. force deploy the implementations and upgrade proxy implementations.
    // slither-disable-next-line locked-ether
    function upgrade(
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _systemContractProxyAdminBytecodeInfo,
        bytes calldata _complexUpgraderProxyBytecodeInfo
    ) external {
        // Decode the fixed and additional force deployments data.
        FixedForceDeploymentsData memory fixedForceDeploymentsData = abi.decode(
            _fixedForceDeploymentsData,
            (FixedForceDeploymentsData)
        );

        L2GenesisForceDeploymentsHelper.forceDeployOnAddressZKsyncOS(_systemContractProxyAdminBytecodeInfo, L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR);
        SystemContractProxyAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR).forceSetOwner(address(this));
      
        // It is expected that all zksync os bytecodes infos contain two parts:
        // the abi-encoding of the implementation and the actual system proxy.
        // So we split the two here:
        (, bytes memory bytecodeInfoSystemProxy) = abi.decode((fixedForceDeploymentsData.bridgehubBytecodeInfo), (bytes, bytes));

        _initProxyOnAddress(
            L2_MESSAGE_ROOT_ADDR,
            fixedForceDeploymentsData.messageRootBytecodeInfo,
            bytecodeInfoSystemProxy
        );
        _initProxyOnAddress(
            L2_BRIDGEHUB_ADDR,
            fixedForceDeploymentsData.bridgehubBytecodeInfo,
            bytecodeInfoSystemProxy
        );
        _initProxyOnAddress(
            L2_ASSET_ROUTER_ADDR,
            fixedForceDeploymentsData.l2AssetRouterBytecodeInfo,
            bytecodeInfoSystemProxy
        );
        _initProxyOnAddress(
            L2_NATIVE_TOKEN_VAULT_ADDR, 
            fixedForceDeploymentsData.l2NtvBytecodeInfo,
            bytecodeInfoSystemProxy
        );
        _initProxyOnAddress(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            fixedForceDeploymentsData.chainAssetHandlerBytecodeInfo,
            bytecodeInfoSystemProxy
        );
        // Formally this is not needed, since the beacon deployer is used only once
        // during genesis, but we keep it this way for consistency.
        _initProxyOnAddress(
            L2_NTV_BEACON_DEPLOYER_ADDR,
            fixedForceDeploymentsData.beaconDeployerInfo,
            bytecodeInfoSystemProxy
        );
        // Complex upgrader should also be upgraded to have the new implementation.
        _initProxyOnAddress(
            address(this),
            _complexUpgraderProxyBytecodeInfo,
            bytecodeInfoSystemProxy
        );
    }
}
