// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ZeroAddress} from "../common/L1ContractErrors.sol";

contract ServerNotifier is Ownable2Step {
    mapping(address chainAdmin => uint256 chainId) public registeredChains;

    event MigrateToGateway(uint256 chainId);

    function initialize(address _admin) public {
        if (_admin == address(0)) {
            revert ZeroAddress();
        }

        _transferOwnership(_admin);
    }

    function addChain(address _chainAdmin, uint256 _chainId) public onlyOwner {
        registeredChains[_chainAdmin] = _chainId;
    }

    function removeChainAdmin() public {
        registeredChains[msg.sender] = 0;
    }

    function removeChainAdmin(address _chainAdmin) public onlyOwner {
        registeredChains[_chainAdmin] = 0;
    }

    function migrateToGateway() public {
        uint256 chainId = registeredChains[msg.sender];
        emit MigrateToGateway(chainId);
    }
}
