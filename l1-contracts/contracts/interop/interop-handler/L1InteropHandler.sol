// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {InteropHandlerBase} from "./InteropHandlerBase.sol";

import {MessageInclusionProof} from "../../common/Messaging.sol";
import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IMessageRootBase} from "../../core/message-root/IMessageRoot.sol";
import {InteropWithdrawalNonZeroValue} from "../../bridge/L1BridgeContractErrors.sol";

/// @title L1InteropHandler
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice L1-side interop handler. It executes L2 -> L1 interop bundles through the shared
/// `InteropHandlerBase.executeBundle` interface (symmetric to the L2 `L2InteropHandler`). An L1-destined bundle
/// is a single indirect, zero-value call (enforced at send time by the L2 InteropCenter) delivered to its target
/// on L1 via ERC-7786 `receiveMessage`. The target and payload are general: the canonical use is an L2 -> L1
/// withdrawal (the call targets the L1 asset router's `finalizeDeposit`), but any single such call is allowed.
/// @dev Deployed behind a proxy on L1.
/// @dev Withdrawal pausability is intentionally NOT enforced here. Previously `L1Nullifier.finalizeDeposit`
/// carried a `whenNotPaused` gate; in the current design that responsibility lives at the asset-handler layer,
/// where funds are actually released — `NativeTokenVaultBase.bridgeMint` is `whenNotPaused`, so pausing the
/// asset router / NTV halts the release of every withdrawal routed through this handler. Keeping the handler
/// itself stateless and pauseless (no Ownable/Pausable) avoids a second, redundant pause switch.
contract L1InteropHandler is InteropHandlerBase {
    /// @dev MessageRoot smart contract that is used to prove message inclusion.
    IMessageRootBase public immutable MESSAGE_ROOT;

    /// @dev Contract is expected to be used as a proxy implementation.
    /// @dev Locking the reentrancy guard in the constructor prevents the implementation from being initialized.
    /// @param _messageRoot The MessageRoot used to prove message inclusion.
    constructor(IMessageRootBase _messageRoot) reentrancyGuardInitializer {
        MESSAGE_ROOT = _messageRoot;
    }

    /// @notice Initializes the contract behind its proxy.
    /// @dev Only locks the reentrancy guard: it doubles as one-time initialization protection (a second call
    /// reverts with `SlotOccupied`). The handler holds no configurable state — the L1 chain id it operates on
    /// is simply `block.chainid`.
    function initialize() external reentrancyGuardInitializer {}

    /// @inheritdoc InteropHandlerBase
    /// @dev Proves the bundle's inclusion via the L1 MessageRoot.
    function _proveInclusion(MessageInclusionProof memory _proof) internal override returns (bool) {
        return
            MESSAGE_ROOT.proveL2MessageInclusionShared({
                _chainId: _proof.chainId,
                _blockOrBatchNumber: _proof.l1BatchNumber,
                _index: _proof.l2MessageIndex,
                _message: _proof.message,
                _proof: _proof.proof
            });
    }

    /// @inheritdoc InteropHandlerBase
    /// @dev L1-destined calls carry no base-token call value; any transferred amount rides inside the call
    /// payload (e.g. a withdrawal's `finalizeDeposit` transfer data).
    function _handleCallValue(uint256 _value, uint256 /* _sourceChainId */) internal pure override {
        require(_value == 0, InteropWithdrawalNonZeroValue(_value));
    }

    /// @inheritdoc InteropHandlerBase
    /// @dev On L1 the base token is ETH; bundles destined for L1 carry L1's ETH asset ID.
    function _expectedDestinationBaseTokenAssetId() internal view override returns (bytes32) {
        return DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
    }
}
