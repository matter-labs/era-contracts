// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {InteropCallStarter} from "../../common/Messaging.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {ERC7930_V1_MIN_LENGTH} from "../InteropConstants.sol";
import {InteroperableAddressChainReferenceNotEmpty, InteroperableAddressNotEmpty} from "../InteropErrors.sol";
import {IInteropCenterBase} from "../IInteropCenterBase.sol";
import {InteroperableAddress} from "../../vendor/draft-InteroperableAddress.sol";

/// @title InteropCenterBase
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Shared external message-sending surface and address validation for the L1 and L2 Interop Centers.
/// @dev The external wrappers apply pause and reentrancy protection exactly once, then dispatch to
/// environment-specific internal implementations without changing `msg.sender`.
abstract contract InteropCenterBase is
    IInteropCenterBase,
    ReentrancyGuard,
    Ownable2StepUpgradeable,
    PausableUpgradeable
{
    /// @notice Sends a single ERC-7786 message using the layer-specific transport.
    function sendMessage(
        bytes calldata recipient,
        bytes calldata payload,
        bytes[] calldata attributes
    ) external payable override whenNotPaused nonReentrant returns (bytes32 sendId) {
        sendId = _sendMessage(recipient, payload, attributes);
    }

    /// @inheritdoc IInteropCenterBase
    function sendBundle(
        bytes calldata _destinationChainId,
        InteropCallStarter[] calldata _callStarters,
        bytes[] calldata _bundleAttributes
    ) external payable override whenNotPaused nonReentrant returns (bytes32 bundleHash) {
        bundleHash = _sendBundle(_destinationChainId, _callStarters, _bundleAttributes);
    }

    function _sendMessage(
        bytes calldata _recipient,
        bytes calldata _payload,
        bytes[] calldata _attributes
    ) internal virtual returns (bytes32 sendId);

    function _sendBundle(
        bytes calldata _destinationChainId,
        InteropCallStarter[] calldata _callStarters,
        bytes[] calldata _bundleAttributes
    ) internal virtual returns (bytes32 sendId);

    /// @notice Verifies that an ERC-7930 address has an empty chain-reference field.
    function _ensureEmptyChainReference(bytes calldata _interoperableAddress) internal pure {
        require(
            _interoperableAddress.length >= ERC7930_V1_MIN_LENGTH,
            InteroperableAddress.InteroperableAddressParsingError(_interoperableAddress)
        );
        uint8 chainReferenceLength = uint8(_interoperableAddress[0x04]);
        require(chainReferenceLength == 0, InteroperableAddressChainReferenceNotEmpty(_interoperableAddress));
    }

    /// @notice Verifies that an ERC-7930 address has an empty address field.
    function _ensureEmptyAddress(bytes calldata _interoperableAddress) internal pure {
        require(
            _interoperableAddress.length >= ERC7930_V1_MIN_LENGTH,
            InteroperableAddress.InteroperableAddressParsingError(_interoperableAddress)
        );
        uint8 chainReferenceLength = uint8(_interoperableAddress[0x04]);
        require(
            _interoperableAddress.length >= ERC7930_V1_MIN_LENGTH + chainReferenceLength,
            InteroperableAddress.InteroperableAddressParsingError(_interoperableAddress)
        );
        uint8 addressLength = uint8(_interoperableAddress[0x05 + chainReferenceLength]);
        require(addressLength == 0, InteroperableAddressNotEmpty(_interoperableAddress));
    }

    /// @inheritdoc IInteropCenterBase
    function pause() external override onlyOwner {
        _pause();
    }

    /// @inheritdoc IInteropCenterBase
    function unpause() external override onlyOwner {
        _unpause();
    }
}
