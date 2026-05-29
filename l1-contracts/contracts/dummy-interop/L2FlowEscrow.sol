// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IL2FlowEscrow} from "./IL2FlowEscrow.sol";
import {COMMIT_LOG_TAG, SendSpec, SpecState} from "./IDummyFlow.sol";
import {L2ContractHelper} from "../common/l2-helpers/L2ContractHelper.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {IL2AssetRouter} from "../bridge/asset-router/IL2AssetRouter.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";

/// @dev `finalizeDeposit` is declared on `AssetRouterBase` (the abstract contract) but
/// not on its interface. Tiny local interface so the escrow can call it without pulling
/// in the abstract contract.
interface IAssetRouterFinalizeDeposit {
    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes calldata _transferData) external payable;
}
import {
    EscrowAlreadyInitialized,
    EscrowDepositorMismatch,
    EscrowInvalidAuthorizeFromState,
    EscrowInvalidRefundAuthorizeFromState,
    EscrowOnlyAliasedLinker,
    EscrowSelfDestination,
    EscrowSendSpecMissingDest,
    EscrowSendSpecZeroAmount,
    EscrowSendSpecZeroOriginChain,
    EscrowSendSpecZeroRecipient,
    EscrowSendSpecZeroToken,
    EscrowSpecAlreadyCommitted,
    EscrowSpecNotExecutable,
    EscrowSpecNotForThisChain,
    EscrowSpecNotRevertable
} from "./DummyFlowErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See `IL2FlowEscrow`. All three addresses the escrow depends on (the L1 linker
/// it trusts, plus the AR/NTV it calls into) are storage-set in `initialize` — none are
/// baked into bytecode. This lets the escrow point at either the system AR/NTV (system
/// predeploys) or a userspace `PrivateL2AssetRouter` / `PrivateL2NativeTokenVault`,
/// chosen at deploy time. CREATE2 with a fixed salt across L2s still yields the same
/// escrow address (since bytecode is identical), but each instance's wiring is set by
/// its per-chain initializer.
///
/// Asset moves route through `L2AssetRouter` → `L2NativeTokenVault`:
///   - source: `AR.initiateIndirectCall` (gated to also accept this escrow via the AR's
///     `atomicFlowEscrow` extension);
///   - destination: `AR.finalizeDeposit` (same gate extension).
/// Refunds bypass AR — locked tokens never leave escrow custody before execute, so a
/// refund is a direct local `safeTransfer`.
contract L2FlowEscrow is IL2FlowEscrow {
    using SafeERC20 for IERC20;

    /// @dev L1 linker this escrow trusts. Set once via `initialize`.
    address private _l1Linker;

    /// @dev L2 asset router this escrow calls into for burns/mints. Set once via
    /// `initialize`. Typically a `PrivateL2AssetRouter` deployed in userspace, but the
    /// system `L2_ASSET_ROUTER_ADDR` is also a valid choice on chains that wire its
    /// `atomicFlowEscrow` slot to point at this escrow.
    address private _assetRouter;

    /// @dev L2 native token vault used for source-side allowances. Set once via
    /// `initialize`. Must be the NTV that `_assetRouter` itself routes burns through.
    address private _nativeTokenVault;

    mapping(bytes32 flowId => mapping(bytes32 specHash => SpecState)) internal _state;

    /// @notice One-shot initializer.
    /// @param _linker The canonical L1 linker address whose aliased counterpart will be
    /// allowed to call `authorizeFromL1` / `authorizeRefundFromL1`.
    /// @param _ar The L2 asset router this escrow drives for burns/mints.
    /// @param _ntv The L2 native token vault `_ar` routes through.
    function initialize(address _linker, address _ar, address _ntv) external {
        if (_l1Linker != address(0)) revert EscrowAlreadyInitialized();
        _l1Linker = _linker;
        _assetRouter = _ar;
        _nativeTokenVault = _ntv;
    }

    /// @inheritdoc IL2FlowEscrow
    function L1_LINKER() external view returns (address) {
        return _l1Linker;
    }

    /// @inheritdoc IL2FlowEscrow
    function commitSend(bytes32 _flowId, SendSpec calldata _spec) external {
        _validateSourceSpec(_spec);
        if (msg.sender != _spec.depositor) revert EscrowDepositorMismatch(msg.sender, _spec.depositor);

        bytes32 specHash = keccak256(abi.encode(_spec));
        if (_state[_flowId][specHash] != SpecState.Unset) revert EscrowSpecAlreadyCommitted(specHash);
        _state[_flowId][specHash] = SpecState.Committed;

        IERC20(_spec.originToken).safeTransferFrom(_spec.depositor, address(this), _spec.amount);

        // L2→L1 commit log: linker reads this back via `IMessageVerification` to learn the
        // chain's outbound contribution. Payload is `(TAG, flowId, destChainId, specHash)`;
        // the sender field of the L2Message (set by the L1 messenger system contract) pins
        // the escrow address — not duplicated in the data.
        L2ContractHelper.sendMessageToL1(abi.encode(COMMIT_LOG_TAG, _flowId, _spec.destChainId, specHash));

        emit FlowCommitted(_flowId, specHash, _spec.depositor);
    }

    /// @inheritdoc IL2FlowEscrow
    function authorizeFromL1(bytes32 _flowId, bytes32[] calldata _specHashes) external {
        _requireAliasedLinker();
        uint256 n = _specHashes.length;
        for (uint256 i; i < n; ++i) {
            bytes32 h = _specHashes[i];
            SpecState s = _state[_flowId][h];
            // Valid prior states: Unset (destination) or Committed (source).
            if (s != SpecState.Unset && s != SpecState.Committed) {
                revert EscrowInvalidAuthorizeFromState(h, s);
            }
            _state[_flowId][h] = SpecState.Executable;
            emit FlowAuthorized(_flowId, h);
        }
    }

    /// @inheritdoc IL2FlowEscrow
    function authorizeRefundFromL1(bytes32 _flowId, bytes32[] calldata _specHashes) external {
        _requireAliasedLinker();
        uint256 n = _specHashes.length;
        for (uint256 i; i < n; ++i) {
            bytes32 h = _specHashes[i];
            SpecState s = _state[_flowId][h];
            // Only Committed entries can be refunded — destinations have no lock to return.
            if (s != SpecState.Committed) revert EscrowInvalidRefundAuthorizeFromState(h, s);
            _state[_flowId][h] = SpecState.Revertable;
            emit FlowRefundAuthorized(_flowId, h);
        }
    }

    /// @inheritdoc IL2FlowEscrow
    function execute(bytes32 _flowId, SendSpec calldata _spec) external {
        bytes32 specHash = keccak256(abi.encode(_spec));
        SpecState s = _state[_flowId][specHash];
        if (s != SpecState.Executable) revert EscrowSpecNotExecutable(specHash, s);
        _state[_flowId][specHash] = SpecState.Executed;

        bool isSource;
        if (_spec.originChainId == block.chainid) {
            _executeSource(_spec);
            isSource = true;
        } else if (_spec.destChainId == block.chainid) {
            _executeDestination(_spec);
            isSource = false;
        } else {
            revert EscrowSpecNotForThisChain(_spec.originChainId, _spec.destChainId);
        }

        emit FlowExecuted(_flowId, specHash, isSource);
    }

    /// @dev Source-side burn. Approve NTV for the locked amount, then call
    /// `AR.initiateIndirectCall` — its internal `_burn` path pulls from `address(this)`
    /// (passed as `_originalCaller`) into NTV custody. The returned `InteropCallStarter`
    /// is discarded; we don't emit an outbound interop bundle, the L1 linker carries
    /// authorization instead.
    function _executeSource(SendSpec calldata _spec) internal {
        IERC20(_spec.originToken).safeIncreaseAllowance(_nativeTokenVault, _spec.amount);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(_spec.originChainId, _spec.originToken);
        bytes memory burnData = DataEncoding.encodeBridgeBurnData(_spec.amount, _spec.recipient, _spec.originToken);
        bytes memory depositData = DataEncoding.encodeAssetRouterBridgehubDepositData(assetId, burnData);
        IL2AssetRouter(_assetRouter).initiateIndirectCall({
            _chainId: _spec.destChainId,
            _originalCaller: address(this),
            _value: 0,
            _data: depositData
        });
    }

    /// @dev Destination-side mint. Synthesize the NTV-expected `transferData` from the
    /// `SendSpec` body (whose hash is bound by the L1 authorization), then call
    /// `AR.finalizeDeposit`. The AR's extended `onlyAssetRouterCounterpartOrSelf` accepts
    /// this escrow as the canonical atomic-flow escrow.
    function _executeDestination(SendSpec calldata _spec) internal {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(_spec.originChainId, _spec.originToken);
        bytes memory transferData = DataEncoding.encodeBridgeMintData({
            _originalCaller: _spec.depositor,
            _remoteReceiver: _spec.recipient,
            _originToken: _spec.originToken,
            _amount: _spec.amount,
            _erc20Metadata: _spec.erc20Data
        });
        IAssetRouterFinalizeDeposit(_assetRouter).finalizeDeposit(_spec.originChainId, assetId, transferData);
    }

    /// @inheritdoc IL2FlowEscrow
    function claimRefund(bytes32 _flowId, SendSpec calldata _spec) external {
        bytes32 specHash = keccak256(abi.encode(_spec));
        SpecState s = _state[_flowId][specHash];
        if (s != SpecState.Revertable) revert EscrowSpecNotRevertable(specHash, s);
        _state[_flowId][specHash] = SpecState.Reverted;

        // Source-side only — the depositor is the recorded payer carried in the spec body
        // (whose hash is bound by the L1 authorization).
        IERC20(_spec.originToken).safeTransfer(_spec.depositor, _spec.amount);

        emit FlowRefunded(_flowId, specHash, _spec.depositor);
    }

    /// @inheritdoc IL2FlowEscrow
    function bundleState(bytes32 _flowId, bytes32 _specHash) external view returns (SpecState) {
        return _state[_flowId][_specHash];
    }

    function _requireAliasedLinker() internal view {
        address unaliased = AddressAliasHelper.undoL1ToL2Alias(msg.sender);
        if (unaliased != _l1Linker) revert EscrowOnlyAliasedLinker(msg.sender);
    }

    /// @dev Validation applied at `commitSend`. A source-side spec must describe a real
    /// outbound transfer that originates on this chain.
    function _validateSourceSpec(SendSpec calldata _spec) internal view {
        if (_spec.destChainId == 0) revert EscrowSendSpecMissingDest();
        if (_spec.destChainId == block.chainid) revert EscrowSelfDestination(_spec.destChainId);
        if (_spec.originChainId != block.chainid) revert EscrowSendSpecZeroOriginChain();
        if (_spec.amount == 0) revert EscrowSendSpecZeroAmount();
        if (_spec.originToken == address(0)) revert EscrowSendSpecZeroToken();
        if (_spec.recipient == address(0)) revert EscrowSendSpecZeroRecipient();
    }
}
