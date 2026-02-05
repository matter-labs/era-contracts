// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/**
 * @author Matter Labs
 * @notice MessageRoot contract is responsible for storing and aggregating the roots of the batches from different chains into the MessageRoot.
 * @custom:security-contact security@matterlabs.dev
 */
<<<<<<<< HEAD:l1-contracts/contracts/core/bridgehub/IMessageRootBase.sol
interface IMessageRootBase {
    function BRIDGE_HUB() external view returns (address);
========
interface IL1MessageRoot {
    function v31UpgradeChainBatchNumber(uint256 _chainId) external view returns (uint256);
>>>>>>>> 64583bba54970221dbae654dfe26f60b8a107626:l1-contracts/contracts/core/message-root/IL1MessageRoot.sol

    function saveV31UpgradeChainBatchNumber(uint256 _chainId) external;
}
