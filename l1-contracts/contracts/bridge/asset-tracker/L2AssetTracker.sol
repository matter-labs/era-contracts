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
import {IL2AssetTracker} from "./IL2AssetTracker.sol";
import {L2AssetBookkeepingInfo} from "../../common/L2AssetBookkeeping.sol";
import {MAX_TOKEN_BALANCE} from "../../common/Config.sol";

/// @notice Chain-local, write-mostly asset bookkeeping; correctness of transfers is guaranteed by ZK
/// proofs, not by these amounts. See {protocol-docs/bridging.md#l2-asset-bookkeeping}.
/// @dev Inherits Ownable2StepUpgradeable and PausableUpgradeable (unused on L2) purely to preserve the
/// storage layout of the already-deployed L2AssetTracker: they occupy slots 0-200 via the former shared
/// AssetTrackerBase, so the tracker state below must stay at slots 201+.
contract L2AssetTracker is IL2AssetTracker, Ownable2StepUpgradeable, PausableUpgradeable, ReentrancyGuard {
    /// @dev Slots 201-203, holding the v31 tracker's `chainBalance`, the `assetMigrationNumber` of the
    /// even earlier Token Balance Migration, and `isAssetRegistered`. The escrow-integrity accounting
    /// `chainBalance` served now lives in the vault that owns the escrow
    /// (`NativeTokenVaultBase.bridgedOut`), and `assetBookkeeping` below replaces the rest, seeded from
    /// scratch — so the values left here are abandoned rather than migrated.
    // slither-disable-next-line unused-state
    uint256[3] private __DEPRECATED_v31TokenAccounting;

    /// @inheritdoc IL2AssetTracker
    uint256 public L1_CHAIN_ID;

    /// @inheritdoc IL2AssetTracker
    bytes32 public BASE_TOKEN_ASSET_ID;

    /// @dev Slots 206-208, holding the v31 tracker's `interopInfo`, `totalPreV31TotalSupply` and
    /// `needBaseTokenTotalSupplyBackfill`. The first two are superseded by `assetBookkeeping`, which
    /// merges them; the ZKsync OS base-token backfill they gated is complete on every chain that can
    /// take this upgrade (see {V32UpgradeZKsyncOS}), so its flag is gone.
    // slither-disable-next-line unused-state
    uint256[3] private __DEPRECATED_v31Bookkeeping;

    /// @notice Chain-local bookkeeping of each asset's L1 <-> L2 flows; see {L2AssetBookkeepingInfo}.
    /// @dev `preTrackingTotalSupply` conventions: for a bridged token (the base token included) it is
    /// the token's pre-tracking `totalSupply()`. Tokens native to this chain instead use the
    /// infinite-deposit convention, offsetting the same net inbound flow by `MAX_TOKEN_BALANCE`:
    /// `MAX_TOKEN_BALANCE - bridgedOut`.
    mapping(bytes32 assetId => L2AssetBookkeepingInfo info) internal assetBookkeeping;

    /// @inheritdoc IL2AssetTracker
    mapping(bytes32 assetId => bool isTracked) public isAssetTracked;

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
    function getAssetBookkeeping(bytes32 _assetId) external view returns (L2AssetBookkeepingInfo memory) {
        return assetBookkeeping[_assetId];
    }

    /*//////////////////////////////////////////////////////////////
                            BOOKKEEPING INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IL2AssetTracker
    function trackBaseToken() external onlyUpgrader {
        bytes32 baseTokenAssetId = BASE_TOKEN_ASSET_ID;
        if (isAssetTracked[baseTokenAssetId]) {
            return;
        }
        isAssetTracked[baseTokenAssetId] = true;

        // The base token never originates from this chain, so like any bridged token its pre-tracking
        // net inbound flow is exactly its current `totalSupply()`: the pre-upgrade supply on an
        // upgraded chain, zero at genesis (the holder's balance is minted in full before this runs).
        assetBookkeeping[baseTokenAssetId].preTrackingTotalSupply = L2_BASE_TOKEN_SYSTEM_CONTRACT.totalSupply();
    }

    /// @inheritdoc IL2AssetTracker
    function registerNewTokenIfNeeded(bytes32 _assetId, uint256 _originChainId) external onlyL2NativeTokenVault {
        if (isAssetTracked[_assetId]) {
            return;
        }
        isAssetTracked[_assetId] = true;

        if (_originChainId == block.chainid) {
            // A bridged token's baseline is zero, which the slot already holds; a native one starts at
            // the infinite-deposit baseline, matching a zero `bridgedOut`.
            assetBookkeeping[_assetId].preTrackingTotalSupply = MAX_TOKEN_BALANCE;
        }
    }

    /// @inheritdoc IL2AssetTracker
    function trackLegacyTokenIfNeeded(
        bytes32 _assetId,
        uint256 _originChainId,
        address _tokenAddress
    ) external onlyL2NativeTokenVault {
        if (isAssetTracked[_assetId]) {
            return;
        }
        isAssetTracked[_assetId] = true;

        if (_originChainId == block.chainid) {
            // Before this bookkeeping existed, the vault escrow was the exact outstanding amount except
            // for indistinguishable direct donations, which are conservatively treated as escrow.
            assetBookkeeping[_assetId].preTrackingTotalSupply =
                MAX_TOKEN_BALANCE - IERC20(_tokenAddress).balanceOf(L2_NATIVE_TOKEN_VAULT_ADDR);
        } else {
            // A bridged token's totalSupply is exactly its pre-tracking net inbound flow.
            assetBookkeeping[_assetId].preTrackingTotalSupply = IERC20(_tokenAddress).totalSupply();
        }
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
    function assertRecoveryIsAccountingNeutral(bytes32 _assetId, uint256 _toChainId) public view {
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

    /// @dev Records an outbound flow when it targets L1 and this chain currently settles on L1.
    function _recordBridgingToChain(bytes32 _assetId, uint256 _toChainId, uint256 _amount) internal {
        if (
            _toChainId == L1_CHAIN_ID &&
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() == L1_CHAIN_ID
        ) {
            assetBookkeeping[_assetId].totalWithdrawalsToL1 += _amount;
        }
    }

    /// @dev Records an inbound flow when it originates from L1 and this chain currently settles on L1.
    function _recordBridgingFromChain(bytes32 _assetId, uint256 _fromChainId, uint256 _amount) internal {
        if (
            _fromChainId == L1_CHAIN_ID &&
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() == L1_CHAIN_ID
        ) {
            assetBookkeeping[_assetId].totalSuccessfulDepositsFromL1 += _amount;
        }
    }

    /// @dev Before the genesis upgrade no base-token value is transferred; revert rather than record a
    /// flow under an incorrect asset id.
    function _baseTokenAssetIdForFlow() internal view returns (bytes32 baseTokenAssetId) {
        baseTokenAssetId = BASE_TOKEN_ASSET_ID;
        require(baseTokenAssetId != bytes32(0), MissingBaseTokenAssetId());
    }
}
