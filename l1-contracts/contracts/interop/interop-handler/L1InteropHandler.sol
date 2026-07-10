// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {InteropHandlerBase} from "./InteropHandlerBase.sol";

import {MessageInclusionProof} from "../../common/Messaging.sol";
import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IMessageRootBase} from "../../core/message-root/IMessageRoot.sol";
import {InteropWithdrawalNonZeroValue} from "../../bridge/L1BridgeContractErrors.sol";
import {ZeroAddress} from "../../common/L1ContractErrors.sol";

/// @title L1InteropHandler
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice L1-side interop handler. It executes L2 -> L1 interop bundles through the shared
/// `InteropHandlerBase.executeBundle` interface (symmetric to the L2 `L2InteropHandler`). An L1-destined bundle
/// is a single zero-value call — direct (a plain L2 -> L1 message) or indirect (asset-router routed) — enforced
/// at send time by the L2 InteropCenter and delivered to its target on L1 via ERC-7786 `receiveMessage`. The
/// target and payload are general: the canonical use is an L2 -> L1 withdrawal (an indirect call targeting the
/// L1 asset router's `finalizeDeposit`), but any single such call is allowed.
/// @dev Deployed behind a proxy on L1.
/// @dev Pausable so that withdrawals can be halted: previously `L1Nullifier.finalizeDeposit` carried the
/// `whenNotPaused` gate for withdrawal finalization; that gate now lives here, on the call-executing entry
/// points (`executeBundle`/`unbundleBundle`) of the handler that replaced it.
contract L1InteropHandler is InteropHandlerBase, Ownable2StepUpgradeable, PausableUpgradeable {
    /// @dev MessageRoot smart contract that is used to prove message inclusion.
    IMessageRootBase public immutable MESSAGE_ROOT;

    /// @dev Contract is expected to be used as a proxy implementation.
    /// @dev Locking the reentrancy guard (and disabling the OZ initializers) in the constructor prevents the
    /// implementation from being initialized.
    /// @param _messageRoot The MessageRoot used to prove message inclusion.
    constructor(IMessageRootBase _messageRoot) reentrancyGuardInitializer {
        _disableInitializers();
        MESSAGE_ROOT = _messageRoot;
    }

    /// @notice Initializes the contract behind its proxy.
    /// @param _owner The owner that can pause/unpause withdrawal processing.
    function initialize(address _owner) external reentrancyGuardInitializer initializer {
        require(_owner != address(0), ZeroAddress());
        _transferOwnership(_owner);
    }

    /// @notice Pauses bundle execution/unbundling — i.e. halts L2 -> L1 withdrawal finalization.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes bundle execution/unbundling.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @inheritdoc InteropHandlerBase
    /// @dev Blocks `executeBundle`/`unbundleBundle` while paused, halting withdrawal finalization.
    function _ensureNotPaused() internal view override {
        _requireNotPaused();
    }

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
    /// @dev Deliberate double-defense: the same invariant is already enforced at SEND time by the L2
    /// InteropCenter (`NonZeroValueToL1NotSupported`); this receive-side check re-verifies it with its own
    /// error (`InteropWithdrawalNonZeroValue`) in case a malformed bundle ever reaches L1.
    function _handleCallValue(uint256 _value, uint256 /* _sourceChainId */) internal pure override {
        require(_value == 0, InteropWithdrawalNonZeroValue(_value));
    }

    /// @inheritdoc InteropHandlerBase
    /// @dev On L1 the base token is ETH; bundles destined for L1 carry L1's ETH asset ID.
    function _expectedDestinationBaseTokenAssetId() internal view override returns (bytes32) {
        return DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
    }
}
