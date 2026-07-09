// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_NATIVE_TOKEN_VAULT,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT
} from "../../common/l2-helpers/L2ContractInterfaces.sol";
import {Unauthorized} from "../../common/L1ContractErrors.sol";

import {
    AssetAlreadyRegistered,
    AssetIdNotRegistered,
    BaseTokenTotalSupplyBackfillNotNeeded,
    ChainBalanceMustBeZeroBeforeMigration,
    InsufficientChainBalance,
    MissingBaseTokenAssetId,
    TotalPreV31SupplyNotSaved,
    TotalPreV31SupplyShouldBeZero
} from "./AssetTrackerErrors.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {IL2AssetTracker, SavedTotalSupply, MAX_TOKEN_BALANCE} from "./IL2AssetTracker.sol";

/// @dev Inherits Ownable2StepUpgradeable and PausableUpgradeable to preserve the storage layout of the
/// already-deployed L2AssetTracker (they occupy slots 0-200 via the former shared AssetTrackerBase, so the
/// tracker state below must stay at slots 201+). The owner/pause features are unused on L2 — access control
/// is enforced by the address-based modifiers below — but the slots are retained for upgrade compatibility.
contract L2AssetTracker is IL2AssetTracker, Ownable2StepUpgradeable, PausableUpgradeable, ReentrancyGuard {
    /// @notice Maps token balances for each chain.
    /// NOTE: this mapping may be removed in the future, don't rely on it!
    /// @dev This is write-only bookkeeping kept for future use; it is not consulted by any
    /// bridging decision. Correctness of transfers is guaranteed by ZK proofs (plus 2FA on
    /// ZKsync OS chains) rather than by on-chain balance enforcement.
    /// @dev The `chainBalance` is only used to track the balance of native tokens on the L2.
    /// For all the other tokens it is expected to be 0.
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) public override chainBalance;

    /// @dev Slot previously holding `assetMigrationNumber` from the removed Token Balance Migration.
    /// Retained to preserve the deployed storage layout across the in-place upgrade.
    // slither-disable-next-line unused-state
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 migrationNumber))
        private __DEPRECATED_assetMigrationNumber;

    /// @notice Denotes whether a token is registered or not: the token's chainBalance is set
    /// correctly and its `totalPreV31TotalSupply` is tracked correctly.
    /// @dev Once we know that all legacy tokens have been registered (and all new ones have the
    /// corresponding logic performed automatically), we can remove the mapping. So DONT RELY ON IT!
    mapping(bytes32 assetId => bool isAssetRegistered) public override isAssetRegistered;

    uint256 public L1_CHAIN_ID;

    bytes32 public BASE_TOKEN_ASSET_ID;

    /// @dev L2-side accounting used to compute the amount to keep on L1 during L1 -> Gateway migration.
    mapping(bytes32 assetId => InteropL2Info info) public interopInfo;

    /// @dev Token total supply snapshot captured before the first post-v31 bridge operation for each token.
    /// @dev For tokens that existed before the chain migrated to v31, it should be equal to `totalSuccessfulDeposits - totalWithdrawalsToL1`.
    /// - If a token is a bridged token, it is equal to its `totalSupply()`.
    /// - If a token is a native token, it is equal to the `2^256-1 - balanceOf of the native token vault`, i.e. one
    /// could imagine there was a big successful deposit at the inception time of 2^256-1 and then the withdrawals behaved the same way as for
    /// the bridged L2 tokens.
    /// @dev For native tokens, it is expected to be populated automatically with `isAssetRegistered[block.chainid]`.
    /// @dev IMPORTANT: for base token this value may not be correct for ZKsync OS chains until the totalSupply for the base
    /// token has been backfilled, so before using this value for the base token, one should check that it was set (`needBaseTokenTotalSupplyBackfill = false`).
    mapping(bytes32 assetId => SavedTotalSupply snapshot) public totalPreV31TotalSupply;

    /// @dev On ZKsync OS chains, the `totalSupply()` of the base token is not available by default,
    /// so before we ever use it to do any migrations, we need to backfill it.
    /// @dev This variable is expected to be deleted after v31 upgrade, once all the ZKsync OS chains have their base token
    /// amount backfilled.
    bool public needBaseTokenTotalSupplyBackfill;

    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyL2NativeTokenVault() {
        if (msg.sender != L2_NATIVE_TOKEN_VAULT_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyBaseTokenHolder() {
        if (msg.sender != L2_BASE_TOKEN_HOLDER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyBaseTokenHolderOrL2BaseToken() {
        if (msg.sender != L2_BASE_TOKEN_HOLDER_ADDR && msg.sender != address(L2_BASE_TOKEN_SYSTEM_CONTRACT)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyL2BaseToken() {
        if (msg.sender != address(L2_BASE_TOKEN_SYSTEM_CONTRACT)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Backfills the base token's pre-V31 total supply for ZKOS chains.
    /// @dev Called by L2BaseTokenZKOS.setZKsyncOSPreV31TotalSupply() after setting the total supply.
    /// @param _amount The pre-V31 total supply amount.
    function backFillZKSyncOSBaseTokenV31MigrationData(uint256 _amount) external onlyL2BaseToken {
        if (!needBaseTokenTotalSupplyBackfill) {
            revert BaseTokenTotalSupplyBackfillNotNeeded();
        }

        // For genesis chains, the base token is registered during _finalizeDeployments() via
        // L2NativeTokenVault.registerBaseTokenIfNeeded() → registerNewTokenIfNeeded(),
        // which sets totalPreV31TotalSupply[assetId] = {isSaved: true, amount: 0}.
        // For existing chains upgraded to V31, L2V31Upgrade calls registerBaseTokenDuringUpgrade()
        // which also sets totalPreV31TotalSupply to {isSaved: true, amount: 0}.
        require(isAssetRegistered[BASE_TOKEN_ASSET_ID], AssetIdNotRegistered(BASE_TOKEN_ASSET_ID));
        SavedTotalSupply memory baseTokenPreV31TotalSupply = totalPreV31TotalSupply[BASE_TOKEN_ASSET_ID];
        require(baseTokenPreV31TotalSupply.isSaved, TotalPreV31SupplyNotSaved(BASE_TOKEN_ASSET_ID));
        require(
            baseTokenPreV31TotalSupply.amount == 0,
            TotalPreV31SupplyShouldBeZero(BASE_TOKEN_ASSET_ID, baseTokenPreV31TotalSupply.amount)
        );
        totalPreV31TotalSupply[BASE_TOKEN_ASSET_ID].amount = _amount;

        needBaseTokenTotalSupplyBackfill = false;
    }

    /// @notice Sets the L1 chain ID and base token asset ID for this L2 chain.
    /// @dev This function is called during contract initialization or upgrades.
    /// @param _l1ChainId The chain ID of the L1 network.
    /// @param _baseTokenAssetId The asset ID of the base token used for gas fees on this chain.
    function initL2(
        uint256 _l1ChainId,
        bytes32 _baseTokenAssetId,
        bool _needBaseTokenTotalSupplyBackfill
    ) external reentrancyGuardInitializer onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
        BASE_TOKEN_ASSET_ID = _baseTokenAssetId;
        needBaseTokenTotalSupplyBackfill = _needBaseTokenTotalSupplyBackfill;
    }

    /// @inheritdoc IL2AssetTracker
    function registerNewTokenIfNeeded(bytes32 _assetId, uint256 _originChainId) public override onlyL2NativeTokenVault {
        if (isAssetRegistered[_assetId]) {
            return;
        }
        isAssetRegistered[_assetId] = true;

        if (_originChainId == block.chainid) {
            chainBalance[_originChainId][_assetId] = MAX_TOKEN_BALANCE;
            // By convention, we treat native tokens as those that had an infinite deposit
            // at the inception of the chain, so we set the `totalPreV31TotalSupply` to MAX_TOKEN_BALANCE to reflect that.
            totalPreV31TotalSupply[_assetId] = SavedTotalSupply({isSaved: true, amount: MAX_TOKEN_BALANCE});
        } else {
            // We dont track chain balance for non-native tokens.

            // If a token is not a native token and is bridged for the first time,
            // we know that it has never been bridged before v31.
            totalPreV31TotalSupply[_assetId] = SavedTotalSupply({isSaved: true, amount: 0});
        }
    }

    /// @notice Registers the base token in the asset tracker during a V31 upgrade
    /// of an existing chain.
    /// @dev Unlike `registerNewTokenIfNeeded` (used during genesis when all tokens
    /// are truly new), this function is for upgrading existing chains where the base
    /// token already exists on-chain but the asset tracker is deployed during the
    /// current upgrade. The base token originates on L1 (non-native to this chain).
    /// Reverts if the base token is already registered, since this is called first
    /// during the upgrade and double-registration indicates a broken invariant.
    /// The real pre-V31 total supply is backfilled later via
    /// `backFillZKSyncOSBaseTokenV31MigrationData()`.
    function registerBaseTokenDuringUpgrade() external onlyUpgrader {
        bytes32 baseTokenAssetId = BASE_TOKEN_ASSET_ID;
        require(!isAssetRegistered[baseTokenAssetId], AssetAlreadyRegistered(baseTokenAssetId));
        isAssetRegistered[baseTokenAssetId] = true;
        totalPreV31TotalSupply[baseTokenAssetId] = SavedTotalSupply({isSaved: true, amount: 0});

        emit BaseTokenRegisteredDuringUpgrade(baseTokenAssetId);
    }

    /// @notice Stores token total supply snapshot used for pre-v31 migration accounting.
    /// @dev Anyone can call this to eagerly initialize the snapshot before the first bridge operation.
    function registerLegacyToken(bytes32 _assetId) public override {
        if (isAssetRegistered[_assetId]) {
            return;
        }

        // Token is not registered, two cases:
        // - It is not present in the system at all
        // - It is a legacy token.
        // We distinguish these cases by checking the origin chain id in the NTV.
        // `_tryGetTokenAddress` is expected to revert if the token is not registered on NTV.
        address tokenAddress = _tryGetTokenAddress(_assetId);
        _registerLegacyToken(_assetId, tokenAddress);
    }

    /*//////////////////////////////////////////////////////////////
                    Token deposits and withdrawals
    //////////////////////////////////////////////////////////////*/

    /// @notice This function is called for outgoing bridging from the L2, i.e. L2->L1 withdrawals and outgoing L2->L2 interop.
    /// @param _toChainId The destination chain id of the transfer.
    /// @param _assetId The bridged asset id.
    /// @param _amount The transferred amount.
    /// @param _tokenOriginChainId Origin chain id of the bridged token.
    function handleInitiateBridgingOnL2(
        uint256 _toChainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId
    ) external onlyL2NativeTokenVault {
        _handleInitiateBridgingOnL2Inner(_toChainId, _assetId, _amount, _tokenOriginChainId);
    }

    function _handleInitiateBridgingOnL2Inner(
        uint256 _toChainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId
    ) internal {
        address tokenAddress = _tryGetTokenAddress(_assetId);
        _registerLegacyTokenIfNeeded(_assetId, tokenAddress);

        if (_tokenOriginChainId == block.chainid) {
            /// On the L2 we only save chainBalance for native tokens.
            _decreaseChainBalance(block.chainid, _assetId, _amount);
        }

        if (
            _toChainId == L1_CHAIN_ID &&
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() == L1_CHAIN_ID
        ) {
            interopInfo[_assetId].totalWithdrawalsToL1 += _amount;
        }
    }

    /// @notice Handles the initiation of base token bridging operations on L2.
    /// @dev This function is specifically for the chain's native base token used for gas payments.
    /// @param _toChainId The chain ID which the funds are sent to.
    /// @param _amount The amount of base tokens being bridged out.
    function handleInitiateBaseTokenBridgingOnL2(uint256 _toChainId, uint256 _amount) external onlyBaseTokenHolder {
        bytes32 baseTokenAssetId = BASE_TOKEN_ASSET_ID;
        uint256 baseTokenOriginChainId = L2_NATIVE_TOKEN_VAULT.originChainId(baseTokenAssetId);
        _handleInitiateBridgingOnL2Inner(_toChainId, baseTokenAssetId, _amount, baseTokenOriginChainId);
    }

    /// @notice Reverses the accounting of a previous {handleInitiateBaseTokenBridgingOnL2}, used when an
    /// atomic-interop value leg times out and its base-token value is refunded on the source chain.
    /// @dev The exact arithmetic inverse of {_handleInitiateBridgingOnL2Inner} for the base token: it
    /// re-credits `chainBalance` iff the base token is native to this chain, and un-counts the pending
    /// withdrawal iff the value was bridged towards L1 under L1 settlement. The token is already
    /// registered (it was registered at initiate time), so no legacy-token registration is needed.
    /// @param _toChainId The chain ID the funds were originally sent to.
    /// @param _amount The amount of base tokens being refunded.
    function handleRevertInitiateBaseTokenBridgingOnL2(
        uint256 _toChainId,
        uint256 _amount
    ) external onlyBaseTokenHolder {
        bytes32 baseTokenAssetId = BASE_TOKEN_ASSET_ID;
        uint256 baseTokenOriginChainId = L2_NATIVE_TOKEN_VAULT.originChainId(baseTokenAssetId);

        if (baseTokenOriginChainId == block.chainid) {
            /// On the L2 we only save chainBalance for native tokens. Inverse of `_decreaseChainBalance`.
            chainBalance[block.chainid][baseTokenAssetId] += _amount;
        }

        if (
            _toChainId == L1_CHAIN_ID &&
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() == L1_CHAIN_ID
        ) {
            interopInfo[baseTokenAssetId].totalWithdrawalsToL1 -= _amount;
        }
    }

    /// @notice Handles the finalization of incoming token bridging operations on L2.
    /// @dev This function is called when tokens are bridged into this L2 from another chain.
    /// @param _fromChainId The source chain id of the transfer.
    /// @param _assetId The asset ID of the token being bridged in.
    /// @param _amount The amount of tokens being bridged in.
    /// @param _tokenOriginChainId The chain ID where this token was originally created.
    /// @param _tokenAddress The contract address of the token on this chain.
    function handleFinalizeBridgingOnL2(
        uint256 _fromChainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId,
        address _tokenAddress
    ) external onlyL2NativeTokenVault {
        _handleFinalizeBridgingOnL2Inner({
            _fromChainId: _fromChainId,
            _assetId: _assetId,
            _amount: _amount,
            _isNativeToThisChain: _tokenOriginChainId == block.chainid,
            _tokenAddress: _tokenAddress
        });
    }

    function _handleFinalizeBridgingOnL2Inner(
        uint256 _fromChainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isNativeToThisChain,
        address _tokenAddress
    ) internal {
        _registerLegacyTokenIfNeeded(_assetId, _tokenAddress);

        /// On the L2 we only save chainBalance for native tokens.
        if (_isNativeToThisChain) {
            chainBalance[block.chainid][_assetId] += _amount;
        }

        if (
            _fromChainId == L1_CHAIN_ID &&
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() == L1_CHAIN_ID
        ) {
            interopInfo[_assetId].totalSuccessfulDepositsFromL1 += _amount;
        }
    }

    /// @notice Populates the totalPreV31TotalSupply.
    /// @dev Assumes that the token is not yet registered.
    function _registerLegacyToken(bytes32 _assetId, address _tokenAddress) internal returns (uint256 totalSupply) {
        // Legacy tokens are all expected to have the origin chain id set on the L2NativeTokenVault.
        uint256 originChainId = L2_NATIVE_TOKEN_VAULT.originChainId(_assetId);
        require(originChainId != 0, AssetIdNotRegistered(_assetId));
        if (originChainId == block.chainid) {
            // Invariant check: the chain balance of the origin chain should be 0 until the balance migration
            // from NTV is complete.
            uint256 originChainBalance = chainBalance[originChainId][_assetId];
            require(
                originChainBalance == 0,
                ChainBalanceMustBeZeroBeforeMigration(originChainId, _assetId, originChainBalance)
            );

            // Initialize chainBalance
            // For origin chains, chainBalance starts at MAX_TOKEN_BALANCE and decreases as tokens are bridged out.
            // We need to account for tokens currently locked in the NTV from previous bridge operations.
            // Note, that this logic treats "tokens sent directly to L2NTV" and tokens bridged to L1 through NTV the same
            // way. It is okay, since the tokens that have been sent to the L2NTV are basically frozen anyway.
            uint256 ntvBalance = IERC20(_tokenAddress).balanceOf(L2_NATIVE_TOKEN_VAULT_ADDR);
            uint256 chainTotalSupply = MAX_TOKEN_BALANCE - ntvBalance;
            chainBalance[originChainId][_assetId] = chainTotalSupply;
            totalSupply = chainTotalSupply;
            totalPreV31TotalSupply[_assetId] = SavedTotalSupply({isSaved: true, amount: totalSupply});
        } else {
            // Save pre-v31 supply for bridged legacy tokens.
            // Note, that here we assume that `totalSupply()` won't be affected in any way
            // until it is used here, i.e. all deposits or withdrawals should firstly record the previous totalSupply.
            totalSupply = IERC20(_tokenAddress).totalSupply();
            totalPreV31TotalSupply[_assetId] = SavedTotalSupply({isSaved: true, amount: totalSupply});
        }
        isAssetRegistered[_assetId] = true;
    }

    function _registerLegacyTokenIfNeeded(
        bytes32 _assetId,
        address _tokenAddress
    ) internal returns (uint256 totalSupply) {
        if (isAssetRegistered[_assetId]) {
            // If the token is already registered, then the totalPreV31TotalSupply should be already populated, so we can just return it.
            return totalPreV31TotalSupply[_assetId].amount;
        }

        // Note we assume that the token must be legacy, since we expect the NTV to call `registerNewToken` for any new tokens.
        return _registerLegacyToken(_assetId, _tokenAddress);
    }

    /// @notice Handles the finalization of incoming base token bridging operations on L2.
    /// @dev This function is specifically for the chain's native base token used for gas payments.
    /// @param _fromChainId The source chain ID of the bridging operation.
    /// @param _amount The amount of base tokens being bridged into this chain.
    function handleFinalizeBaseTokenBridgingOnL2(
        uint256 _fromChainId,
        uint256 _amount
    ) external onlyBaseTokenHolderOrL2BaseToken {
        bytes32 baseTokenAssetId = BASE_TOKEN_ASSET_ID;
        if (_amount == 0) {
            return;
        }
        if (baseTokenAssetId == bytes32(0)) {
            /// this means we are before the genesis upgrade, where we don't transfer value, so we can skip.
            /// if we don't skip we use incorrect asset id.
            revert MissingBaseTokenAssetId();
        }

        _handleFinalizeBridgingOnL2Inner({
            _fromChainId: _fromChainId,
            _assetId: baseTokenAssetId,
            _amount: _amount,
            _isNativeToThisChain: false,
            _tokenAddress: address(L2_BASE_TOKEN_SYSTEM_CONTRACT)
        });
    }

    /*//////////////////////////////////////////////////////////////
                            Helper Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev This function is used to decrease the chain balance of a token on a chain.
    /// @dev It makes debugging issues easier. Overflows don't usually happen, so there is no similar function to increase the chain balance.
    function _decreaseChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal {
        if (chainBalance[_chainId][_assetId] < _amount) {
            revert InsufficientChainBalance(_chainId, _assetId, _amount);
        }
        chainBalance[_chainId][_assetId] -= _amount;
    }

    /// @notice Retrieves the token contract address for a given asset ID.
    /// @param _assetId The asset ID to look up.
    /// @return tokenAddress The contract address of the token.
    function _tryGetTokenAddress(bytes32 _assetId) internal view returns (address tokenAddress) {
        tokenAddress = L2_NATIVE_TOKEN_VAULT.tokenAddress(_assetId);
        require(tokenAddress != address(0), AssetIdNotRegistered(_assetId));
    }
}
