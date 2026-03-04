// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2GenesisForceDeploymentsHelper} from "./L2GenesisForceDeploymentsHelper.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_MESSAGE_ROOT_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_NTV_BEACON_DEPLOYER_ADDR, L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {ISystemContractProxy} from "./ISystemContractProxy.sol";
import {FixedForceDeploymentsData} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {SystemContractProxyAdmin} from "./SystemContractProxyAdmin.sol";

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @notice The upgrade to be applied on testnets to ensure that they use system proxies for system contracts' upgradeability.
/// @notice That it is not expected to be run on mainnet, as mainnet will use those from the start.
contract L2V30TestnetSystemProxiesUpgrade {
    /// @notice Initializes a system proxy on a specific address.
    /// @param _address The address of the system contract proxy to initialize.
    /// @param _fullBytecodeInfo The full bytecode info (implementation + proxy) to force deploy.
    /// @param _bytecodeInfoSystemProxy The bytecode info of the system proxy to deploy on top of the existing contract.
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

        L2GenesisForceDeploymentsHelper.forceDeployOnAddressZKsyncOS(
            _systemContractProxyAdminBytecodeInfo,
            L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR
        );
        SystemContractProxyAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR).forceSetOwner(address(this));

        // It is expected that all zksync os bytecodes infos contain two parts:
        // the abi-encoding of the implementation and the actual system proxy.
        // So we split the two here:
        (, bytes memory bytecodeInfoSystemProxy) = abi.decode(
            (fixedForceDeploymentsData.bridgehubBytecodeInfo),
            (bytes, bytes)
        );

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
        // during genesis, but we keep it this way for consistency with the genesis upgrade on mainnet.
        _initProxyOnAddress(
            L2_NTV_BEACON_DEPLOYER_ADDR,
            fixedForceDeploymentsData.beaconDeployerInfo,
            bytecodeInfoSystemProxy
        );
        // Complex upgrader should also be upgraded to have the new implementation.
        _initProxyOnAddress(address(this), _complexUpgraderProxyBytecodeInfo, bytecodeInfoSystemProxy);
    }
}
