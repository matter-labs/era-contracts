// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2_WRAPPED_BASE_TOKEN_IMPL_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_BRIDGEHUB_ADDR, L2_ASSET_ROUTER_ADDR, L2_MESSAGE_ROOT_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "../common/L2ContractAddresses.sol";
import {IL2ContractDeployer} from "../common/interfaces/IL2ContractDeployer.sol";
import {ZKChainSpecificForceDeploymentsData} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IL2SharedBridgeLegacy} from "../bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {IL2WrappedBaseToken} from "../bridge/interfaces/IL2WrappedBaseToken.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IZKOSContractDeployer} from "./IZKOSContractDeployer.sol";

import {MessageRoot} from "../bridgehub/MessageRoot.sol";
import {Bridgehub} from "../bridgehub/Bridgehub.sol";
import {L2AssetRouter} from "../bridge/asset-router/L2AssetRouter.sol";
import {L2NativeTokenVaultZKOS} from "../bridge/ntv/L2NativeTokenVaultZKOS.sol";

import {ICTMDeploymentTracker} from "../bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "../bridgehub/IMessageRoot.sol";

struct FixedForceDeploymentsData {
    uint256 l1ChainId;
    uint256 eraChainId;
    address l1AssetRouter;
    bytes32 l2TokenProxyBytecodeHash;
    address aliasedL1Governance;
    uint256 maxNumberOfZKChains;
    bytes bridgehubBytecodeOrHash;
    bytes l2AssetRouterBytecodeOrHash;
    bytes l2NtvBytecodeOrHash;
    bytes messageRootBytecodeOrHash;
    address l2SharedBridgeLegacyImpl;
    address l2BridgedStandardERC20Impl;
    // The forced beacon address. It is needed only for internal testing.
    // MUST be equal to 0 in production.
    // It will be the job of the governance to ensure that this value is set correctly.
    address dangerousTestOnlyForcedBeacon;
}


