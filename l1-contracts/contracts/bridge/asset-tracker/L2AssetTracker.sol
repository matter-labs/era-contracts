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
import {
    AssetIdNotRegistered,
    BaseTokenNativeToThisChain,
    ChainBalanceMustBeZeroBeforeMigration,
    InsufficientChainBalance,
    MissingBaseTokenAssetId,
    RecoverToL1NotSupported,
    Unauthorized
} from "../../common/L1ContractErrors.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {IL2AssetTracker, SavedTotalSupply} from "./IL2AssetTracker.sol";
import {MAX_TOKEN_BALANCE} from "../../common/Config.sol";

/// @notice Chain-local, write-mostly token bookkeeping; correctness of transfers is guaranteed by ZK
/// proofs, not by these balances. See {protocol-docs/bridging.md#l2-asset-tracker}.
/// @dev Inherits Ownable2StepUpgradeable and PausableUpgradeable (unused on L2) purely to preserve the
/// storage layout of the already-deployed L2AssetTracker: they occupy slots 0-200 via the former shared
/// AssetTrackerBase, so the tracker state below must stay at slots 201+.
contract L2AssetTracker is IL2AssetTracker, Ownable2StepUpgradeable, PausableUpgradeable, ReentrancyGuard {
    /// @inheritdoc IL2AssetTracker
    /// @dev Tracked only for tokens native to this chain; expected to be 0 for all others.
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) public override chainBalance;

    /// @dev Slot previously holding `assetMigrationNumber` from the removed Token Balance Migration.
    /// Retained to preserve the deployed storage layout across the in-place upgrade.
    // slither-disable-next-line unused-state
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 migrationNumber))
        private __DEPRECATED_assetMigrationNumber;

    /// @inheritdoc IL2AssetTracker
    /// @dev May be removed once all legacy tokens are registered — don't rely on it.
    mapping(bytes32 assetId => bool isAssetRegistered) public override isAssetRegistered;

    uint256 public L1_CHAIN_ID;

    bytes32 public BASE_TOKEN_ASSET_ID;

    /// @dev L2-side accounting used to compute the amount to keep on L1 during L1 -> Gateway migration.
    mapping(bytes32 assetId => InteropL2Info info) public interopInfo;

    /// @notice Token total-supply snapshot captured before the token's first post-v31 bridge operation.
    /// See {protocol-docs/bridging.md#l2-asset-tracker}.
    mapping(bytes32 assetId => SavedTotalSupply snapshot) public totalPreV31TotalSupply;

    /// @dev Slot previously holding `needBaseTokenTotalSupplyBackfill`. The ZKsync OS base-token
    /// backfill it gated is complete on every chain that can take this upgrade, which is enforced on
    /// L1 (see {V33UpgradeZKsyncOS}), so this release has no backfill entry point left.
    // slither-disable-next-line unused-state
    bool private __DEPRECATED_needBaseTokenTotalSupplyBackfill;

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

    /// @inheritdoc IL2AssetTracker
    function initL2(uint256 _l1ChainId, bytes32 _baseTokenAssetId) external reentrancyGuardInitializer onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
        BASE_TOKEN_ASSET_ID = _baseTokenAssetId;
    }

    /// @inheritdoc IL2AssetTracker
    function registerNewTokenIfNeeded(bytes32 _assetId, uint256 _originChainId) public override onlyL2NativeTokenVault {
        if (isAssetRegistered[_assetId]) {
            return;
        }
        isAssetRegistered[_assetId] = true;

        if (_originChainId == block.chainid) {
            // By convention, native tokens are treated as if an infinite deposit happened at the chain's
            // inception (see MAX_TOKEN_BALANCE).
            chainBalance[_originChainId][_assetId] = MAX_TOKEN_BALANCE;
            totalPreV31TotalSupply[_assetId] = SavedTotalSupply({isSaved: true, amount: MAX_TOKEN_BALANCE});
        } else {
            // Chain balance is not tracked for non-native tokens. A token bridged in for the first time
            // has never been bridged before v31, so its pre-v31 supply is zero.
            totalPreV31TotalSupply[_assetId] = SavedTotalSupply({isSaved: true, amount: 0});
        }
    }

    /// @inheritdoc IL2AssetTracker
    function registerLegacyToken(bytes32 _assetId) public override {
        if (isAssetRegistered[_assetId]) {
            return;
        }

        // An unregistered token is either a legacy token or not present in the system at all;
        // `_tryGetTokenAddress` reverts in the latter case (not registered on the NTV).
        address tokenAddress = _tryGetTokenAddress(_assetId);
        _registerLegacyToken(_assetId, tokenAddress);
    }

    /*//////////////////////////////////////////////////////////////
                    Token deposits and withdrawals
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IL2AssetTracker
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
            // chainBalance is only tracked for native tokens.
            _decreaseChainBalance(block.chainid, _assetId, _amount);
        }

        if (
            _toChainId == L1_CHAIN_ID &&
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() == L1_CHAIN_ID
        ) {
            interopInfo[_assetId].totalWithdrawalsToL1 += _amount;
        }
    }

    /// @inheritdoc IL2AssetTracker
    function handleInitiateBaseTokenBridgingOnL2(uint256 _toChainId, uint256 _amount) external onlyBaseTokenHolder {
        bytes32 baseTokenAssetId = BASE_TOKEN_ASSET_ID;
        uint256 baseTokenOriginChainId = L2_NATIVE_TOKEN_VAULT.originChainId(baseTokenAssetId);
        _handleInitiateBridgingOnL2Inner(_toChainId, baseTokenAssetId, _amount, baseTokenOriginChainId);
    }

    /// @inheritdoc IL2AssetTracker
    function assertRecoveryIsAccountingNeutral(bytes32 _assetId, uint256 _toChainId) public view override {
        // L2->L1 withdrawals are never revertable: `totalWithdrawalsToL1` must stay append-only.
        // See {protocol-docs/bridging.md#l2-asset-tracker}.
        require(_toChainId != L1_CHAIN_ID, RecoverToL1NotSupported());
        // The base token never originates from this chain, so there is no chainBalance to re-credit;
        // for every other asset the re-credit happens through `handleFinalizeBridgingOnL2`.
        if (_assetId == BASE_TOKEN_ASSET_ID) {
            require(L2_NATIVE_TOKEN_VAULT.originChainId(_assetId) != block.chainid, BaseTokenNativeToThisChain());
        }
    }

    /// @inheritdoc IL2AssetTracker
    function assertBaseTokenRecoveryIsAccountingNeutral(uint256 _toChainId) external view {
        assertRecoveryIsAccountingNeutral(BASE_TOKEN_ASSET_ID, _toChainId);
    }

    /// @inheritdoc IL2AssetTracker
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

        // chainBalance is only tracked for native tokens.
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

    /// @notice Registers a legacy token, populating its `chainBalance` and `totalPreV31TotalSupply`.
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

            // chainBalance starts at MAX_TOKEN_BALANCE minus tokens already escrowed in the NTV. Tokens
            // sent directly to the NTV are treated the same as bridged-out ones — they are effectively
            // frozen anyway.
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
            return totalPreV31TotalSupply[_assetId].amount;
        }

        // The token must be legacy: the NTV calls `registerNewTokenIfNeeded` for any new token.
        return _registerLegacyToken(_assetId, _tokenAddress);
    }

    /// @inheritdoc IL2AssetTracker
    function handleFinalizeBaseTokenBridgingOnL2(
        uint256 _fromChainId,
        uint256 _amount
    ) external onlyBaseTokenHolderOrL2BaseToken {
        bytes32 baseTokenAssetId = BASE_TOKEN_ASSET_ID;
        if (_amount == 0) {
            return;
        }
        if (baseTokenAssetId == bytes32(0)) {
            // Before the genesis upgrade no value is transferred; revert rather than record under an
            // incorrect asset id.
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

    /// @dev Reverts with a descriptive error instead of underflowing, to ease debugging; there is no
    /// matching increase helper since overflow is not a realistic concern.
    function _decreaseChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal {
        if (chainBalance[_chainId][_assetId] < _amount) {
            revert InsufficientChainBalance(_chainId, _assetId, _amount);
        }
        chainBalance[_chainId][_assetId] -= _amount;
    }

    /// @notice Retrieves the token contract address for a given asset ID.
    /// @dev Reverts if the asset is not registered on the NTV.
    /// @param _assetId The asset ID to look up.
    /// @return tokenAddress The contract address of the token.
    function _tryGetTokenAddress(bytes32 _assetId) internal view returns (address tokenAddress) {
        tokenAddress = L2_NATIVE_TOKEN_VAULT.tokenAddress(_assetId);
        require(tokenAddress != address(0), AssetIdNotRegistered(_assetId));
    }
}
