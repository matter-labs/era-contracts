// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

string constant NEW_PRIORITY_REQUEST_SIGNATURE = "NewPriorityRequest(uint256,bytes32,uint64,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes),bytes[])";
address constant RAND_ADDRESS = address(0xDEAD);

uint256 constant SERVER_NOTIFIER_OWNER_SLOT = 0;
uint256 constant SERVER_NOTIFIER_PENDING_OWNER_SLOT = 1;
uint256 constant SERVER_NOTIFIER_CHAIN_TYPE_MANAGER_SLOT = 2;
uint256 constant SERVER_NOTIFIER_UPGRADE_TIMESTAMP_SLOT = 3;
uint256 constant SERVER_NOTIFIER_PRECONDITION_CHECKER_SLOT = 4;
