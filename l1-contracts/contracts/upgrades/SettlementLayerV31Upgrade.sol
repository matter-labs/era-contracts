// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {L2_VERSION_SPECIFIC_UPGRADER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IMessageRootBase} from "../core/message-root/IMessageRoot.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "../bridge/ntv/INativeTokenVaultBase.sol";
import {IL1NativeTokenVault} from "../bridge/ntv/IL1NativeTokenVault.sol";
import {IL2V31Upgrade} from "./IL2V31Upgrade.sol";
import {ZKChainSpecificForceDeploymentsData} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {TokenBridgingData, TokenMetadata} from "../common/Messaging.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";
import {IComplexUpgraderZKsyncOSV29} from "../state-transition/l2-deps/IComplexUpgraderZKsyncOSV29.sol";
import {IL2ContractDeployer} from "../common/interfaces/IL2ContractDeployer.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {IL1MessageRoot} from "../core/message-root/IL1MessageRoot.sol";
import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {Bytes} from "../vendor/Bytes.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";

error PriorityQueueNotReady();
error V31UpgradeGatewayBlockNumberNotSet();
error NotAllBatchesExecuted();
error UnsupportedL2UpgradeSelector(bytes4 selector);
error UnexpectedUpgradeTarget(address target);

event L2V31UpgradeCalldataConstructed(address indexed bridgehub, uint256 indexed chainId, bytes data);
event L2UpgradeTxDataConstructed(address indexed bridgehub, uint256 indexed chainId, bytes data);

