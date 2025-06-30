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

import {L2_BRIDGEHUB_ADDR} from "../common/L2ContractAddresses.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The MessageRoot contract is responsible for storing the cross message roots of the chains and the aggregated root of all chains.
contract L2MessageRoot is MessageRootBase {
    /// @dev Contract is expected to be used as proxy implementation on L1, but as a system contract on L2.
    /// This means we call the _initialize in both the constructor and the initialize functions.
    /// @dev Initialize the implementation to prevent Parity hack.
    function initL2() public onlyUpgrader {
        _initialize();
        _disableInitializers();
    }

    function _bridgehub() internal view override returns (IBridgehub) {
        return IBridgehub(L2_BRIDGEHUB_ADDR);
    }

    // A method for backwards compatibility with the old implementation
    function BRIDGE_HUB() public view returns (IBridgehub) {
        return IBridgehub(L2_BRIDGEHUB_ADDR);
    }
}
