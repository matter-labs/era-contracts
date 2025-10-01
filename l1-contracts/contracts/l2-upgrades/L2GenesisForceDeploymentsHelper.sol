// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_MESSAGE_ROOT_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_NTV_BEACON_DEPLOYER_ADDR, L2_WRAPPED_BASE_TOKEN_IMPL_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IL2ContractDeployer} from "../common/interfaces/IL2ContractDeployer.sol";
import {FixedForceDeploymentsData, ZKChainSpecificForceDeploymentsData} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IL2WrappedBaseToken} from "../bridge/interfaces/IL2WrappedBaseToken.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IZKOSContractDeployer} from "./IZKOSContractDeployer.sol";
import {L2NativeTokenVault} from "../bridge/ntv/L2NativeTokenVault.sol";
import {L2MessageRoot} from "../bridgehub/L2MessageRoot.sol";
import {L2Bridgehub} from "../bridgehub/L2Bridgehub.sol";
import {L2AssetRouter} from "../bridge/asset-router/L2AssetRouter.sol";
import {L2ChainAssetHandler} from "../bridgehub/L2ChainAssetHandler.sol";
import {DeployFailed} from "../common/L1ContractErrors.sol";

import {L2NativeTokenVaultZKOS} from "../bridge/ntv/L2NativeTokenVaultZKOS.sol";

import {ICTMDeploymentTracker} from "../bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "../bridgehub/IMessageRoot.sol";

import {UpgradeableBeaconDeployer} from "../bridge/ntv/UpgradeableBeaconDeployer.sol";

