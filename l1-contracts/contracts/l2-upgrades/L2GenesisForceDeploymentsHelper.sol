// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GW_ASSET_TRACKER_ADDR, L2_ASSET_TRACKER_ADDR, L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_INTEROP_HANDLER_ADDR, L2_MESSAGE_ROOT_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_NTV_BEACON_DEPLOYER_ADDR, L2_WRAPPED_BASE_TOKEN_IMPL_ADDR, L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR, L2_INTEROP_CENTER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IL2ContractDeployer} from "../common/interfaces/IL2ContractDeployer.sol";
import {FixedForceDeploymentsData, ZKChainSpecificForceDeploymentsData} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IL2WrappedBaseToken} from "../bridge/interfaces/IL2WrappedBaseToken.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SystemContractProxyAdmin} from "./SystemContractProxyAdmin.sol";
import {IZKOSContractDeployer} from "contracts/l2-system/zksync-os/interfaces/IZKOSContractDeployer.sol";
import {L2NativeTokenVault} from "../bridge/ntv/L2NativeTokenVault.sol";
import {L2MessageRoot} from "../core/message-root/L2MessageRoot.sol";
import {L2Bridgehub} from "../core/bridgehub/L2Bridgehub.sol";
import {L2AssetRouter} from "../bridge/asset-router/L2AssetRouter.sol";
import {L2AssetTracker} from "../bridge/asset-tracker/L2AssetTracker.sol";
import {GWAssetTracker} from "../bridge/asset-tracker/GWAssetTracker.sol";
import {L2ChainAssetHandler} from "../core/chain-asset-handler/L2ChainAssetHandler.sol";
import {InteropHandler} from "../interop/InteropHandler.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {IL2SharedBridgeLegacy} from "../bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {DeployFailed, UnsupportedUpgradeType, ZKsyncOSNotForceDeployForExistingContract} from "../common/L1ContractErrors.sol";

import {L2NativeTokenVaultZKOS} from "../bridge/ntv/L2NativeTokenVaultZKOS.sol";

import {ICTMDeploymentTracker} from "../core/ctm-deployment/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "../core/message-root/IMessageRoot.sol";
import {InteropCenter} from "../interop/InteropCenter.sol";

import {UpgradeableBeaconDeployer} from "../bridge/UpgradeableBeaconDeployer.sol";
import {ISystemContractProxy} from "./ISystemContractProxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";

import {ZKSyncOSBytecodeInfo} from "../common/libraries/ZKSyncOSBytecodeInfo.sol";