/// @author Matter Labs
/// @title This contract will only be used on L1, since for V31 there will be no active GW, due the deprecation of EraGW, and the ZKSync OS GW launch will only happen after V31.
/// @custom:security-contact security@matterlabs.dev
contract SettlementLayerV31Upgrade is BaseZkSyncUpgrade {
    using Bytes for bytes;

    /// @dev The address of the Bridgehub proxy on L1.
    IBridgehubBase public immutable BRIDGEHUB;

    constructor(IBridgehubBase _bridgehub) {
        BRIDGEHUB = _bridgehub;
    }

    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        IBridgehubBase bridgehub = BRIDGEHUB;
        address assetRouter = address(bridgehub.assetRouter());
        address nativeTokenVaultAddr = address(IL1AssetRouter(assetRouter).nativeTokenVault());

        /// We write to storage to avoid reentrancy.
        s.nativeTokenVault = nativeTokenVaultAddr;

        // Note that this call will revert if the native token vault has not been upgraded, i.e.
        // if a chain settling on Gateway tries to upgrade before ZK Gateway has done the upgrade.
        s.assetTracker = address(IL1NativeTokenVault(s.nativeTokenVault).l1AssetTracker());
        s.__DEPRECATED_l2DAValidator = address(0);

        // Set the permissionless validator used in Priority Mode, same as done in DiamondInit.
        s.priorityModeInfo.permissionlessValidator = IChainTypeManager(s.chainTypeManager).PERMISSIONLESS_VALIDATOR();

        require(s.totalBatchesCommitted == s.totalBatchesExecuted, NotAllBatchesExecuted());

        ProposedUpgrade memory proposedUpgrade = _proposedUpgrade;
        proposedUpgrade.l2ProtocolUpgradeTx.data = getL2UpgradeTxData(
            address(bridgehub),
            s.chainId,
            proposedUpgrade.l2ProtocolUpgradeTx.data
        );

        super.upgrade(proposedUpgrade);
        IMessageRootBase messageRoot = IMessageRootBase(bridgehub.messageRoot());

        if (s.settlementLayer == address(0)) {
            // slither-disable-next-line reentrancy-no-eth
            IL1MessageRoot(address(messageRoot)).saveV31UpgradeChainBatchNumber(s.chainId);
        }

        if (bridgehub.whitelistedSettlementLayers(s.chainId)) {
            require(IGetters(address(this)).getPriorityQueueSize() == 0, PriorityQueueNotReady());
        }

        // Era chains automatically have it tracked.
        // ZKsync OS chains haven't been tracking this value until the v31 upgrade.
        // It will have to be backfilled.
        // FIXME The actual logic for backfilling will be introduced in a separate PR.
        if (!s.zksyncOS) {
            s.baseTokenHasTotalSupply = true;
        }

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    function getL2V31UpgradeCalldata(
        address _bridgehub,
        uint256 _chainId,
        bytes memory _existingUpgradeCalldata
    ) public view returns (bytes memory) {
        // Decode the placeholder to extract isZKsyncOS, ctmDeployer, and fixedForceDeploymentsData
        // (these are ecosystem-wide and don't change per chain).
        (
            bool isZKsyncOS,
            address ctmDeployer,
            bytes memory fixedForceDeploymentsData,

        ) = // ignore placeholder additionalForceDeploymentsData
            abi.decode(_existingUpgradeCalldata.slice(4), (bool, address, bytes, bytes));

        // Construct per-chain ZKChainSpecificForceDeploymentsData from L1 state.
        bytes memory additionalForceDeploymentsData = _buildChainSpecificForceDeploymentsData(_bridgehub, _chainId);

        return
            abi.encodeCall(
                IL2V31Upgrade.upgrade,
                (isZKsyncOS, ctmDeployer, fixedForceDeploymentsData, additionalForceDeploymentsData)
            );
    }

    function _buildChainSpecificForceDeploymentsData(
        address _bridgehub,
        uint256 _chainId
    ) internal view returns (bytes memory) {
        IBridgehubBase bridgehub = IBridgehubBase(_bridgehub);
        address assetRouter = address(bridgehub.assetRouter());
        address nativeTokenVaultAddr = address(IL1AssetRouter(assetRouter).nativeTokenVault());
        bytes32 baseTokenAssetId = bridgehub.baseTokenAssetId(_chainId);
        INativeTokenVaultBase nativeTokenVault = INativeTokenVaultBase(nativeTokenVaultAddr);
        address originToken = nativeTokenVault.originToken(baseTokenAssetId);

        string memory baseTokenName;
        string memory baseTokenSymbol;
        uint256 baseTokenDecimals;

        if (originToken == ETH_TOKEN_ADDRESS) {
            baseTokenName = "Ether";
            baseTokenSymbol = "ETH";
            baseTokenDecimals = 18;
        } else {
            baseTokenName = IERC20Metadata(originToken).name();
            baseTokenSymbol = IERC20Metadata(originToken).symbol();
            baseTokenDecimals = IERC20Metadata(originToken).decimals();
        }

        return
            abi.encode(
                ZKChainSpecificForceDeploymentsData({
                    l2LegacySharedBridge: address(0),
                    predeployedL2WethAddress: address(0),
                    baseTokenL1Address: originToken,
                    baseTokenMetadata: TokenMetadata({
                        name: baseTokenName,
                        symbol: baseTokenSymbol,
                        decimals: baseTokenDecimals
                    }),
                    baseTokenBridgingData: TokenBridgingData({
                        assetId: baseTokenAssetId,
                        originChainId: nativeTokenVault.originChainId(baseTokenAssetId),
                        originToken: originToken
                    })
                })
            );
    }

    function getL2UpgradeTxData(
        address _bridgehub,
        uint256 _chainId,
        bytes memory _existingTxData
    ) public view returns (bytes memory) {
        bytes4 selector = bytes4(_existingTxData);

        if (selector == IComplexUpgrader.forceDeployAndUpgrade.selector) {
            (
                IL2ContractDeployer.ForceDeployment[] memory forceDeployments,
                address delegateTo,
                bytes memory existingUpgradeCalldata
            ) = abi.decode(_existingTxData.slice(4), (IL2ContractDeployer.ForceDeployment[], address, bytes));

            _validateWrappedUpgrade(delegateTo, existingUpgradeCalldata);
            bytes memory l2V31UpgradeCalldata = getL2V31UpgradeCalldata(_bridgehub, _chainId, existingUpgradeCalldata);

            return
                abi.encodeCall(
                    IComplexUpgrader.forceDeployAndUpgrade,
                    (forceDeployments, delegateTo, l2V31UpgradeCalldata)
                );
        }

        if (selector == IComplexUpgrader.forceDeployAndUpgradeUniversal.selector) {
            (
                IComplexUpgrader.UniversalContractUpgradeInfo[] memory forceDeployments,
                address delegateTo,
                bytes memory existingUpgradeCalldata
            ) = abi.decode(_existingTxData.slice(4), (IComplexUpgrader.UniversalContractUpgradeInfo[], address, bytes));

            _validateWrappedUpgrade(delegateTo, existingUpgradeCalldata);
            bytes memory l2V31UpgradeCalldata = getL2V31UpgradeCalldata(_bridgehub, _chainId, existingUpgradeCalldata);

            return
                abi.encodeCall(
                    IComplexUpgrader.forceDeployAndUpgradeUniversal,
                    (forceDeployments, delegateTo, l2V31UpgradeCalldata)
                );
        }

        if (selector == IComplexUpgraderZKsyncOSV29.forceDeployAndUpgradeUniversal.selector) {
            (
                IComplexUpgraderZKsyncOSV29.UniversalForceDeploymentInfo[] memory forceDeployments,
                address delegateTo,
                bytes memory existingUpgradeCalldata
            ) = abi.decode(
                    _existingTxData.slice(4),
                    (IComplexUpgraderZKsyncOSV29.UniversalForceDeploymentInfo[], address, bytes)
                );

            _validateWrappedUpgrade(delegateTo, existingUpgradeCalldata);
            bytes memory l2V31UpgradeCalldata = getL2V31UpgradeCalldata(_bridgehub, _chainId, existingUpgradeCalldata);

            return
                abi.encodeCall(
                    IComplexUpgraderZKsyncOSV29.forceDeployAndUpgradeUniversal,
                    (forceDeployments, delegateTo, l2V31UpgradeCalldata)
                );
        }

        if (selector == IComplexUpgrader.upgrade.selector) {
            (address delegateTo, bytes memory existingUpgradeCalldata) = abi.decode(
                _existingTxData.slice(4),
                (address, bytes)
            );

            _validateWrappedUpgrade(delegateTo, existingUpgradeCalldata);
            bytes memory l2V31UpgradeCalldata = getL2V31UpgradeCalldata(_bridgehub, _chainId, existingUpgradeCalldata);

            return abi.encodeCall(IComplexUpgrader.upgrade, (delegateTo, l2V31UpgradeCalldata));
        }

        revert UnsupportedL2UpgradeSelector(selector);
    }

    function emitL2V31UpgradeCalldata(
        address _bridgehub,
        uint256 _chainId,
        bytes calldata _existingUpgradeCalldata
    ) external returns (bytes memory data) {
        data = getL2V31UpgradeCalldata(_bridgehub, _chainId, _existingUpgradeCalldata);
        emit L2V31UpgradeCalldataConstructed(_bridgehub, _chainId, data);
    }

    function emitL2UpgradeTxData(
        address _bridgehub,
        uint256 _chainId,
        bytes calldata _existingTxData
    ) external returns (bytes memory data) {
        data = getL2UpgradeTxData(_bridgehub, _chainId, _existingTxData);
        emit L2UpgradeTxDataConstructed(_bridgehub, _chainId, data);
    }

    function _validateWrappedUpgrade(address _delegateTo, bytes memory _existingUpgradeCalldata) internal pure {
        if (bytes4(_existingUpgradeCalldata) != IL2V31Upgrade.upgrade.selector) {
            revert UnsupportedL2UpgradeSelector(bytes4(_existingUpgradeCalldata));
        }
        if (_delegateTo != L2_VERSION_SPECIFIC_UPGRADER_ADDR) {
            revert UnexpectedUpgradeTarget(_delegateTo);
        }
    }
}
