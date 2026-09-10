// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {IERC7786GatewaySource} from "../IERC7786GatewaySource.sol";
import {IInteropCenterBase} from "../IInteropCenterBase.sol";

/// @title InteropCenterBase
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Shared ERC-7786 `sendMessage` entry point and pause switch of the L1 and L2 Interop Centers.
/// @dev The external wrapper applies pause and reentrancy protection exactly once, then dispatches to the
/// layer-specific `_sendMessage` implementation without changing `msg.sender`. Multi-call bundles are an
/// L2-only feature and therefore live in `L2InteropCenter` rather than here.
abstract contract InteropCenterBase is
    IInteropCenterBase,
    ReentrancyGuard,
    Ownable2StepUpgradeable,
    PausableUpgradeable
{
    /// @inheritdoc IERC7786GatewaySource
    function sendMessage(
        bytes calldata recipient,
        bytes calldata payload,
        bytes[] calldata attributes
    ) external payable override whenNotPaused nonReentrant returns (bytes32 sendId) {
        sendId = _sendMessage(recipient, payload, attributes);
    }

    /// @dev Layer-specific implementation of {sendMessage}; runs with pause and reentrancy protection applied.
    function _sendMessage(
        bytes calldata _recipient,
        bytes calldata _payload,
        bytes[] calldata _attributes
    ) internal virtual returns (bytes32 sendId);

    /// @inheritdoc IInteropCenterBase
    function pause() external override onlyOwner {
        _pause();
    }

    /// @inheritdoc IInteropCenterBase
    function unpause() external override onlyOwner {
        _unpause();
    }
}
