// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

interface IDeployPaymaster {
    function run(address _bridgehub, uint256 _chainId) external;
}
