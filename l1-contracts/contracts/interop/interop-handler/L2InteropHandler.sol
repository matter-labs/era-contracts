// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {
    L2_BASE_TOKEN_HOLDER,
    L2_NATIVE_TOKEN_VAULT,
    L2_MESSAGE_VERIFICATION,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT,
    L2_COMPLEX_UPGRADER_ADDR
} from "../../common/l2-helpers/L2ContractInterfaces.sol";
import {InteropHandlerBase} from "./InteropHandlerBase.sol";
import {MessageInclusionProof} from "../../common/Messaging.sol";
import {CannotClaimInteropOnL1Settlement} from "../InteropErrors.sol";
import {Unauthorized} from "../../common/L1ContractErrors.sol";

/// @title L2InteropHandler
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev L2 system contract that serves as the entry-point for executing, verifying and unbundling interop bundles.
/// The generic bundle logic lives in `InteropHandlerBase`; this contract wires in the L2 system-contract behaviour.
contract L2InteropHandler is InteropHandlerBase {
    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Initializes the reentrancy guard and records the L1 chain ID. Called by the complex upgrader.
    /// @param _l1ChainId The chain ID of L1.
    function initL2(uint256 _l1ChainId) public reentrancyGuardInitializer onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
    }

    /// @inheritdoc InteropHandlerBase
    function _proveInclusion(MessageInclusionProof memory _proof) internal override returns (bool) {
        return
            L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared({
                _chainId: _proof.chainId,
                _blockOrBatchNumber: _proof.l1BatchNumber,
                _index: _proof.l2MessageIndex,
                _message: _proof.message,
                _proof: _proof.proof
            });
    }

    /// @inheritdoc InteropHandlerBase
    /// @dev Interop claiming requires the chain to settle on Gateway so that GWAssetTracker can process the execution
    /// confirmation and move balances from pendingInteropBalance to chainBalance. We read the chain's current
    /// settlement layer from `SystemContext` (kept in sync with each batch's bootloader-driven
    /// `setSettlementLayerChainId` call); the analogous mapping on the chain's own `L2Bridgehub` is only written for
    /// chains that *settle on this Bridgehub* (i.e. populated on L1's L1Bridgehub and on a Gateway's L2Bridgehub for
    /// the chains it hosts), and is never written on a chain's own L2Bridgehub for itself.
    function _settlementGuard() internal view override {
        require(
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() != L1_CHAIN_ID,
            CannotClaimInteropOnL1Settlement()
        );
    }

    /// @inheritdoc InteropHandlerBase
    function _handleCallValue(uint256 _value, uint256 _sourceChainId) internal override {
        if (_value > 0) {
            // Transfer base tokens from the BaseTokenHolder instead of minting.
            L2_BASE_TOKEN_HOLDER.give(address(this), _value, _sourceChainId);
        }
    }

    /// @inheritdoc InteropHandlerBase
    function _expectedDestinationBaseTokenAssetId() internal view override returns (bytes32) {
        return L2_NATIVE_TOKEN_VAULT.BASE_TOKEN_ASSET_ID();
    }

    /// @notice Allows the contract to receive native ETH from L2_BASE_TOKEN_HOLDER.
    /// @dev This is required because L2_BASE_TOKEN_HOLDER.give() transfers ETH to this contract
    ///      before forwarding it to the interop call recipient.
    receive() external payable {
        if (msg.sender != address(L2_BASE_TOKEN_HOLDER)) {
            revert Unauthorized(msg.sender);
        }
    }
}
