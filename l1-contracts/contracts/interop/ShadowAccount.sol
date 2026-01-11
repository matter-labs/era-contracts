// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {InteroperableAddress} from "../vendor/draft-InteroperableAddress.sol";
import {L2_INTEROP_HANDLER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The ShadowAccount contract represents a cross-chain identity on the destination chain.
/// It allows users from other chains to have a consistent address and execute transactions
/// on the destination chain without requiring special support from target contracts.
contract ShadowAccount {
    /// @notice The InteropHandler address that deployed this shadow account
    address public immutable INTEROP_HANDLER;

    /// @notice The full ERC-7930 interoperable address of the owner (packed bytes format)
    bytes public fullOwnerAddress;

    /// @notice The chain ID of the owner
    uint256 public ownerChainId;

    /// @notice The EVM address of the owner on the source chain
    address public ownerAddress;

    /// @notice Error thrown when caller is not the InteropHandler
    error OnlyInteropHandler(address caller);

    /// @notice Error thrown when the call execution fails
    error CallExecutionFailed(bytes returndata);

    /// @notice Modifier to restrict access to the InteropHandler only
    modifier onlyInteropHandler() {
        if (msg.sender != INTEROP_HANDLER) {
            revert OnlyInteropHandler(msg.sender);
        }
        _;
    }

    /// @notice Creates a new ShadowAccount for the given interoperable owner address
    /// @param _fullOwnerAddress The ERC-7930 formatted interoperable address of the owner
    constructor(bytes memory _fullOwnerAddress) {
        INTEROP_HANDLER = msg.sender;
        fullOwnerAddress = _fullOwnerAddress;

        // Parse the EVM address from the interoperable address format
        (uint256 chainId, address addr) = InteroperableAddress.parseEvmV1(_fullOwnerAddress);
        ownerChainId = chainId;
        ownerAddress = addr;
    }

    /// @notice Executes a call from this shadow account to a target contract
    /// @dev Can only be called by the InteropHandler contract
    /// @param target The address of the contract to call
    /// @param value The amount of native token to send with the call
    /// @param data The calldata to pass to the target contract
    /// @return returndata The data returned by the call
    function executeFromIH(
        address target,
        uint256 value,
        bytes calldata data
    ) external payable onlyInteropHandler returns (bytes memory returndata) {
        bool success;
        (success, returndata) = target.call{value: value}(data);

        if (!success) {
            revert CallExecutionFailed(returndata);
        }

        return returndata;
    }

    /// @notice Allows the shadow account to receive native tokens
    receive() external payable {}
}
