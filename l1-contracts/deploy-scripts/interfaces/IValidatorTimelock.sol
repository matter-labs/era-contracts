// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IValidatorTimelock {
    function setChainTypeManager(IChainTypeManager _chainTypeManager) external;
    function chainTypeManager() external view returns (IChainTypeManager);
    function transferOwnership(address newOwner) external;
}
