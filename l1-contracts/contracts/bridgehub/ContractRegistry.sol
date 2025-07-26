// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {IContractRegistry, EcosystemContract, CTMContract, AllContracts} from "./IContractRegistry.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The ContractRegistry contract is used to register and manage the contracts.
contract ContractRegistry is IContractRegistry, Ownable2StepUpgradeable, ReentrancyGuard {
    mapping(EcosystemContract => address ecosystemContract) public ecosystemContractAddress;

    mapping(address chainTypeManager => mapping(CTMContract => address)) public ctmContractAddress;

    error LengthMismatch();

    constructor() {
        _disableInitializers();
        require(uint256(type(EcosystemContract).max) + uint256(type(CTMContract ).max) == uint256(type(AllContracts).max), LengthMismatch());
    }

    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    function setEcosystemContractAddress(EcosystemContract _ecosystemContract, address _contractAddress) external onlyOwner {
        ecosystemContractAddress[_ecosystemContract] = _contractAddress;
    }

    function setCTMContractAddress(address _chainTypeManager, CTMContract _ctmContract, address _contractAddress) external onlyOwner {
        ctmContractAddress[_chainTypeManager][_ctmContract] = _contractAddress;
    }

    error ContractOutOfRange();

    function ecosystemContractFromContract(AllContracts _contract) external view returns (EcosystemContract) {
        if (uint256(_contract) < uint256(type(EcosystemContract).max)) {
            return EcosystemContract(uint8(_contract));
        } else {
            revert ContractOutOfRange();
        }

    }

    function ctmContractFromContract(AllContracts _contract) external view returns (CTMContract) {
        if (uint256(_contract) >= uint256(type(EcosystemContract).max)) {
            return CTMContract(uint8(_contract) - uint8(type(EcosystemContract).max));
        } else {
            revert ContractOutOfRange();
        }
    }
}
