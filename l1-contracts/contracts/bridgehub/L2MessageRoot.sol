// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IBridgehub} from "./IBridgehub.sol";

import {MessageRootBase} from "./MessageRootBase.sol";

import {L2_BRIDGEHUB_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The MessageRoot contract is responsible for storing the cross message roots of the chains and the aggregated root of all chains.
contract L2MessageRoot is MessageRootBase {
    /// @dev Chain ID of L1 for bridging reasons.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    uint256 public L1_CHAIN_ID;

    /// @dev Contract is expected to be used as proxy implementation on L1, but as a system contract on L2.
    /// This means we call the _initialize in both the constructor and the initialize functions.
    /// @dev Initialize the implementation to prevent Parity hack.
    /// @param _l1ChainId The chain id of L1.
    function initL2(uint256 _l1ChainId) public onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
        _initialize();
        _disableInitializers();
    }

    function _bridgehub() internal view override returns (IBridgehub) {
        return IBridgehub(L2_BRIDGEHUB_ADDR);
    }

    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    // A method for backwards compatibility with the old implementation
    function BRIDGE_HUB() public view returns (IBridgehub) {
        return IBridgehub(L2_BRIDGEHUB_ADDR);
    }
}
