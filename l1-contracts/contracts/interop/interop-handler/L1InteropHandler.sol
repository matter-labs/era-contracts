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
/// @notice L1-side interop handler. It executes L2 -> L1 withdrawal bundles through the shared
/// `InteropHandlerBase.executeBundle` interface (symmetric to the L2 `L2InteropHandler`): a withdrawal is a
/// single-call interop bundle emitted by the L2 InteropCenter whose only call targets the L1 asset router's
/// `finalizeDeposit` via ERC-7786 `receiveMessage`.
/// @dev Deployed behind a proxy on L1.
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
    /// @param _l1ChainId The chain ID of L1.
    function initialize(uint256 _l1ChainId) external reentrancyGuardInitializer {
        L1_CHAIN_ID = _l1ChainId;
    }

    /// @inheritdoc InteropHandlerBase
    /// @dev Proves the withdrawal bundle's inclusion via the L1 MessageRoot.
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
    /// @dev L1 has no settlement-layer restriction: it is the base layer where withdrawals are ultimately claimed.
    // solhint-disable-next-line no-empty-blocks
    function _settlementGuard() internal view override {}

    /// @inheritdoc InteropHandlerBase
    /// @dev Withdrawals carry the amount inside the `finalizeDeposit` transfer data, never as call value.
    function _handleCallValue(uint256 _value, uint256 /* _sourceChainId */) internal pure override {
        require(_value == 0, InteropWithdrawalNonZeroValue(_value));
    }

    /// @inheritdoc InteropHandlerBase
    /// @dev On L1 the base token is ETH; withdrawal bundles destined for L1 carry L1's ETH asset ID.
    function _expectedDestinationBaseTokenAssetId() internal view override returns (bytes32) {
        return DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
    }
}
