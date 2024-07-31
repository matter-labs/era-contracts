// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IMessageRoot {
    function clearTreeAndProvidePubdata() external returns (bytes memory pubdata);
    function getAggregatedRoot() external view returns (bytes32 aggregatedRoot);
}
