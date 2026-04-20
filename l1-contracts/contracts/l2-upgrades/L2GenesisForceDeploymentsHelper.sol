// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {
    GW_ASSET_TRACKER_ADDR,
    L2_ASSET_TRACKER_ADDR,
    L2_ASSET_ROUTER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_MESSAGE_ROOT_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_NTV_BEACON_DEPLOYER_ADDR,
    L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
    L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR,
    L2_INTEROP_CENTER_ADDR
} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IL2BaseTokenBase} from "../l2-system/interfaces/IL2BaseTokenBase.sol";
import {IL2ContractDeployer} from "../common/interfaces/IL2ContractDeployer.sol";
import {
    FixedForceDeploymentsData,
    ZKChainSpecificForceDeploymentsData
} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IL2WrappedBaseToken} from "../bridge/interfaces/IL2WrappedBaseToken.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SystemContractProxyAdmin} from "./SystemContractProxyAdmin.sol";
import {IZKOSContractDeployer} from "contracts/l2-system/zksync-os/interfaces/IZKOSContractDeployer.sol";
import {L2NativeTokenVault} from "../bridge/ntv/L2NativeTokenVault.sol";
import {L2MessageRoot} from "../core/message-root/L2MessageRoot.sol";
import {L2Bridgehub} from "../core/bridgehub/L2Bridgehub.sol";
import {L2AssetRouter} from "../bridge/asset-router/L2AssetRouter.sol";
import {IL2AssetTracker} from "../bridge/asset-tracker/IL2AssetTracker.sol";
import {L2AssetTracker} from "../bridge/asset-tracker/L2AssetTracker.sol";
import {GWAssetTracker} from "../bridge/asset-tracker/GWAssetTracker.sol";
import {L2ChainAssetHandler} from "../core/chain-asset-handler/L2ChainAssetHandler.sol";
import {InteropHandler} from "../interop/InteropHandler.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {IL2SharedBridgeLegacy} from "../bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {
    DeployFailed,
    UnsupportedUpgradeType,
    ZKsyncOSNotForceDeployForExistingContract,
    ZKsyncOSNotForceDeployToPrecompileAddress,
    NonCanonicalRepresentation
} from "../common/L1ContractErrors.sol";

import {L2NativeTokenVaultZKOS} from "../bridge/ntv/L2NativeTokenVaultZKOS.sol";

import {ICTMDeploymentTracker} from "../core/ctm-deployment/ICTMDeploymentTracker.sol";
import {IMessageRootBase} from "../core/message-root/IMessageRoot.sol";
import {InteropCenter} from "../interop/InteropCenter.sol";

import {UpgradeableBeaconDeployer} from "../bridge/UpgradeableBeaconDeployer.sol";
import {ISystemContractProxy} from "./ISystemContractProxy.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";

import {BYTECODE_INFO_LENGTH, ZKSyncOSBytecodeInfo} from "../common/libraries/ZKSyncOSBytecodeInfo.sol";

