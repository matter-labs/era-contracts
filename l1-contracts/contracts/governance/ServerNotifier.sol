// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ZeroAddress, Unauthorized} from "../common/L1ContractErrors.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";

contract ServerNotifier is Ownable2Step, ReentrancyGuard {
    IChainTypeManager public chainTypeManager;

    event MigrateToGateway(uint256 indexed chainId);
    event MigrateFromGateway(uint256 indexed chainId);

    /// @notice Checks if the caller is the admin of the chain.
    modifier onlyChainAdmin(uint256 _chainId) {
        if (msg.sender != chainTypeManager.getChainAdmin(_chainId)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    function initialize(address _admin, address _chainTypeManager) public reentrancyGuardInitializer {
        chainTypeManager = IChainTypeManager(_chainTypeManager);
        if (_admin == address(0)) {
            revert ZeroAddress();
        }

        _transferOwnership(_admin);
    }

    function migrateToGateway(uint256 _chainId) external onlyChainAdmin(_chainId) {
        emit MigrateToGateway(_chainId);
    }

    function migrateFromGateway(uint256 _chainId) external onlyChainAdmin(_chainId) {
        emit MigrateFromGateway(_chainId);
    }
}
