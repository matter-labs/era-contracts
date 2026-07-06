// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IERC7786GatewaySource} from "./IERC7786GatewaySource.sol";
import {IL1Bridgehub} from "../core/bridgehub/IL1Bridgehub.sol";

/// @dev The parsed representation of the ERC-7786 attributes supported by the L1InteropCenter.
/// @param interopCallValue The value (in the destination chain's base token) passed with the call on the destination chain.
/// @param indirectCallMessageValue The `msg.value` (in ETH) to be passed to the cross-chain sender on L1.
/// @param mintValue The total amount of the destination chain's base token to be minted with the transaction.
/// @param l2GasLimit The gas limit of the L2 transaction.
/// @param l2GasPerPubdataByteLimit The maximum amount of L2 gas that the operator may charge the user per pubdata byte.
/// @param refundRecipient The address on the destination chain that receives the fee refund.
/// @param indirectCall Whether the message is an indirect call, i.e. it is passed through a cross-chain sender
/// (a "second bridge", e.g. the asset router) that constructs the actual destination-side call.
/// @param factoryDeps Factory dependencies to be published with the L1->L2 transaction (direct calls only).
struct L1MessageAttributes {
    uint256 interopCallValue;
    uint256 indirectCallMessageValue;
    uint256 mintValue;
    uint256 l2GasLimit;
    uint256 l2GasPerPubdataByteLimit;
    address refundRecipient;
    bool indirectCall;
    bytes[] factoryDeps;
}

/// @title L1 Interop Center interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1InteropCenter is IERC7786GatewaySource {
    /// @notice The L1 Bridgehub that performs the L1->L2 transaction requests on behalf of the L1InteropCenter.
    function BRIDGE_HUB() external view returns (IL1Bridgehub);

    /// @notice Used to initialize the proxy.
    function initialize() external;

    /// @notice Parses ERC-7786 attributes into the L1-specific representation.
    /// @param _attributes The ERC-7786 attributes to parse.
    /// @return l1MessageAttributes The parsed attributes.
    function parseL1Attributes(
        bytes[] calldata _attributes
    ) external pure returns (L1MessageAttributes memory l1MessageAttributes);
}