/// @title L2GenesisForceDeploymentsHelper
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A helper library for initializing and managing force-deployed contracts during either the L2 gateway upgrade or
/// the genesis after the gateway protocol upgrade.
library L2GenesisForceDeploymentsHelper {
    function forceDeployEra(bytes memory _bytecodeInfo, address _newAddress) internal {
        bytes32 bytecodeHash = abi.decode(_bytecodeInfo, (bytes32));
        IL2ContractDeployer.ForceDeployment[] memory forceDeployments = new IL2ContractDeployer.ForceDeployment[](1);
        // Configure the MessageRoot deployment.
        forceDeployments[0] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: bytecodeHash,
            newAddress: _newAddress,
            callConstructor: false,
            value: 0,
            input: hex""
        });

        IL2ContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR).forceDeployOnAddresses(forceDeployments);
    }

    function forceDeployZKsyncOS(bytes memory _bytecodeInfo, address _newAddress) internal {
        (bytes32 bytecodeHash, uint32 bytecodeLength, bytes32 observableBytecodeHash) = abi.decode(
            _bytecodeInfo,
            (bytes32, uint32, bytes32)
        );

        bytes memory data = abi.encodeCall(
            IZKOSContractDeployer.setBytecodeDetailsEVM,
            (_newAddress, bytecodeHash, bytecodeLength, observableBytecodeHash)
        );

        // Note, that we dont use interface, but raw call to avoid Solidity checking for empty bytecode
        (bool success, ) = L2_DEPLOYER_SYSTEM_CONTRACT_ADDR.call(data);
        if (!success) {
            revert DeployFailed();
        }
    }

    /// @notice Unified function to force deploy contracts based on whether it's ZKSyncOS or Era.
    /// @param _isZKsyncOS Whether the deployment is for ZKSyncOS or Era.
    /// @param _bytecodeInfo The bytecode information for deployment.
    /// @param _newAddress The address where the contract should be deployed.
    function forceDeployOnAddress(bool _isZKsyncOS, bytes memory _bytecodeInfo, address _newAddress) internal {
        if (_isZKsyncOS) {
            forceDeployZKsyncOS(_bytecodeInfo, _newAddress);
        } else {
            forceDeployEra(_bytecodeInfo, _newAddress);
        }
    }

    /// @notice Initializes force-deployed contracts.
    /// @param _ctmDeployer Address of the CTM Deployer contract.
    /// @param _fixedForceDeploymentsData Encoded data for forced deployment that
    /// is the same for all the chains.
    /// @param _additionalForceDeploymentsData Encoded data for force deployments that
    /// is specific for each ZK Chain.
    function performForceDeployedContractsInit(
        bool _isZKsyncOS,
        address _ctmDeployer,
        bytes memory _fixedForceDeploymentsData,
        bytes memory _additionalForceDeploymentsData,
        bool _isGenesisUpgrade
    ) internal {
        // Decode the fixed and additional force deployments data.
        FixedForceDeploymentsData memory fixedForceDeploymentsData = abi.decode(
            _fixedForceDeploymentsData,
            (FixedForceDeploymentsData)
        );
        ZKChainSpecificForceDeploymentsData memory additionalForceDeploymentsData = abi.decode(
            _additionalForceDeploymentsData,
            (ZKChainSpecificForceDeploymentsData)
        );

        forceDeployOnAddress(
            _isZKsyncOS,
            fixedForceDeploymentsData.messageRootBytecodeInfo,
            address(L2_MESSAGE_ROOT_ADDR)
        );
        // If this is a genesis upgrade, we need to initialize the MessageRoot contract.
        // We dont need to do anything for already deployed chains.
        if (_isGenesisUpgrade) {
            L2MessageRoot(L2_MESSAGE_ROOT_ADDR).initL2(fixedForceDeploymentsData.l1ChainId);
        }

        forceDeployOnAddress(_isZKsyncOS, fixedForceDeploymentsData.bridgehubBytecodeInfo, address(L2_BRIDGEHUB_ADDR));
        if (_isGenesisUpgrade) {
            L2Bridgehub(L2_BRIDGEHUB_ADDR).initL2(
                fixedForceDeploymentsData.l1ChainId,
                fixedForceDeploymentsData.aliasedL1Governance,
                fixedForceDeploymentsData.maxNumberOfZKChains
            );
        } else {
            L2Bridgehub(L2_BRIDGEHUB_ADDR).updateL2(
                fixedForceDeploymentsData.l1ChainId,
                fixedForceDeploymentsData.maxNumberOfZKChains
            );
        }

        // For new chains, there is no legacy shared bridge, but the already existing ones,
        // we should be able to query it.
        address l2LegacySharedBridge = _isGenesisUpgrade
            ? address(0)
            : L2AssetRouter(L2_ASSET_ROUTER_ADDR).L2_LEGACY_SHARED_BRIDGE();

        forceDeployOnAddress(
            _isZKsyncOS,
            fixedForceDeploymentsData.l2AssetRouterBytecodeInfo,
            address(L2_ASSET_ROUTER_ADDR)
        );
        if (_isGenesisUpgrade) {
            // solhint-disable-next-line func-named-parameters
            L2AssetRouter(L2_ASSET_ROUTER_ADDR).initL2(
                fixedForceDeploymentsData.l1ChainId,
                fixedForceDeploymentsData.eraChainId,
                fixedForceDeploymentsData.l1AssetRouter,
                l2LegacySharedBridge,
                additionalForceDeploymentsData.baseTokenAssetId,
                fixedForceDeploymentsData.aliasedL1Governance
            );
        } else {
            // solhint-disable-next-line func-named-parameters
            L2AssetRouter(L2_ASSET_ROUTER_ADDR).updateL2(
                fixedForceDeploymentsData.l1ChainId,
                fixedForceDeploymentsData.eraChainId,
                fixedForceDeploymentsData.l1AssetRouter,
                l2LegacySharedBridge,
                additionalForceDeploymentsData.baseTokenAssetId
            );
        }

        address predeployedL2WethAddress = _isGenesisUpgrade
            ? address(0)
            : L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).WETH_TOKEN();
        bytes32 previousL2TokenProxyBytecodeHash = _isGenesisUpgrade
            ? bytes32(0)
            : L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).L2_TOKEN_PROXY_BYTECODE_HASH();

        // Ensure the WETH token is deployed and retrieve its address.
        address wrappedBaseTokenAddress = _ensureWethToken({
            _predeployedWethToken: predeployedL2WethAddress,
            _aliasedL1Governance: fixedForceDeploymentsData.aliasedL1Governance,
            _baseTokenL1Address: additionalForceDeploymentsData.baseTokenL1Address,
            _baseTokenAssetId: additionalForceDeploymentsData.baseTokenAssetId,
            _baseTokenName: additionalForceDeploymentsData.baseTokenName,
            _baseTokenSymbol: additionalForceDeploymentsData.baseTokenSymbol
        });

        // Now initialiazing the upgradeable token beacon
        forceDeployOnAddress(_isZKsyncOS, fixedForceDeploymentsData.l2NtvBytecodeInfo, L2_NATIVE_TOKEN_VAULT_ADDR);

        if (_isGenesisUpgrade) {
            address deployedTokenBeacon;
            // In production, the `fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon` must always
            // be equal to 0. It is only for simplifying testing.
            if (fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon == address(0)) {
                // We need to deploy the beacon, we will use a separate contract for that to save
                // up on size of this contract.
                forceDeployOnAddress(
                    _isZKsyncOS,
                    fixedForceDeploymentsData.beaconDeployerInfo,
                    L2_NTV_BEACON_DEPLOYER_ADDR
                );

                deployedTokenBeacon = UpgradeableBeaconDeployer(L2_NTV_BEACON_DEPLOYER_ADDR).deployUpgradeableBeacon(
                    fixedForceDeploymentsData.aliasedL1Governance
                );
            } else {
                deployedTokenBeacon = fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon;
            }

            // solhint-disable-next-line func-named-parameters
            L2NativeTokenVaultZKOS(L2_NATIVE_TOKEN_VAULT_ADDR).initL2(
                fixedForceDeploymentsData.l1ChainId,
                fixedForceDeploymentsData.aliasedL1Governance,
                fixedForceDeploymentsData.l2TokenProxyBytecodeHash,
                additionalForceDeploymentsData.l2LegacySharedBridge,
                deployedTokenBeacon,
                wrappedBaseTokenAddress,
                additionalForceDeploymentsData.baseTokenAssetId
            );
        } else {
            // solhint-disable-next-line func-named-parameters
            L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).updateL2(
                fixedForceDeploymentsData.l1ChainId,
                previousL2TokenProxyBytecodeHash,
                l2LegacySharedBridge,
                wrappedBaseTokenAddress,
                additionalForceDeploymentsData.baseTokenAssetId
            );
        }

        forceDeployOnAddress(
            _isZKsyncOS,
            fixedForceDeploymentsData.chainAssetHandlerBytecodeInfo,
            address(L2_CHAIN_ASSET_HANDLER_ADDR)
        );
        if (_isGenesisUpgrade) {
            // solhint-disable-next-line func-named-parameters
            L2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR).initL2(
                fixedForceDeploymentsData.l1ChainId,
                fixedForceDeploymentsData.aliasedL1Governance,
                L2_BRIDGEHUB_ADDR,
                L2_ASSET_ROUTER_ADDR,
                L2_MESSAGE_ROOT_ADDR
            );
        } else {
            L2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR).updateL2(
                fixedForceDeploymentsData.l1ChainId,
                L2_BRIDGEHUB_ADDR,
                L2_ASSET_ROUTER_ADDR,
                L2_MESSAGE_ROOT_ADDR
            );
        }

        // It is expected that either through the force deployments above
        // or upon initialization, both the L2 deployment of BridgeHub, AssetRouter, and MessageRoot are deployed.
        // However, there is still some follow-up finalization that needs to be done.
        L2Bridgehub(L2_BRIDGEHUB_ADDR).setAddresses(
            L2_ASSET_ROUTER_ADDR,
            ICTMDeploymentTracker(_ctmDeployer),
            IMessageRoot(L2_MESSAGE_ROOT_ADDR),
            L2_CHAIN_ASSET_HANDLER_ADDR
        );
    }

    /// @notice Constructs the initialization calldata for the L2WrappedBaseToken.
    /// @param _wrappedBaseTokenName The name of the wrapped base token.
    /// @param _wrappedBaseTokenSymbol The symbol of the wrapped base token.
    /// @param _baseTokenL1Address The L1 address of the base token.
    /// @param _baseTokenAssetId The asset ID of the base token.
    /// @return initData The encoded initialization calldata.
    function getWethInitData(
        string memory _wrappedBaseTokenName,
        string memory _wrappedBaseTokenSymbol,
        address _baseTokenL1Address,
        bytes32 _baseTokenAssetId
    ) internal pure returns (bytes memory initData) {
        initData = abi.encodeCall(
            IL2WrappedBaseToken.initializeV3,
            (
                _wrappedBaseTokenName,
                _wrappedBaseTokenSymbol,
                L2_ASSET_ROUTER_ADDR,
                _baseTokenL1Address,
                _baseTokenAssetId
            )
        );
    }

    /// @notice Ensures that the WETH token is deployed. If not predeployed, deploys it.
    /// @param _predeployedWethToken The potential address of the predeployed WETH token.
    /// @param _aliasedL1Governance Address of the aliased L1 governance.
    /// @param _baseTokenL1Address L1 address of the base token.
    /// @param _baseTokenAssetId Asset ID of the base token.
    /// @param _baseTokenName Name of the base token.
    /// @param _baseTokenSymbol Symbol of the base token.
    /// @return The address of the ensured WETH token.
    function _ensureWethToken(
        address _predeployedWethToken,
        address _aliasedL1Governance,
        address _baseTokenL1Address,
        bytes32 _baseTokenAssetId,
        string memory _baseTokenName,
        string memory _baseTokenSymbol
    ) private returns (address) {
        if (_predeployedWethToken != address(0)) {
            return _predeployedWethToken;
        }

        string memory wrappedBaseTokenName = string.concat("Wrapped ", _baseTokenName);
        string memory wrappedBaseTokenSymbol = string.concat("W", _baseTokenSymbol);

        bytes memory initData = getWethInitData(
            wrappedBaseTokenName,
            wrappedBaseTokenSymbol,
            _baseTokenL1Address,
            _baseTokenAssetId
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy{salt: bytes32(0)}(
            L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
            _aliasedL1Governance,
            initData
        );

        return address(proxy);
    }
}
