// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {IContractRegistry} from "./IContractRegistry.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The ContractRegistry contract is used to register and manage the contracts.
contract ContractRegistry is IContractRegistry, Ownable2StepUpgradeable, ReentrancyGuard {
    mapping(Contract => address ecosystemContract) public contractAddress;

    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    function setContractAddress(Contract _ecosystemContract, address _contractAddress) external onlyOwner {
        contractAddress[_ecosystemContract] = _contractAddress;
    }
}
