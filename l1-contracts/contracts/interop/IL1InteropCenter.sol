// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IL1Bridgehub} from "../core/bridgehub/IL1Bridgehub.sol";
import {IInteropCenterBase} from "./IInteropCenterBase.sol";

/// @dev The parsed representation of the ERC-7786 attributes supported by the L1InteropCenter.
/// @param interopCallValue The value (in the destination chain's base token) passed with the call on the destination chain.
/// @param indirectCallMessageValue The `msg.value` (in ETH) to be passed to the cross-chain sender on L1.
/// @param mintValue The total amount of the destination chain's base token to be minted with the transaction.
/// @param l2GasLimit The gas limit of the L2 transaction.
/// @param l2GasPerPubdataByteLimit The maximum amount of L2 gas that the operator may charge the user per pubdata byte.
/// @param refundRecipient The address on the destination chain that receives the fee refund.
/// @param indirectCall Whether the message is an indirect call, i.e. it is passed through a cross-chain sender
/// (e.g. the asset router) that constructs the actual destination-side call.
/// @param factoryDepsProvided Whether the caller supplied a factory-dependencies attribute, including an empty array.
/// @param factoryDeps Factory dependencies to be published with the L1->L2 transaction (direct calls only).
struct L1MessageAttributes {
    uint256 interopCallValue;
    uint256 indirectCallMessageValue;
    uint256 mintValue;
    uint256 l2GasLimit;
    uint256 l2GasPerPubdataByteLimit;
    address refundRecipient;
    bool indirectCall;
    bool factoryDepsProvided;
    bytes[] factoryDeps;
}

/// @title L1 Interop Center interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1InteropCenter is IInteropCenterBase {
    /// @notice The L1 Bridgehub, used as the registry of chains, base tokens and ZK chain addresses.
    function BRIDGE_HUB() external view returns (IL1Bridgehub);

    /// @notice Used to initialize the proxy.
    /// @param _owner The owner of the contract.
    function initialize(address _owner) external;

    /// @notice Parses ERC-7786 attributes into the L1-specific representation.
    /// @param _attributes The ERC-7786 attributes to parse.
    /// @return l1MessageAttributes The parsed attributes.
    function parseL1Attributes(
        bytes[] calldata _attributes
    ) external pure returns (L1MessageAttributes memory l1MessageAttributes);

    /// @notice Estimates the base cost (in the destination chain's base token) of an L1->L2 transaction.
    /// @param _chainId Destination chain ID.
    /// @param _gasPrice L1 gas price used for the estimate.
    /// @param _l2GasLimit Destination execution gas limit.
    /// @param _l2GasPerPubdataByteLimit Maximum gas charged per pubdata byte.
    /// @return Base cost in the destination chain's base token.
    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256);
}
