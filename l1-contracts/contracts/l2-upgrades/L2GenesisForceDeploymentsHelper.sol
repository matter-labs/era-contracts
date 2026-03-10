// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {
    GW_ASSET_TRACKER_ADDR,
    L2_ASSET_TRACKER_ADDR,
    L2_ASSET_ROUTER_ADDR,
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
    /// @notice Emitted when a contract upgrade (deploy or proxy update) is performed via `conductContractUpgrade`.
    event ContractUpgraded(
        IComplexUpgrader.ContractUpgradeType indexed upgradeType,
        address indexed targetAddress
    );

    /// @notice Emitted when the full force-deployed contracts initialization completes.
    event ForceDeployedContractsInitialized(bool isZKsyncOS, bool isGenesisUpgrade);

    /// @notice Force-deploys a contract on Era by calling the L2 deployer system contract.
    /// @param _bytecodeInfo ABI-encoded bytecode hash (bytes32) of the contract to deploy.
    /// @param _newAddress The target address for the deployment.
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

    /// @notice Deploys bytecode on ZKsync OS by setting bytecode details via the deployer system contract.
    /// @dev "Unsafe" because it skips the checks for existing code and precompile addresses that
    /// `forceDeployOnAddressZKsyncOS` performs. Should only be used when those checks are intentionally skipped.
    /// @param _bytecodeInfo ABI-encoded tuple of (bytecodeHash, bytecodeLength, observableBytecodeHash).
    /// @param _newAddress The target address for the deployment.
    function unsafeForceDeployZKsyncOS(bytes memory _bytecodeInfo, address _newAddress) internal {
        require(_bytecodeInfo.length == BYTECODE_INFO_LENGTH, NonCanonicalRepresentation());

        (bytes32 bytecodeHash, uint256 bytecodeLength256, bytes32 observableBytecodeHash) = ZKSyncOSBytecodeInfo
            .decodeZKSyncOSBytecodeInfo(_bytecodeInfo);

        uint32 bytecodeLength = uint32(bytecodeLength256);

        bytes memory data = abi.encodeCall(
            IZKOSContractDeployer.setBytecodeDetailsEVM,
            (_newAddress, bytecodeHash, bytecodeLength, observableBytecodeHash)
        );
        // Note, that we don't use the interface, but a raw call to avoid Solidity checking for empty bytecode
        (bool success, ) = L2_DEPLOYER_SYSTEM_CONTRACT_ADDR.call(data);
        if (!success) {
            revert DeployFailed();
        }
    }

    /// @notice Safe wrapper around `unsafeForceDeployZKsyncOS` that validates the target address.
    /// @dev Reverts if `_newAddress` already has code or is a precompile/zero address.
    /// @param _bytecodeInfo ABI-encoded tuple of (bytecodeHash, bytecodeLength, observableBytecodeHash).
    /// @param _newAddress The target address for the deployment.
    function forceDeployOnAddressZKsyncOS(bytes memory _bytecodeInfo, address _newAddress) internal {
        require(_newAddress.code.length == 0, ZKsyncOSNotForceDeployForExistingContract(_newAddress));

        uint160 addr = uint160(_newAddress);
        require(addr > 0xFF, ZKsyncOSNotForceDeployToPrecompileAddress(_newAddress));

        unsafeForceDeployZKsyncOS(_bytecodeInfo, _newAddress);
    }

    /// @notice Derives a deterministic address in user space from the bytecode info.
    /// @dev The first 32 bytes of the hash preimage are zeros, which guarantees no collision with
    /// CREATE or CREATE2 addresses (both start their preimage with a non-zero byte).
    /// @param _bytecodeInfo The bytecode information used as the hash preimage.
    /// @return The derived address.
    function generateRandomAddress(bytes memory _bytecodeInfo) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes.concat(bytes32(0), _bytecodeInfo)))));
    }

    /// @notice Upgrades a ZKsync OS system contract by deploying a new implementation and updating the proxy.
    /// @dev `_bytecodeInfo` is an ABI-encoded tuple of (implBytecodeInfo, proxyBytecodeInfo). The implementation
    /// is deployed at a deterministic address derived from its bytecode info. If the proxy at `_newAddress` does not
    /// exist yet, it is also deployed and its admin is initialized.
    /// @param _bytecodeInfo ABI-encoded (bytes, bytes) containing the implementation and proxy bytecode info.
    /// @param _newAddress The proxy address to upgrade (or deploy + upgrade if it doesn't exist yet).
    function updateZKsyncOSContract(bytes memory _bytecodeInfo, address _newAddress) internal {
        // The ABI encoding of (bytes, bytes) has at least 64 bytes of overhead (two offset words).
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
            // We cannot just assume the bytecode is correct. Even though the address derivation makes
            // collisions extremely unlikely, they are non-zero (a birthday attack is possible if a malicious
            // person controls both the correct and malicious source code). So we verify the code matches.
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

        // If the proxy hasn't been deployed yet, deploy it and initialize its admin.
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

    /// @notice Deploys and initializes all force-deployed system contracts in user space.
    /// @dev Initializes every system contract except SystemContractProxyAdmin, which is expected to be
    /// initialized inside the Genesis. For genesis upgrades, calls `initL2` on each contract; for
    /// non-genesis upgrades, calls `updateL2`. On ZKsync OS genesis, contracts are already deployed
    /// so only initialization is performed.
    /// @param _isZKsyncOS Whether the target chain runs on ZKsync OS (as opposed to Era).
    /// @param _ctmDeployer Address of the CTM Deployer contract.
    /// @param _fixedForceDeploymentsData ABI-encoded `FixedForceDeploymentsData`, the same for all chains.
    /// @param _additionalForceDeploymentsData ABI-encoded `ZKChainSpecificForceDeploymentsData`, specific per chain.
    /// @param _isGenesisUpgrade Whether this is a first-time genesis or a subsequent upgrade.
    function performForceDeployedContractsInit(
        bool _isZKsyncOS,
        address _ctmDeployer,
        bytes memory _fixedForceDeploymentsData,
        bytes memory _additionalForceDeploymentsData,
        bool _isGenesisUpgrade
    ) internal {
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
        _finalizeDeployments({
            _ctmDeployer: _ctmDeployer,
            fixedForceDeploymentsData: fixedForceDeploymentsData,
            additionalForceDeploymentsData: additionalForceDeploymentsData,
            _isZKsyncOS: _isZKsyncOS,
            _isGenesisUpgrade: _isGenesisUpgrade
        });

        emit ForceDeployedContractsInitialized(_isZKsyncOS, _isGenesisUpgrade);
    }

    /// @dev Ensures this contract (the upgrader) owns the SystemContractProxyAdmin.
    /// On Era chains the proxy admin is not actively used during deployment, but we claim ownership for consistency.
    /// On ZKsync OS chains the contract and owner are expected to already exist from genesis.
    /// Legacy chains that lack this predeployment use separate logic (not covered here) to set it up.
    function _setupProxyAdmin() private {
        if (SystemContractProxyAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR).owner() != address(this)) {
            SystemContractProxyAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR).forceSetOwner(address(this));
        }
    }

    /// @dev Deploys and initializes core protocol contracts: MessageRoot, Bridgehub, and AssetRouter.
    /// On ZKsync OS genesis these contracts have already been deployed, so only initialization is performed.
    function _deployCoreContracts(
        IComplexUpgrader.ContractUpgradeType expectedUpgradeType,
        FixedForceDeploymentsData memory fixedForceDeploymentsData,
        ZKChainSpecificForceDeploymentsData memory additionalForceDeploymentsData,
        bool _isGenesisUpgrade,
        bool _isZKsyncOS
    ) private {
        if (!(_isZKsyncOS && _isGenesisUpgrade)) {
            conductContractUpgrade(
                expectedUpgradeType,
                fixedForceDeploymentsData.messageRootBytecodeInfo,
                address(L2_MESSAGE_ROOT_ADDR)
            );
        }
        // Genesis requires full initialization; non-genesis only updates the existing state.
        if (_isGenesisUpgrade) {
            L2MessageRoot(L2_MESSAGE_ROOT_ADDR).initL2(
                fixedForceDeploymentsData.l1ChainId,
                fixedForceDeploymentsData.gatewayChainId
            );
        } else {
            L2MessageRoot(L2_MESSAGE_ROOT_ADDR).updateL2(
                fixedForceDeploymentsData.l1ChainId,
                fixedForceDeploymentsData.gatewayChainId
            );
        }

        if (!(_isZKsyncOS && _isGenesisUpgrade)) {
            conductContractUpgrade(
                expectedUpgradeType,
                fixedForceDeploymentsData.bridgehubBytecodeInfo,
                address(L2_BRIDGEHUB_ADDR)
            );
        }
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

        // For new chains, there is no legacy shared bridge, but for already existing ones
        // we can query it.
        address l2LegacySharedBridge = _isGenesisUpgrade
            ? address(0)
            : address(L2AssetRouter(L2_ASSET_ROUTER_ADDR).L2_LEGACY_SHARED_BRIDGE());

        if (!(_isZKsyncOS && _isGenesisUpgrade)) {
            conductContractUpgrade(
                expectedUpgradeType,
                fixedForceDeploymentsData.l2AssetRouterBytecodeInfo,
                address(L2_ASSET_ROUTER_ADDR)
            );
        }
        if (_isGenesisUpgrade) {
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

    /// @dev Deploys and initializes token-related contracts: WETH, NativeTokenVault,
    /// ChainAssetHandler, AssetTracker, InteropCenter, and InteropHandler.
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

        address wrappedBaseTokenAddress = _ensureWethToken({
            _predeployedWethToken: predeployedL2WethAddress,
            _aliasedL1Governance: fixedForceDeploymentsData.aliasedL1Governance,
            _baseTokenL1Address: additionalForceDeploymentsData.baseTokenL1Address,
            _baseTokenAssetId: additionalForceDeploymentsData.baseTokenBridgingData.assetId,
            _baseTokenName: additionalForceDeploymentsData.baseTokenMetadata.name,
            _baseTokenSymbol: additionalForceDeploymentsData.baseTokenMetadata.symbol
        });
        if (!(_isZKsyncOS && _isGenesisUpgrade)) {
            conductContractUpgrade(
                expectedUpgradeType,
                fixedForceDeploymentsData.l2NtvBytecodeInfo,
                L2_NATIVE_TOKEN_VAULT_ADDR
            );
        }
        if (_isGenesisUpgrade) {
            address deployedTokenBeacon;
            // In production, the `fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon` must always
            // be equal to 0. It is only for simplifying testing.
            if (fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon == address(0)) {
                // The beacon is deployed via a separate contract to reduce the code size of this library.
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

        if (!(_isZKsyncOS && _isGenesisUpgrade)) {
            conductContractUpgrade(
                expectedUpgradeType,
                fixedForceDeploymentsData.chainAssetHandlerBytecodeInfo,
                address(L2_CHAIN_ASSET_HANDLER_ADDR)
            );
        }
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
                fixedForceDeploymentsData.aliasedL1Governance,
                fixedForceDeploymentsData.zkTokenAssetId
            );
        } else {
            InteropCenter(L2_INTEROP_CENTER_ADDR).updateL2(
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

    /// @dev Performs post-deployment finalization: wires up Bridgehub addresses, initializes
    /// AssetTracker / GWAssetTracker / InteropHandler, and registers the base token in the NTV.
    function _finalizeDeployments(
        address _ctmDeployer,
        FixedForceDeploymentsData memory fixedForceDeploymentsData,
        ZKChainSpecificForceDeploymentsData memory additionalForceDeploymentsData,
        bool _isZKsyncOS,
        bool _isGenesisUpgrade
    ) private {
        L2Bridgehub(L2_BRIDGEHUB_ADDR).setAddresses({
            _assetRouter: L2_ASSET_ROUTER_ADDR,
            _l1CtmDeployer: ICTMDeploymentTracker(_ctmDeployer),
            _messageRoot: IMessageRootBase(L2_MESSAGE_ROOT_ADDR),
            _chainAssetHandler: L2_CHAIN_ASSET_HANDLER_ADDR,
            _chainRegistrationSender: fixedForceDeploymentsData.aliasedChainRegistrationSender
        });

        L2AssetTracker(L2_ASSET_TRACKER_ADDR).initL2(
            fixedForceDeploymentsData.l1ChainId,
            additionalForceDeploymentsData.baseTokenBridgingData.assetId,
            // The only chains that need backfill for the base token's total supply are ZKsync OS
            // chains that existed before the v31 upgrade (i.e. isGenesis is false).
            _isZKsyncOS && !_isGenesisUpgrade
        );

        GWAssetTracker(GW_ASSET_TRACKER_ADDR).initL2(
            fixedForceDeploymentsData.l1ChainId,
            fixedForceDeploymentsData.aliasedL1Governance
        );

        InteropHandler(L2_INTEROP_HANDLER_ADDR).initL2(fixedForceDeploymentsData.l1ChainId);

        L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).registerBaseTokenIfNeeded();
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
