// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (proxy/Proxy.sol)

pragma solidity ^0.8.13;

// import "../../state-transition/state-transition-interfaces/IStateTransition.sol";

import {IVerifier, VerifierParams} from "../../state-transition/chain-interfaces/IVerifier.sol";
// import "../../state-transition/Verifier.sol";
import {UpgradeStorage} from "../../state-transition/chain-deps/StateTransitionChainStorage.sol";
import "../../common/interfaces/IAllowList.sol";
import "../../common/Messaging.sol";
import "../../state-transition/libraries/PriorityQueue.sol";

struct BridgehubStorage {
    /// @notice Address which will exercise critical changes to the Diamond Proxy (upgrades, freezing & unfreezing)
    address governor;
    /// @notice Address that the governor proposed as one that will replace it
    address pendingGovernor;
    
    /// new fields
    /// @notice we store registered stateTransitions
    mapping(address => bool) stateTransitionIsRegistered;
    /// @notice chainID => stateTransition contract address
    mapping(uint256 => address) stateTransition;
}