/// @title L2GenesisForceDeploymentsHelper
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A helper library for initializing and managing force-deployed contracts during either the L2 gateway upgrade or
/// the genesis after the gateway protocol upgrade.
library L2GenesisForceDeploymentsHelper {
    /// @notice Emitted when a contract is deployed or upgraded during the force-deployment flow.
    event ContractUpgraded(IComplexUpgrader.ContractUpgradeType indexed upgradeType, address indexed targetAddress);

    /// @notice Emitted once the full force-deployed contracts initialization flow completes.
    event ForceDeployedContractsInitialized(bool isZKsyncOS, bool isGenesisUpgrade);

    function forceDeployEra(bytes memory _bytecodeInfo, address _newAddress) internal {
        bytes32 bytecodeHash = abi.decode(_bytecodeInfo, (bytes32));
        IL2ContractDeployer.ForceDeployment[] memory forceDeployments = new IL2ContractDeployer.ForceDeployment[](1);
        forceDeployments[0] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: bytecodeHash,
            newAddress: _newAddress,
            callConstructor: false,
            value: 0,
            input: hex""
        });

        bytes memory data = abi.encodeCall(IL2ContractDeployer.forceDeployOnAddresses, (forceDeployments));

        (bool success, ) = L2_DEPLOYER_SYSTEM_CONTRACT_ADDR.call(data);
        if (!success) {
            revert DeployFailed();
        }
    }

    function unsafeForceDeployZKsyncOS(bytes memory _bytecodeInfo, address _newAddress) internal {
        // Validate canonical encoding for (bytes32, uint32, bytes32)
        require(_bytecodeInfo.length == BYTECODE_INFO_LENGTH, NonCanonicalRepresentation());

        // Decode the bytecode info using the library
        (bytes32 bytecodeHash, uint256 bytecodeLength256, bytes32 observableBytecodeHash) = ZKSyncOSBytecodeInfo
            .decodeZKSyncOSBytecodeInfo(_bytecodeInfo);

        // Convert to uint32 for the contract deployer interface
        uint32 bytecodeLength = uint32(bytecodeLength256);

        bytes memory data = abi.encodeCall(
            IZKOSContractDeployer.setBytecodeDetailsEVM,
            (_newAddress, bytecodeHash, bytecodeLength, observableBytecodeHash)
        );
        // Note, that we don't use the interface, but a raw call to avoid Solidity checking for empty bytecode.
        (bool success, ) = L2_DEPLOYER_SYSTEM_CONTRACT_ADDR.call(data);
        if (!success) {
            revert DeployFailed();
        }
    }

    function forceDeployOnAddressZKsyncOS(bytes memory _bytecodeInfo, address _newAddress) internal {
        require(_newAddress.code.length == 0, ZKsyncOSNotForceDeployForExistingContract(_newAddress));

        // Block deployment to precompile addresses (0x01-0xFF) and zero address.
        uint160 addr = uint160(_newAddress);
        require(addr > 0xFF, ZKsyncOSNotForceDeployToPrecompileAddress(_newAddress));

        unsafeForceDeployZKsyncOS(_bytecodeInfo, _newAddress);
    }

    /// @notice A random address in the user space derived from the bytecode info.
    /// @dev The first 32 bytes of the preimage are 0s to ensure that the address will never collide with neither create nor create2.
    /// This is the case, since for both create and create2 the preimage for hash starts with a non-zero byte.
    function generateRandomAddress(bytes memory _bytecodeInfo) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes.concat(bytes32(0), _bytecodeInfo)))));
    }

    function updateZKsyncOSContract(bytes memory _bytecodeInfo, address _newAddress) internal {
        // The ABI encoding of (bytes, bytes) has at least 64 bytes of overhead from the two offset words.
        require(_bytecodeInfo.length >= 64, NonCanonicalRepresentation());

        (bytes memory bytecodeInfo, bytes memory bytecodeInfoSystemProxy) = abi.decode((_bytecodeInfo), (bytes, bytes));

        // This data is provided by decentralized governance, so it can be trusted to be encoded correctly.
        // We still verify canonical encoding as an extra safety measure.
        bytes memory canonicalEncoding = abi.encode(bytecodeInfo, bytecodeInfoSystemProxy);
        require(keccak256(_bytecodeInfo) == keccak256(canonicalEncoding), NonCanonicalRepresentation());

        address implAddress = generateRandomAddress(bytecodeInfo);
        // We skip force deploying if the bytecode has not changed to make upgrades simpler.
        if (implAddress.code.length == 0) {
            forceDeployOnAddressZKsyncOS(bytecodeInfo, implAddress);
        } else {
            // We cannot just assume the bytecode is correct. The address derivation makes collisions
            // extremely unlikely, but not impossible, so we verify the deployed code hash matches.
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

        // If the proxy has not been deployed yet, deploy it and initialize its admin.
        if (_newAddress.code.length == 0) {
            forceDeployOnAddressZKsyncOS(bytecodeInfoSystemProxy, _newAddress);
            ISystemContractProxy(_newAddress).forceInitAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR);
        }

        SystemContractProxyAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR).upgrade(
            ITransparentUpgradeableProxy(_newAddress),
            implAddress
        );
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
        if (_upgradeType == IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment) {
            unsafeForceDeployZKsyncOS(_bytecodeInfo, _newAddress);
        } else if (_upgradeType == IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade) {
            updateZKsyncOSContract(_bytecodeInfo, _newAddress);
        } else if (_upgradeType == IComplexUpgrader.ContractUpgradeType.EraForceDeployment) {
            forceDeployEra(_bytecodeInfo, _newAddress);
        } else {
            revert UnsupportedUpgradeType();
        }
        emit ContractUpgraded(_upgradeType, _newAddress);
    }

    /// @notice Initializes force-deployed contracts.
    /// @dev Note, that this function is expected to initialize all system contracts deployed within the user space
    /// with the only exception of the SystemContractProxyAdmin, which is expected to be initialized inside the Genesis.
    /// @dev Contract deployment (conductContractUpgrade) is handled externally via the force deployment list.
    /// This function only performs initialization (initL2/updateL2 calls).
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

        _setupProxyAdmin();

        // Ensure WETH token exists. During genesis NTV.WETH_TOKEN() returns address(0)
        // (uninitialized storage), so _ensureWethToken deploys a new proxy.
        // During upgrades it returns the existing address and _ensureWethToken is a no-op.
        address wrappedBaseTokenAddress = _ensureWethToken({
            _predeployedWethToken: L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).WETH_TOKEN(),
            _aliasedL1Governance: fixedForceDeploymentsData.aliasedL1Governance,
            _baseTokenL1Address: additionalForceDeploymentsData.baseTokenL1Address,
            _baseTokenAssetId: additionalForceDeploymentsData.baseTokenBridgingData.assetId,
            _baseTokenName: additionalForceDeploymentsData.baseTokenMetadata.name,
            _baseTokenSymbol: additionalForceDeploymentsData.baseTokenMetadata.symbol
        });

        if (_isGenesisUpgrade) {
            _initAllContracts(fixedForceDeploymentsData, additionalForceDeploymentsData, wrappedBaseTokenAddress);
        } else {
            _updateAllContracts(fixedForceDeploymentsData, additionalForceDeploymentsData, wrappedBaseTokenAddress);
        }
        _finalizeDeployments(_ctmDeployer, fixedForceDeploymentsData);

        _initializeV31Contracts(
            _isZKsyncOS,
            _isGenesisUpgrade,
            fixedForceDeploymentsData,
            additionalForceDeploymentsData
        );

        emit ForceDeployedContractsInitialized(_isZKsyncOS, _isGenesisUpgrade);
    }

    function _setupProxyAdmin() private {
        // For Era chains, the SystemContractProxyAdmin is never used during deployment, but it is expected to be present
        // just in case. This line is just for consistency.
        // For ZKsyncOS chains, we expect that both the contract and the owner have been populated at the time of the genesis.
        // These are not predeployed only for legacy chains. For them, special logic (not covered here) would be used to ensure
        // that this contract is predeployed and the owner is set correctly.
        if (SystemContractProxyAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR).owner() != address(this)) {
            SystemContractProxyAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR).forceSetOwner(address(this));
        }
    }

    /// @notice Calls initL2() on ALL contracts. Used during genesis only.
    function _initAllContracts(
        FixedForceDeploymentsData memory _fixedForceDeploymentsData,
        ZKChainSpecificForceDeploymentsData memory _additionalForceDeploymentsData,
        address _wrappedBaseTokenAddress
    ) private {
        L2MessageRoot(L2_MESSAGE_ROOT_ADDR).initL2(
            _fixedForceDeploymentsData.l1ChainId,
            _fixedForceDeploymentsData.gatewayChainId
        );

        L2Bridgehub(L2_BRIDGEHUB_ADDR).initL2(
            _fixedForceDeploymentsData.l1ChainId,
            _fixedForceDeploymentsData.aliasedL1Governance,
            _fixedForceDeploymentsData.maxNumberOfZKChains
        );

        // solhint-disable-next-line func-named-parameters
        L2AssetRouter(L2_ASSET_ROUTER_ADDR).initL2(
            _fixedForceDeploymentsData.l1ChainId,
            _fixedForceDeploymentsData.eraChainId,
            IL1AssetRouter(_fixedForceDeploymentsData.l1AssetRouter),
            IL2SharedBridgeLegacy(address(0)), // no legacy bridge for new chains
            _additionalForceDeploymentsData.baseTokenBridgingData.assetId,
            _fixedForceDeploymentsData.aliasedL1Governance
        );

        address deployedTokenBeacon;
        if (_fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon == address(0)) {
            deployedTokenBeacon = UpgradeableBeaconDeployer(L2_NTV_BEACON_DEPLOYER_ADDR).deployUpgradeableBeacon(
                _fixedForceDeploymentsData.aliasedL1Governance
            );
        } else {
            deployedTokenBeacon = _fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon;
        }

        // solhint-disable-next-line func-named-parameters
        L2NativeTokenVaultZKOS(L2_NATIVE_TOKEN_VAULT_ADDR).initL2(
            _fixedForceDeploymentsData.l1ChainId,
            _fixedForceDeploymentsData.aliasedL1Governance,
            _fixedForceDeploymentsData.l2TokenProxyBytecodeHash,
            _additionalForceDeploymentsData.l2LegacySharedBridge,
            deployedTokenBeacon,
            _wrappedBaseTokenAddress,
            _additionalForceDeploymentsData.baseTokenBridgingData,
            _additionalForceDeploymentsData.baseTokenMetadata
        );

        L2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR).initL2(
            _fixedForceDeploymentsData.l1ChainId,
            _fixedForceDeploymentsData.aliasedL1Governance
        );
    }

    /// @notice Calls updateL2() on ALL contracts. Used during non-genesis upgrades.
    function _updateAllContracts(
        FixedForceDeploymentsData memory _fixedForceDeploymentsData,
        ZKChainSpecificForceDeploymentsData memory _additionalForceDeploymentsData,
        address _wrappedBaseTokenAddress
    ) private {
        L2MessageRoot(L2_MESSAGE_ROOT_ADDR).updateL2(
            _fixedForceDeploymentsData.l1ChainId,
            _fixedForceDeploymentsData.gatewayChainId
        );

        L2Bridgehub(L2_BRIDGEHUB_ADDR).updateL2(
            _fixedForceDeploymentsData.l1ChainId,
            _fixedForceDeploymentsData.aliasedL1Governance,
            _fixedForceDeploymentsData.maxNumberOfZKChains
        );

        // solhint-disable-next-line func-named-parameters
        L2AssetRouter(L2_ASSET_ROUTER_ADDR).updateL2(
            _fixedForceDeploymentsData.l1ChainId,
            _fixedForceDeploymentsData.eraChainId,
            IL1AssetRouter(_fixedForceDeploymentsData.l1AssetRouter),
            IL2SharedBridgeLegacy(_getLegacySharedBridge()),
            _additionalForceDeploymentsData.baseTokenBridgingData.assetId,
            _fixedForceDeploymentsData.aliasedL1Governance
        );

        bytes32 previousL2TokenProxyBytecodeHash = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR)
            .L2_TOKEN_PROXY_BYTECODE_HASH();

        // solhint-disable-next-line func-named-parameters
        L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).updateL2(
            _fixedForceDeploymentsData.l1ChainId,
            _fixedForceDeploymentsData.aliasedL1Governance,
            previousL2TokenProxyBytecodeHash,
            _getLegacySharedBridge(),
            _wrappedBaseTokenAddress,
            _additionalForceDeploymentsData.baseTokenBridgingData,
            _additionalForceDeploymentsData.baseTokenMetadata
        );

        L2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR).updateL2(
            _fixedForceDeploymentsData.l1ChainId,
            _fixedForceDeploymentsData.aliasedL1Governance
        );
    }

    function _finalizeDeployments(
        address _ctmDeployer,
        FixedForceDeploymentsData memory _fixedForceDeploymentsData
    ) private {
        L2Bridgehub(L2_BRIDGEHUB_ADDR).setAddresses({
            _assetRouter: L2_ASSET_ROUTER_ADDR,
            _l1CtmDeployer: ICTMDeploymentTracker(_ctmDeployer),
            _messageRoot: IMessageRootBase(L2_MESSAGE_ROOT_ADDR),
            _chainAssetHandler: L2_CHAIN_ASSET_HANDLER_ADDR,
            _chainRegistrationSender: _fixedForceDeploymentsData.aliasedChainRegistrationSender
        });
    }

    /// @notice Initializes contracts introduced in v31 using ABI-encoded deployment data.
    function initializeV31Contracts(
        bool _isZKsyncOS,
        bool _isGenesisUpgrade,
        bytes memory _fixedForceDeploymentsData,
        bytes memory _additionalForceDeploymentsData
    ) internal {
        FixedForceDeploymentsData memory fixedForceDeploymentsData = abi.decode(
            _fixedForceDeploymentsData,
            (FixedForceDeploymentsData)
        );
        ZKChainSpecificForceDeploymentsData memory additionalForceDeploymentsData = abi.decode(
            _additionalForceDeploymentsData,
            (ZKChainSpecificForceDeploymentsData)
        );

        _initializeV31Contracts(
            _isZKsyncOS,
            _isGenesisUpgrade,
            fixedForceDeploymentsData,
            additionalForceDeploymentsData
        );
    }

    /// @notice Initializes contracts introduced in v31: AssetTracker, GWAssetTracker,
    /// InteropHandler, L2BaseToken, and base token registration.
    /// @dev Called after `_finalizeDeployments` as part of `performForceDeployedContractsInit()`.
    /// Keeping this in the library ensures a single source of truth for v31-specific initialization.
    function _initializeV31Contracts(
        bool _isZKsyncOS,
        bool _isGenesisUpgrade,
        FixedForceDeploymentsData memory _fixedForceDeploymentsData,
        ZKChainSpecificForceDeploymentsData memory _additionalForceDeploymentsData
    ) private {
        L2AssetTracker(L2_ASSET_TRACKER_ADDR).initL2(
            _fixedForceDeploymentsData.l1ChainId,
            _additionalForceDeploymentsData.baseTokenBridgingData.assetId,
            // The only chains that need backfill for the base token's total supply are ZKsync OS
            // chains that existed before the v31 upgrade (i.e. isGenesis is false).
            _isZKsyncOS && !_isGenesisUpgrade
        );

        GWAssetTracker(GW_ASSET_TRACKER_ADDR).initL2(
            _fixedForceDeploymentsData.l1ChainId,
            _fixedForceDeploymentsData.aliasedL1Governance
        );

        InteropHandler(L2_INTEROP_HANDLER_ADDR).initL2(_fixedForceDeploymentsData.l1ChainId);

        InteropCenter(L2_INTEROP_CENTER_ADDR).initL2(
            _fixedForceDeploymentsData.l1ChainId,
            _fixedForceDeploymentsData.aliasedL1Governance,
            _fixedForceDeploymentsData.zkTokenAssetId
        );

        // Register the base token in the AssetTracker.
        // During genesis, NTV.registerBaseTokenIfNeeded() handles it.
        // During upgrades, AssetTracker.registerBaseTokenDuringUpgrade() handles it.
        if (_isGenesisUpgrade) {
            L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).registerBaseTokenIfNeeded();
        } else {
            IL2AssetTracker(L2_ASSET_TRACKER_ADDR).registerBaseTokenDuringUpgrade();
        }

        // Initialize L2BaseToken: sets L1_CHAIN_ID and initializes the BaseTokenHolder balance.
        // For Era: reads __DEPRECATED_totalSupply and computes holder balance.
        // For ZKOS: mints via MINT_BASE_TOKEN_HOOK and transfers to holder.
        IL2BaseTokenBase(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initL2(_fixedForceDeploymentsData.l1ChainId);
    }

    /// @notice Returns the address of the legacy shared bridge from the L2 Asset Router.
    function _getLegacySharedBridge() private view returns (address) {
        return address(L2AssetRouter(L2_ASSET_ROUTER_ADDR).L2_LEGACY_SHARED_BRIDGE());
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
