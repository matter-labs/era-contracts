// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {DynamicIncrementalMerkle} from "../common/libraries/DynamicIncrementalMerkle.sol";
import {Initializable} from "@openzeppelin/contracts-v4/proxy/utils/Initializable.sol";

import {IBridgehub} from "./IBridgehub.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {OnlyBridgehub, OnlyChain, ChainExists, MessageRootNotRegistered} from "./L1BridgehubErrors.sol";
import {FullMerkle} from "../common/libraries/FullMerkle.sol";

import {MessageHashing} from "../common/libraries/MessageHashing.sol";

import {MessageRootBase} from "./MessageRootBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The MessageRoot contract is responsible for storing the cross message roots of the chains and the aggregated root of all chains.
contract L2MessageRoot is MessageRootBase {
    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public BRIDGE_HUB;

    /// @dev Contract is expected to be used as proxy implementation on L1, but as a system contract on L2.
    /// This means we call the _initialize in both the constructor and the initialize functions.
    /// @dev Initialize the implementation to prevent Parity hack.
    function initL2(IBridgehub _bridgehub) public {
        BRIDGE_HUB = _bridgehub;
        _initialize();
        _disableInitializers();
    }

    function _bridgehub() internal override view returns (IBridgehub) {
        return BRIDGE_HUB;
    }
}
