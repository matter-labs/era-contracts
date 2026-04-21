// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {IMessageRootBase} from "../core/message-root/IMessageRoot.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "../bridge/ntv/INativeTokenVaultBase.sol";
import {IL1NativeTokenVault} from "../bridge/ntv/IL1NativeTokenVault.sol";
import {IL2V31Upgrade} from "./IL2V31Upgrade.sol";
import {UnexpectedUpgradeSelector, PriorityQueueNotReady, ZeroAddress} from "../common/L1ContractErrors.sol";
import {ZKChainSpecificForceDeploymentsData} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {TokenBridgingData, TokenMetadata} from "../common/Messaging.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {IL1MessageRoot} from "../core/message-root/IL1MessageRoot.sol";
import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {Bytes} from "../vendor/Bytes.sol";
import {ETH_TOKEN_ADDRESS, L2DACommitmentScheme} from "../common/Config.sol";
import {NotAllBatchesExecuted} from "../state-transition/L1StateTransitionErrors.sol";

/// @author Matter Labs
/// @title SettlementLayerV31UpgradeBase
/// @dev Base contract for v31 per-chain upgrades. Handles L1 state updates and
/// delegates L2 tx construction to subclasses (Era vs ZKsyncOS).
/// @custom:security-contact security@matterlabs.dev
abstract contract SettlementLayerV31UpgradeBase is BaseZkSyncUpgrade {
    using Bytes for bytes;

    error UnexpectedZKsyncOSFlag(bool expected, bool actual);

    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        IBridgehubBase bridgehub = IBridgehubBase(s.bridgehub);
        address assetRouter = address(bridgehub.assetRouter());
        address nativeTokenVaultAddr = address(IL1AssetRouter(assetRouter).nativeTokenVault());

        // Persist the freshly discovered NativeTokenVault address into diamond storage so that
        // subsequent facet calls (Mailbox, Executor, Migrator, etc.) see it without re-querying
        // the bridgehub. DiamondInit does the same on chain creation.
        s.nativeTokenVault = nativeTokenVaultAddr;

        // This call reverts with an unrecognised selector if NTV has not been upgraded to v31.
        // If NTV is upgraded but l1AssetTracker has not been set yet, it returns address(0),
        // so we assert non-zero to avoid silently leaving s.assetTracker zeroed.
        address assetTracker = address(IL1NativeTokenVault(s.nativeTokenVault).l1AssetTracker());
        require(assetTracker != address(0), ZeroAddress());
        s.assetTracker = assetTracker;
        s.__DEPRECATED_l2DAValidator = address(0);
        // Reset DA validators, mirroring what the v30 upgrade did. ZKsync OS chains already reset
        // these during their v30 upgrade, so we only need to do it for Era chains here.
        if (!s.zksyncOS) {
            s.l1DAValidator = address(0);
            s.l2DACommitmentScheme = L2DACommitmentScheme.NONE;
        }

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
        if (!s.zksyncOS) {
            s.baseTokenHasTotalSupply = true;
        }

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    /// @notice Construct the final L2 upgrade tx data. Implemented by subclasses.
    function getL2UpgradeTxData(
        address _bridgehub,
        uint256 _chainId,
        bytes memory _existingTxData
    ) public view virtual returns (bytes memory);

    /// @notice Replace the placeholder inner calldata with real per-chain data.
    /// @dev The inner calldata is IL2V31Upgrade.upgrade() — we decode the placeholder to
    /// extract ecosystem-wide fields, then re-encode with per-chain additionalForceDeploymentsData.
    function _buildL2V31UpgradeCalldata(
        address _bridgehub,
        uint256 _chainId,
        bytes memory _existingUpgradeCalldata
    ) internal view returns (bytes memory) {
        // Decode the placeholder to extract isZKsyncOS, ctmDeployer, and fixedForceDeploymentsData
        // (these are ecosystem-wide and don't change per chain).
        (bool isZKsyncOS, address ctmDeployer, bytes memory fixedForceDeploymentsData, ) = abi.decode(
            // ignore placeholder additionalForceDeploymentsData
            _existingUpgradeCalldata.slice(4),
            (bool, address, bytes, bytes)
        );
        if (isZKsyncOS != s.zksyncOS) {
            revert UnexpectedZKsyncOSFlag(s.zksyncOS, isZKsyncOS);
        }

        // Construct per-chain ZKChainSpecificForceDeploymentsData from L1 state.
        bytes memory additionalForceDeploymentsData = _buildChainSpecificForceDeploymentsData(_bridgehub, _chainId);

        return
            abi.encodeCall(
                IL2V31Upgrade.upgrade,
                (isZKsyncOS, ctmDeployer, fixedForceDeploymentsData, additionalForceDeploymentsData)
            );
    }

    /// @notice Build per-chain ZKChainSpecificForceDeploymentsData from L1 state.
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
            // Use `tokenAddress` (the local bridged representation on this settlement layer)
            // instead of `originToken` (which is the address on the origin chain and may have no
            // code here if the token was bridged from another chain).
            address localToken = nativeTokenVault.tokenAddress(baseTokenAssetId);
            baseTokenName = IERC20Metadata(localToken).name();
            baseTokenSymbol = IERC20Metadata(localToken).symbol();
            baseTokenDecimals = IERC20Metadata(localToken).decimals();
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

    /// @notice Validate that the inner calldata targets L2V31Upgrade.
    function _validateWrappedUpgrade(bytes memory _existingUpgradeCalldata) internal pure {
        if (bytes4(_existingUpgradeCalldata) != IL2V31Upgrade.upgrade.selector) {
            revert UnexpectedUpgradeSelector();
        }
    }
}
