// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMessageVerification} from "../../state-transition/chain-interfaces/IMessageVerification.sol";
import {L2Log, L2Message} from "../../common/Messaging.sol";

/// @title MockL2MessageVerification
/// @notice Mock implementation of L2MessageVerification for Anvil testing.
/// @dev Always returns true for message inclusion proofs to bypass L1 settlement in local testing.
contract MockL2MessageVerification is IMessageVerification {
    function proveL2MessageInclusionShared(
        uint256,
        uint256,
        uint256,
        L2Message calldata,
        bytes32[] calldata
    ) external pure override returns (bool) {
        return true;
    }

    function proveL2LogInclusionShared(
        uint256,
        uint256,
        uint256,
        L2Log calldata,
        bytes32[] calldata
    ) external pure override returns (bool) {
        return true;
    }

    function proveL2LeafInclusionShared(
        uint256,
        uint256,
        uint256,
        bytes32,
        bytes32[] calldata
    ) external pure override returns (bool) {
        return true;
    }
}