/// @title L2GenesisForceDeploymentsHelper
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A helper library for initializing and managing force-deployed contracts during either the L2 gateway upgrade or
/// the genesis after the gateway protocol upgrade.
library L2GenesisForceDeploymentsHelper {
    function _forceDeployEra(
        bytes32 _bytecodeHash,
        address _newAddress,
        bool _callConstructor,
        uint256 _value,
        bytes memory _input
    ) internal {
        IL2ContractDeployer.ForceDeployment[] memory forceDeployments = new IL2ContractDeployer.ForceDeployment[](1);
        // Configure the MessageRoot deployment.
        forceDeployments[0] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: _bytecodeHash,
            newAddress: _newAddress,
            callConstructor: _callConstructor,
            value: _value,
            input: _input
        });

        IL2ContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR).forceDeployOnAddresses(forceDeployments);
    }

    function _forceDeployZKsyncOS(
        bytes memory _bytecode,
        address _newAddress,
        bytes memory _input,
        bytes memory _initializerData
    ) internal {
        // ZKsyncOS does not allow force deployments with constructor.
        // So we will do the following:
        // 1. Deploy the bytecode onto a random address with the expected input (to ensure that immutables are set correctly).
        // 2. Clone the bytecode into memory + force deploy bytecode.
        // 3. Call the initializer with the expected data.
        
        bytes memory bytecodeWithConstructor = abi.encodePacked(
            _bytecode,
            _initializerData
        );

        address randomAddress;
        assembly {
            randomAddress := create(0, add(bytecodeWithConstructor, 0x20), mload(bytecodeWithConstructor))
        }

        if (randomAddress.code.length == 0) {
            // Something went wrong, revert.
            // TODO: use custom errors.
            revert("Failed to deploy bytecode");
        }

        // 2. Clone the bytecode into memory + force deploy bytecode.
        IZKOSContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR).setDeployedCodeEVM(
            _newAddress,
            randomAddress.code
        );

        (bool success, bytes memory returnData) = _newAddress.call(_initializerData);

        if (!success) {
            // Something went wrong, revert.
            // TODO: use custom errors.
            revert("Failed to call initializer");
        }
    }

    /// @notice Initializes force-deployed contracts required for the L2 genesis upgrade.
    /// @param _ctmDeployer Address of the CTM Deployer contract.
    /// @param _fixedForceDeploymentsData Encoded data for forced deployment that
    /// is the same for all the chains.
    /// @param _additionalForceDeploymentsData Encoded data for force deployments that
    /// is specific for each ZK Chain.
    function performForceDeployedContractsInit(
        bool _isZKsyncOS,
        address _ctmDeployer,
        bytes memory _fixedForceDeploymentsData,
        bytes memory _additionalForceDeploymentsData
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

        if (_isZKsyncOS) {
            _forceDeployZKsyncOS(
                fixedForceDeploymentsData.messageRootBytecodeOrHash,
                address(L2_MESSAGE_ROOT_ADDR),
                abi.encode(address(L2_BRIDGEHUB_ADDR)),
                abi.encodeCall(MessageRoot.initialize, ())
            );
        } else {
            _forceDeployEra(
                abi.decode(fixedForceDeploymentsData.messageRootBytecodeOrHash, (bytes32)),
                address(L2_MESSAGE_ROOT_ADDR),
                true,
                0,
                abi.encode(address(L2_BRIDGEHUB_ADDR))
            );
        }

        if (_isZKsyncOS) {
            _forceDeployZKsyncOS(
                fixedForceDeploymentsData.bridgehubBytecodeOrHash,
                address(L2_BRIDGEHUB_ADDR),
                abi.encode(
                    fixedForceDeploymentsData.l1ChainId,
                    fixedForceDeploymentsData.aliasedL1Governance,
                    fixedForceDeploymentsData.maxNumberOfZKChains
                ),
                abi.encodeCall(Bridgehub.initialize, (fixedForceDeploymentsData.aliasedL1Governance))
            );
        } else {
            _forceDeployEra(
                abi.decode(fixedForceDeploymentsData.bridgehubBytecodeOrHash, (bytes32)),
                address(L2_BRIDGEHUB_ADDR),
                true,
                0,
                abi.encode(
                    fixedForceDeploymentsData.l1ChainId,
                    fixedForceDeploymentsData.aliasedL1Governance,
                    fixedForceDeploymentsData.maxNumberOfZKChains
                )
            );
        }

        if (_isZKsyncOS) {
            _forceDeployZKsyncOS(
                fixedForceDeploymentsData.l2AssetRouterBytecodeOrHash,
                address(L2_ASSET_ROUTER_ADDR),
                abi.encode(
                    fixedForceDeploymentsData.l1ChainId,
                    fixedForceDeploymentsData.eraChainId,
                    fixedForceDeploymentsData.l1AssetRouter,
                    additionalForceDeploymentsData.l2LegacySharedBridge,
                    additionalForceDeploymentsData.baseTokenAssetId,
                    fixedForceDeploymentsData.aliasedL1Governance
                ),
                abi.encodeCall(L2AssetRouter.initialize, (additionalForceDeploymentsData.baseTokenAssetId, fixedForceDeploymentsData.aliasedL1Governance))
            );
        } else {
            _forceDeployEra(
                abi.decode(fixedForceDeploymentsData.l2AssetRouterBytecodeOrHash, (bytes32)),
                address(L2_ASSET_ROUTER_ADDR),
                true,
                0,
                abi.encode(
                    fixedForceDeploymentsData.l1ChainId,
                    fixedForceDeploymentsData.eraChainId,
                    fixedForceDeploymentsData.l1AssetRouter,
                    additionalForceDeploymentsData.l2LegacySharedBridge,
                    additionalForceDeploymentsData.baseTokenAssetId,
                    fixedForceDeploymentsData.aliasedL1Governance
                )
            );
        }

        // Ensure the WETH token is deployed and retrieve its address.
        address wrappedBaseTokenAddress = _ensureWethToken({
            _predeployedWethToken: additionalForceDeploymentsData.predeployedL2WethAddress,
            _aliasedL1Governance: fixedForceDeploymentsData.aliasedL1Governance,
            _baseTokenL1Address: additionalForceDeploymentsData.baseTokenL1Address,
            _baseTokenAssetId: additionalForceDeploymentsData.baseTokenAssetId,
            _baseTokenName: additionalForceDeploymentsData.baseTokenName,
            _baseTokenSymbol: additionalForceDeploymentsData.baseTokenSymbol
        });

        address deployedTokenBeacon;
        bool contractsDeployedAlready;
        if (additionalForceDeploymentsData.l2LegacySharedBridge != address(0)) {
            // In production, the `fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon` must always
            // be equal to 0. It is only for simplifying testing.
            if (fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon == address(0)) {
                deployedTokenBeacon = address(
                    IL2SharedBridgeLegacy(additionalForceDeploymentsData.l2LegacySharedBridge).l2TokenBeacon()
                );
            } else {
                deployedTokenBeacon = fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon;
            }

            contractsDeployedAlready = true;
        }

        if (_isZKsyncOS) {
            _forceDeployZKsyncOS(
                fixedForceDeploymentsData.l2NtvBytecodeOrHash,
                L2_NATIVE_TOKEN_VAULT_ADDR,
                abi.encode(
                    fixedForceDeploymentsData.l1ChainId,
                    fixedForceDeploymentsData.aliasedL1Governance,
                    additionalForceDeploymentsData.l2LegacySharedBridge,
                    deployedTokenBeacon,
                    contractsDeployedAlready,
                    wrappedBaseTokenAddress,
                    additionalForceDeploymentsData.baseTokenAssetId
                ),
                abi.encodeCall(L2NativeTokenVaultZKOS.initialize, (fixedForceDeploymentsData.aliasedL1Governance, deployedTokenBeacon, contractsDeployedAlready))
            );
        } else {
            _forceDeployEra(
                abi.decode(fixedForceDeploymentsData.l2NtvBytecodeOrHash, (bytes32)),
                L2_NATIVE_TOKEN_VAULT_ADDR,
                true,
                0,
                abi.encode(
                    fixedForceDeploymentsData.l1ChainId,
                    fixedForceDeploymentsData.aliasedL1Governance,
                    fixedForceDeploymentsData.l2TokenProxyBytecodeHash,
                    additionalForceDeploymentsData.l2LegacySharedBridge,
                    deployedTokenBeacon,
                    contractsDeployedAlready,
                    wrappedBaseTokenAddress,
                    additionalForceDeploymentsData.baseTokenAssetId
                )
            );
        }

        // It is expected that either through the force deployments above
        // or upon initialization, both the L2 deployment of BridgeHub, AssetRouter, and MessageRoot are deployed.
        // However, there is still some follow-up finalization that needs to be done.
        Bridgehub(L2_BRIDGEHUB_ADDR).setAddresses(L2_ASSET_ROUTER_ADDR, ICTMDeploymentTracker(_ctmDeployer), IMessageRoot(L2_MESSAGE_ROOT_ADDR));
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
            (_wrappedBaseTokenName, _wrappedBaseTokenSymbol, L2_ASSET_ROUTER_ADDR, _baseTokenL1Address, _baseTokenAssetId)
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
