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
    BaseTokenNativeToThisChain,
    MissingBaseTokenAssetId,
    RecoverToL1NotSupported,
    Unauthorized
} from "../../common/L1ContractErrors.sol";

import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {IL2AssetTracker, SavedTotalSupply} from "./IL2AssetTracker.sol";
import {MAX_TOKEN_BALANCE} from "../../common/Config.sol";

/// @notice Chain-local, write-only asset bookkeeping; correctness of transfers is guaranteed by ZK
/// proofs, not by these amounts. See {protocol-docs/bridging.md#l2-asset-bookkeeping}.
/// @dev Inherits Ownable2StepUpgradeable and PausableUpgradeable (unused on L2) purely to preserve the
/// storage layout of the already-deployed L2AssetTracker: they occupy slots 0-200 via the former shared
/// AssetTrackerBase, so the tracker state below must stay at slots 201+.
contract L2AssetTracker is IL2AssetTracker, Ownable2StepUpgradeable, PausableUpgradeable, ReentrancyGuard {
    /// @dev Slot previously holding `chainBalance`. The outstanding-amount accounting it carried moved
    /// to the vault that owns the escrow and can therefore enforce it
    /// (`NativeTokenVaultBase.bridgedOut`), so the tracker is write-only again: no bridging decision
    /// reads it. Retained to preserve the deployed storage layout.
    // slither-disable-next-line unused-state
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) private __DEPRECATED_chainBalance;

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

    /// @inheritdoc IL2AssetTracker
    /// @dev L2-side accounting used to compute the amount to keep on L1 during L1 -> Gateway migration.
    mapping(bytes32 assetId => InteropL2Info info) public override interopInfo;

    /// @inheritdoc IL2AssetTracker
    /// @dev Conventions: for a bridged token (the base token included) the snapshot is the token's
    /// `totalSupply()` at registration time. Tokens native to this chain use the infinite-deposit
    /// convention, offsetting the same net inbound flow by `MAX_TOKEN_BALANCE`: a token that was never
    /// bridged out starts at `MAX_TOKEN_BALANCE`, one already bridged out at
    /// `MAX_TOKEN_BALANCE - vault escrow`.
    mapping(bytes32 assetId => SavedTotalSupply snapshot) public override totalPreV31TotalSupply;

    /// @dev Slot previously holding `needBaseTokenTotalSupplyBackfill`. The ZKsync OS base-token
    /// backfill it gated is complete on every chain that can take this upgrade, which is enforced on
    /// L1 (see {V32UpgradeZKsyncOS}), so this release has no backfill entry point left.
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

    /*//////////////////////////////////////////////////////////////
                            Token registration
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IL2AssetTracker
    /// @dev A chain upgraded from v31 registered its base token there (and, on ZKsync OS, backfilled
    /// the snapshot), so this is a no-op for it; at genesis the supply is zero.
    function trackBaseToken() external onlyUpgrader {
        bytes32 baseTokenAssetId = BASE_TOKEN_ASSET_ID;
        if (isAssetRegistered[baseTokenAssetId]) {
            return;
        }

        // The base token never originates from this chain, so like any bridged token its pre-tracking
        // net inbound flow is exactly its current `totalSupply()`.
        _register(baseTokenAssetId, L2_BASE_TOKEN_SYSTEM_CONTRACT.totalSupply());
    }

    /// @inheritdoc IL2AssetTracker
    function registerNewTokenIfNeeded(bytes32 _assetId, uint256 _originChainId) external onlyL2NativeTokenVault {
        if (isAssetRegistered[_assetId]) {
            return;
        }

        // No flows predate the registration of a token the vault only learned about now: a bridged
        // token starts at a zero snapshot, a native one at the infinite-deposit convention.
        _register(_assetId, _originChainId == block.chainid ? MAX_TOKEN_BALANCE : 0);
    }

    /// @inheritdoc IL2AssetTracker
    function trackLegacyTokenIfNeeded(
        bytes32 _assetId,
        uint256 _originChainId,
        address _tokenAddress
    ) external onlyL2NativeTokenVault {
        if (isAssetRegistered[_assetId]) {
            return;
        }

        uint256 snapshot;
        if (_originChainId == block.chainid) {
            // Tokens already escrowed in the vault count as bridged out; tokens sent directly to it
            // are treated the same, since they are effectively frozen.
            snapshot = MAX_TOKEN_BALANCE - IERC20(_tokenAddress).balanceOf(L2_NATIVE_TOKEN_VAULT_ADDR);
        } else {
            snapshot = IERC20(_tokenAddress).totalSupply();
        }
        _register(_assetId, snapshot);
    }

    /*//////////////////////////////////////////////////////////////
                    Token deposits and withdrawals
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IL2AssetTracker
    function handleInitiateBridgingOnL2(
        uint256 _toChainId,
        bytes32 _assetId,
        uint256 _amount
    ) external onlyL2NativeTokenVault {
        _recordBridgingToChain(_assetId, _toChainId, _amount);
    }

    /// @inheritdoc IL2AssetTracker
    function handleFinalizeBridgingOnL2(
        uint256 _fromChainId,
        bytes32 _assetId,
        uint256 _amount
    ) external onlyL2NativeTokenVault {
        _recordBridgingFromChain(_assetId, _fromChainId, _amount);
    }

    /// @inheritdoc IL2AssetTracker
    function handleInitiateBaseTokenBridgingOnL2(uint256 _toChainId, uint256 _amount) external onlyBaseTokenHolder {
        _recordBridgingToChain(_baseTokenAssetIdForFlow(), _toChainId, _amount);
    }

    /// @inheritdoc IL2AssetTracker
    function handleFinalizeBaseTokenBridgingOnL2(
        uint256 _fromChainId,
        uint256 _amount
    ) external onlyBaseTokenHolderOrL2BaseToken {
        if (_amount == 0) {
            return;
        }
        _recordBridgingFromChain(_baseTokenAssetIdForFlow(), _fromChainId, _amount);
    }

    /// @inheritdoc IL2AssetTracker
    function assertRecoveryIsAccountingNeutral(bytes32 _assetId, uint256 _toChainId) public view override {
        // `totalWithdrawalsToL1` must stay append-only: L2 -> L1 withdrawals are never revertable, so a
        // recovery of an L1-destined transfer cannot legitimately exist.
        require(_toChainId != L1_CHAIN_ID, RecoverToL1NotSupported());
        // The base token never originates from the chain it lives on, so a recovery has no `bridgedOut`
        // escrow accounting to re-credit for it.
        if (_assetId == BASE_TOKEN_ASSET_ID) {
            require(L2_NATIVE_TOKEN_VAULT.originChainId(_assetId) != block.chainid, BaseTokenNativeToThisChain());
        }
    }

    /// @inheritdoc IL2AssetTracker
    function assertBaseTokenRecoveryIsAccountingNeutral(uint256 _toChainId) external view {
        assertRecoveryIsAccountingNeutral(BASE_TOKEN_ASSET_ID, _toChainId);
    }

    /*//////////////////////////////////////////////////////////////
                            Helper Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Marks the asset registered and stores its pre-tracking supply snapshot. Callers check that
    /// the asset is not registered yet, so a recorded snapshot is never overwritten.
    function _register(bytes32 _assetId, uint256 _snapshot) internal {
        isAssetRegistered[_assetId] = true;
        totalPreV31TotalSupply[_assetId] = SavedTotalSupply({isSaved: true, amount: _snapshot});
    }

    /// @dev Records an outbound flow when it targets L1 and this chain currently settles on L1.
    function _recordBridgingToChain(bytes32 _assetId, uint256 _toChainId, uint256 _amount) internal {
        if (
            _toChainId == L1_CHAIN_ID &&
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() == L1_CHAIN_ID
        ) {
            interopInfo[_assetId].totalWithdrawalsToL1 += _amount;
        }
    }

    /// @dev Records an inbound flow when it originates from L1 and this chain currently settles on L1.
    function _recordBridgingFromChain(bytes32 _assetId, uint256 _fromChainId, uint256 _amount) internal {
        if (
            _fromChainId == L1_CHAIN_ID &&
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() == L1_CHAIN_ID
        ) {
            interopInfo[_assetId].totalSuccessfulDepositsFromL1 += _amount;
        }
    }

    /// @dev Before the genesis upgrade no base-token value is transferred; revert rather than record a
    /// flow under an incorrect asset id.
    function _baseTokenAssetIdForFlow() internal view returns (bytes32 baseTokenAssetId) {
        baseTokenAssetId = BASE_TOKEN_ASSET_ID;
        require(baseTokenAssetId != bytes32(0), MissingBaseTokenAssetId());
    }
}