/// @title L2GenesisForceDeploymentsHelper
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A helper library for initializing and managing force-deployed contracts during either the L2 gateway upgrade or
/// the genesis after the gateway protocol upgrade.
library L2GenesisForceDeploymentsHelper {
    event ForceDeployEraStarted(address indexed targetAddress, bytes32 bytecodeHash);
    event ForceDeployEraCompleted(address indexed targetAddress);
    event ZKsyncOSBytecodeDetailsSet(
        address indexed targetAddress,
        bytes32 bytecodeHash,
        uint32 bytecodeLength,
        bytes32 observableBytecodeHash,
        uint32 observableBytecodeLength
    );
    event ZKsyncOSForceDeployStarted(address indexed targetAddress);
    event ZKsyncOSForceDeployCompleted(address indexed targetAddress);
    event UpdateZKsyncOSContractStarted(address indexed targetAddress);
    event ImplementationAddressGenerated(address indexed implAddress);
    event ProxyUpgradeInitiated(address indexed proxyAddress, address indexed newImplementation);
    event UpdateZKsyncOSContractCompleted(address indexed targetAddress);
    event ContractUpgradeStarted(IComplexUpgrader.ContractUpgradeType upgradeType, address indexed targetAddress);
    event ContractUpgradeCompleted(IComplexUpgrader.ContractUpgradeType upgradeType, address indexed targetAddress);
    event PerformForceDeployedContractsInitStarted(bool isZKsyncOS, bool isGenesisUpgrade);
    event MessageRootUpgradeStarted();
    event MessageRootInitStarted(uint256 l1ChainId);
    event BridgehubUpgradeStarted();
    event BridgehubInitStarted(uint256 l1ChainId);
    event AssetRouterUpgradeStarted();
    event AssetRouterInitStarted(uint256 l1ChainId, uint256 eraChainId);
    event WethTokenEnsureStarted();
    event WethTokenEnsured(address indexed wethAddress);
    event NtvUpgradeStarted();
    event NtvInitStarted(uint256 l1ChainId);
    event ChainAssetHandlerUpgradeStarted();
    event ChainAssetHandlerInitStarted(uint256 l1ChainId);
    event BridgehubSetAddressesStarted();
    event PerformForceDeployedContractsInitCompleted();

    function forceDeployEra(bytes memory _bytecodeInfo, address _newAddress) internal {
        emit ForceDeployEraStarted(_newAddress, abi.decode(_bytecodeInfo, (bytes32)));
        bytes32 bytecodeHash = abi.decode(_bytecodeInfo, (bytes32));
        IL2ContractDeployer.ForceDeployment[] memory forceDeployments = new IL2ContractDeployer.ForceDeployment[](1);
        forceDeployments[0] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: bytecodeHash,
            newAddress: _newAddress,
            callConstructor: false,
            value: 0,
            input: hex""
        });

        IL2ContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR).forceDeployOnAddresses(forceDeployments);
        emit ForceDeployEraCompleted(_newAddress);
    }

    function unsafeForceDeployZKsyncOS(bytes memory _bytecodeInfo, address _newAddress) internal {
        emit ZKsyncOSForceDeployStarted(_newAddress);

        // Decode the bytecode info using the library
        (bytes32 bytecodeHash, uint256 bytecodeLength256, bytes32 observableBytecodeHash) = ZKSyncOSBytecodeInfo
            .decodeZKSyncOSBytecodeInfo(_bytecodeInfo);

        // Convert to uint32 for the contract deployer interface
        uint32 bytecodeLength = uint32(bytecodeLength256);

        bytes memory data = abi.encodeCall(
            IZKOSContractDeployer.setBytecodeDetailsEVM,
            (_newAddress, bytecodeHash, bytecodeLength, observableBytecodeHash)
        );
        emit ZKsyncOSBytecodeDetailsSet({
            targetAddress: _newAddress,
            bytecodeHash: bytecodeHash,
            bytecodeLength: bytecodeLength,
            observableBytecodeHash: observableBytecodeHash,
            observableBytecodeLength: bytecodeLength
        });

        // Note, that we dont use interface, but raw call to avoid Solidity checking for empty bytecode
        (bool success, ) = L2_DEPLOYER_SYSTEM_CONTRACT_ADDR.call(data);
        if (!success) {
            revert DeployFailed();
        }
        emit ZKsyncOSForceDeployCompleted(_newAddress);
    }

    function forceDeployOnAddressZKsyncOS(bytes memory _bytecodeInfo, address _newAddress) internal {
        require(_newAddress.code.length == 0, ZKsyncOSNotForceDeployForExistingContract(_newAddress));
        unsafeForceDeployZKsyncOS(_bytecodeInfo, _newAddress);
    }

    /// @notice A random address in the user space derived from the bytecode info.
    /// @dev The first 32 bytes of the preimage are 0s to ensure that the address will never collide with neither create nor create2.
    /// This is the case, since for both create and create2 the preimage for hash starts with a non-zero byte.
    function generateRandomAddress(bytes memory _bytecodeInfo) internal view returns (address) {
        return address(uint160(uint256(keccak256(bytes.concat(bytes32(0), _bytecodeInfo)))));
    }

    function updateZKsyncOSContract(bytes memory _bytecodeInfo, address _newAddress) internal {
        emit UpdateZKsyncOSContractStarted(_newAddress);
        (bytes memory bytecodeInfo, bytes memory bytecodeInfoSystemProxy) = abi.decode((_bytecodeInfo), (bytes, bytes));

        address implAddress = generateRandomAddress(bytecodeInfo);
        emit ImplementationAddressGenerated(implAddress);
        // We need to allow not force deploying in to make upgrades simpler in case the bytecode has not changed.
        if (implAddress.code.length == 0) {
            forceDeployOnAddressZKsyncOS(bytecodeInfo, implAddress);
        } else {
            // Note, that we can not just assume the correct bytecode. Even though due to a new address derivation,
            // the chances of this contract having a non-empty code that is not being the expected one,
            // are extremely low, but non-zero (in case a malicious person controls both the correct source code and the malicious one,
            // they can perform a birthday attack). So we need to ensure that the code matches.
            bytes32 currentCodeHash;
            assembly {
                currentCodeHash := extcodehash(implAddress)
            }

            // slither-disable-next-line unused-return
            (, , bytes32 expectedCodeHash) = ZKSyncOSBytecodeInfo.decodeZKSyncOSBytecodeInfo(bytecodeInfo);

            if (currentCodeHash != expectedCodeHash) {
                revert ZKsyncOSNotForceDeployForExistingContract(implAddress);
            }
        }

        // If the address does not have any bytecode, we expect that it is a proxy.
        if (_newAddress.code.length == 0) {
            // We can call unsafe directly, since the code length is checked to be 0 already.
            unsafeForceDeployZKsyncOS(bytecodeInfoSystemProxy, _newAddress);
            ISystemContractProxy(_newAddress).forceInitAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR);
        }

        // Now we need to update the implementation address in the proxy.
        emit ProxyUpgradeInitiated(_newAddress, implAddress);
        SystemContractProxyAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(_newAddress),
            implAddress
        );
        emit UpdateZKsyncOSContractCompleted(_newAddress);
    }

    /// @notice Unified function to force deploy contracts based on whether it's ZKsyncOS or Era.
    /// @param _upgradeType The upgrade type to use.
    /// @param _bytecodeInfo The bytecode information for deployment.
    /// @param _newAddress The address where the contract should be deployed.
    function conductContractUpgrade(
        IComplexUpgrader.ContractUpgradeType _upgradeType,
        bytes memory _bytecodeInfo,
        address _newAddress
    ) internal {
        emit ContractUpgradeStarted(_upgradeType, _newAddress);
        if (_upgradeType == IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment) {
            unsafeForceDeployZKsyncOS(_bytecodeInfo, _newAddress);
        } else if (_upgradeType == IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade) {
            updateZKsyncOSContract(_bytecodeInfo, _newAddress);
        } else if (_upgradeType == IComplexUpgrader.ContractUpgradeType.EraForceDeployment) {
            forceDeployEra(_bytecodeInfo, _newAddress);
        } else {
            revert UnsupportedUpgradeType();
        }
        emit ContractUpgradeCompleted(_upgradeType, _newAddress);
    }

    /// @notice Initializes force-deployed contracts.
    /// @dev Note, that this function is expected to initialize all system contracts deployed within the user space.
    /// with the only exception of the SystemContractProxyAdmin, which is expected to be initialized inside the Genesis.
    /// @param _ctmDeployer Address of the CTM Deployer contract.
    /// @param _fixedForceDeploymentsData Encoded data for forced deployment that
    /// is the same for all the chains.
    /// @param _additionalForceDeploymentsData Encoded data for force deployments that
    /// is specific for each ZK Chain.
    /// It deploys a bunch of contracts at given fixed addresses, and initializes them accordingly (different
    /// flow for genesis vs non-genesis upgrade). Most of these contracts expose initL2 / updateL2 methods.
    function performForceDeployedContractsInit(
        bool _isZKsyncOS,
        address _ctmDeployer,
        bytes memory _fixedForceDeploymentsData,
        bytes memory _additionalForceDeploymentsData,
        bool _isGenesisUpgrade
    ) internal {
        emit PerformForceDeployedContractsInitStarted(_isZKsyncOS, _isGenesisUpgrade);
        // Decode the fixed and additional force deployments data.
        FixedForceDeploymentsData memory fixedForceDeploymentsData = abi.decode(
            _fixedForceDeploymentsData,
            (FixedForceDeploymentsData)
        );
        ZKChainSpecificForceDeploymentsData memory additionalForceDeploymentsData = abi.decode(
            _additionalForceDeploymentsData,
            (ZKChainSpecificForceDeploymentsData)
        );

        IComplexUpgrader.ContractUpgradeType expectedUpgradeType = _isZKsyncOS
            ? IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade
            : IComplexUpgrader.ContractUpgradeType.EraForceDeployment;

        _setupProxyAdmin();
        _deployCoreContracts({
            expectedUpgradeType: expectedUpgradeType,
            fixedForceDeploymentsData: fixedForceDeploymentsData,
            additionalForceDeploymentsData: additionalForceDeploymentsData,
            _isGenesisUpgrade: _isGenesisUpgrade,
            _isZKsyncOS: _isZKsyncOS
        });
        _deployTokenInfrastructure({
            expectedUpgradeType: expectedUpgradeType,
            fixedForceDeploymentsData: fixedForceDeploymentsData,
            additionalForceDeploymentsData: additionalForceDeploymentsData,
            _isGenesisUpgrade: _isGenesisUpgrade,
            _isZKsyncOS: _isZKsyncOS
        });
        _finalizeDeployments(_ctmDeployer, fixedForceDeploymentsData, additionalForceDeploymentsData);
    }

    function _setupProxyAdmin() private {
        // For Era chains, the SystemContractProxyAdmin is never used during deployment, but it is expected to be present
        // just in case. This line is just for consistency.
        // For ZKsyncOS chains, we expect that both the contract and the owner has been populated at the time of the genesis.
        // These are not predeployed only for legacy chains. For them, special logic (not covered here) would be used to ensure
        // that they have this contract is predeployed and the owner is set correctly.
        if (SystemContractProxyAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR).owner() != address(this)) {
            SystemContractProxyAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR).forceSetOwner(address(this));
        }
    }

    function _deployCoreContracts(
        IComplexUpgrader.ContractUpgradeType expectedUpgradeType,
        FixedForceDeploymentsData memory fixedForceDeploymentsData,
        ZKChainSpecificForceDeploymentsData memory additionalForceDeploymentsData,
        bool _isGenesisUpgrade,
        bool _isZKsyncOS
    ) private {
        emit MessageRootUpgradeStarted();
        // During the genesis of zksync os. Contracts has been already deployed and initialized.
        // It's not necessary to redeploy or reinitialize them.
        if (!(_isZKsyncOS && _isGenesisUpgrade)) {
            conductContractUpgrade(
                expectedUpgradeType,
                fixedForceDeploymentsData.messageRootBytecodeInfo,
                address(L2_MESSAGE_ROOT_ADDR)
            );
        }
        // If this is a genesis upgrade, we need to initialize the MessageRoot contract.
        // We dont need to do anything for already deployed chains.
        if (_isGenesisUpgrade) {
            L2MessageRoot(L2_MESSAGE_ROOT_ADDR).initL2(
                fixedForceDeploymentsData.l1ChainId,
                fixedForceDeploymentsData.gatewayChainId
            );
        }

        emit BridgehubUpgradeStarted();
        // During the genesis of zksync os. Contracts has been already deployed and initialized.
        // It's not necessary to redeploy or reinitialize them.
        if (!(_isZKsyncOS && _isGenesisUpgrade)) {
            conductContractUpgrade(
                expectedUpgradeType,
                fixedForceDeploymentsData.bridgehubBytecodeInfo,
                address(L2_BRIDGEHUB_ADDR)
            );
        }
        if (_isGenesisUpgrade) {
            emit BridgehubInitStarted(fixedForceDeploymentsData.l1ChainId);
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
            : address(L2AssetRouter(L2_ASSET_ROUTER_ADDR).L2_LEGACY_SHARED_BRIDGE());

        // During the genesis of zksync os. Contracts has been already deployed and initialized.
        // It's not necessary to redeploy or reinitialize them.
        emit AssetRouterUpgradeStarted();
        if (!(_isZKsyncOS && _isGenesisUpgrade)) {
            conductContractUpgrade(
                expectedUpgradeType,
                fixedForceDeploymentsData.l2AssetRouterBytecodeInfo,
                address(L2_ASSET_ROUTER_ADDR)
            );
        }
        if (_isGenesisUpgrade) {
            emit AssetRouterInitStarted(fixedForceDeploymentsData.l1ChainId, fixedForceDeploymentsData.eraChainId);
            // solhint-disable-next-line func-named-parameters
            L2AssetRouter(L2_ASSET_ROUTER_ADDR).initL2(
                fixedForceDeploymentsData.l1ChainId,
                fixedForceDeploymentsData.eraChainId,
                IL1AssetRouter(fixedForceDeploymentsData.l1AssetRouter),
                IL2SharedBridgeLegacy(l2LegacySharedBridge),
                additionalForceDeploymentsData.baseTokenBridgingData.assetId,
                fixedForceDeploymentsData.aliasedL1Governance
            );
        } else {
            // solhint-disable-next-line func-named-parameters
            L2AssetRouter(L2_ASSET_ROUTER_ADDR).updateL2(
                fixedForceDeploymentsData.l1ChainId,
                fixedForceDeploymentsData.eraChainId,
                IL1AssetRouter(fixedForceDeploymentsData.l1AssetRouter),
                IL2SharedBridgeLegacy(l2LegacySharedBridge),
                additionalForceDeploymentsData.baseTokenBridgingData.assetId
            );
        }
    }

    function _deployTokenInfrastructure(
        IComplexUpgrader.ContractUpgradeType expectedUpgradeType,
        FixedForceDeploymentsData memory fixedForceDeploymentsData,
        ZKChainSpecificForceDeploymentsData memory additionalForceDeploymentsData,
        bool _isGenesisUpgrade,
        bool _isZKsyncOS
    ) private {
        address predeployedL2WethAddress = _isGenesisUpgrade
            ? address(0)
            : L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).WETH_TOKEN();
        bytes32 previousL2TokenProxyBytecodeHash = _isGenesisUpgrade
            ? bytes32(0)
            : L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).L2_TOKEN_PROXY_BYTECODE_HASH();

        // Ensure the WETH token is deployed and retrieve its address.
        emit WethTokenEnsureStarted();
        address wrappedBaseTokenAddress = _ensureWethToken({
            _predeployedWethToken: predeployedL2WethAddress,
            _aliasedL1Governance: fixedForceDeploymentsData.aliasedL1Governance,
            _baseTokenL1Address: additionalForceDeploymentsData.baseTokenL1Address,
            _baseTokenAssetId: additionalForceDeploymentsData.baseTokenBridgingData.assetId,
            _baseTokenName: additionalForceDeploymentsData.baseTokenMetadata.name,
            _baseTokenSymbol: additionalForceDeploymentsData.baseTokenMetadata.symbol
        });
        emit WethTokenEnsured(wrappedBaseTokenAddress);

        emit NtvUpgradeStarted();
        if (!(_isZKsyncOS && _isGenesisUpgrade)) {
            // Now initializing the upgradeable token beacon
            conductContractUpgrade(
                expectedUpgradeType,
                fixedForceDeploymentsData.l2NtvBytecodeInfo,
                L2_NATIVE_TOKEN_VAULT_ADDR
            );
        }
        if (_isGenesisUpgrade) {
            emit NtvInitStarted(fixedForceDeploymentsData.l1ChainId);
            address deployedTokenBeacon;
            // In production, the `fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon` must always
            // be equal to 0. It is only for simplifying testing.
            if (fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon == address(0)) {
                // We need to deploy the beacon, we will use a separate contract for that to save
                // up on size of this contract.
                if (!_isZKsyncOS) {
                    conductContractUpgrade(
                        expectedUpgradeType,
                        fixedForceDeploymentsData.beaconDeployerInfo,
                        L2_NTV_BEACON_DEPLOYER_ADDR
                    );
                }
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
                additionalForceDeploymentsData.baseTokenBridgingData,
                additionalForceDeploymentsData.baseTokenMetadata
            );
        } else {
            address l2LegacySharedBridge = address(L2AssetRouter(L2_ASSET_ROUTER_ADDR).L2_LEGACY_SHARED_BRIDGE());
            // solhint-disable-next-line func-named-parameters
            L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).updateL2(
                fixedForceDeploymentsData.l1ChainId,
                previousL2TokenProxyBytecodeHash,
                l2LegacySharedBridge,
                wrappedBaseTokenAddress,
                additionalForceDeploymentsData.baseTokenBridgingData,
                additionalForceDeploymentsData.baseTokenMetadata
            );
        }

        emit ChainAssetHandlerUpgradeStarted();
        if (!(_isZKsyncOS && _isGenesisUpgrade)) {
            conductContractUpgrade(
                expectedUpgradeType,
                fixedForceDeploymentsData.chainAssetHandlerBytecodeInfo,
                address(L2_CHAIN_ASSET_HANDLER_ADDR)
            );
        }
        if (_isGenesisUpgrade) {
            emit ChainAssetHandlerInitStarted(fixedForceDeploymentsData.l1ChainId);
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
        if (!(_isZKsyncOS && _isGenesisUpgrade)) {
            conductContractUpgrade(
                expectedUpgradeType,
                fixedForceDeploymentsData.assetTrackerBytecodeInfo,
                L2_ASSET_TRACKER_ADDR
            );

            conductContractUpgrade(
                expectedUpgradeType,
                fixedForceDeploymentsData.interopCenterBytecodeInfo,
                L2_INTEROP_CENTER_ADDR
            );
        }
        if (_isGenesisUpgrade) {
            InteropCenter(L2_INTEROP_CENTER_ADDR).initL2(
                fixedForceDeploymentsData.l1ChainId,
                fixedForceDeploymentsData.aliasedL1Governance
            );
        }
        if (!(_isZKsyncOS && _isGenesisUpgrade)) {
            conductContractUpgrade(
                expectedUpgradeType,
                fixedForceDeploymentsData.interopHandlerBytecodeInfo,
                L2_INTEROP_HANDLER_ADDR
            );
        }
    }

    function _finalizeDeployments(
        address _ctmDeployer,
        FixedForceDeploymentsData memory fixedForceDeploymentsData,
        ZKChainSpecificForceDeploymentsData memory additionalForceDeploymentsData
    ) private {
        // It is expected that either through the force deployments above
        // or upon initialization, both the L2 deployment of BridgeHub, AssetRouter, and MessageRoot are deployed.
        // However, there is still some follow-up finalization that needs to be done.

        emit BridgehubSetAddressesStarted();
        L2Bridgehub(L2_BRIDGEHUB_ADDR).setAddresses({
            _assetRouter: L2_ASSET_ROUTER_ADDR,
            _l1CtmDeployer: ICTMDeploymentTracker(_ctmDeployer),
            _messageRoot: IMessageRoot(L2_MESSAGE_ROOT_ADDR),
            _chainAssetHandler: L2_CHAIN_ASSET_HANDLER_ADDR,
            _chainRegistrationSender: fixedForceDeploymentsData.aliasedChainRegistrationSender
        });

        L2AssetTracker(L2_ASSET_TRACKER_ADDR).setAddresses(
            fixedForceDeploymentsData.l1ChainId,
            additionalForceDeploymentsData.baseTokenBridgingData.assetId
        );

        GWAssetTracker(GW_ASSET_TRACKER_ADDR).setAddresses(fixedForceDeploymentsData.l1ChainId);

        L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).setAddresses(
            additionalForceDeploymentsData.baseTokenBridgingData.originChainId
        );

        InteropHandler(L2_INTEROP_HANDLER_ADDR).initL2(fixedForceDeploymentsData.l1ChainId);
        emit PerformForceDeployedContractsInitCompleted();
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
            // We could've deployed the implementation, but we keep it predeployed for consistency purposes with Era.
            L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
            _aliasedL1Governance,
            initData
        );

        return address(proxy);
    }
}
