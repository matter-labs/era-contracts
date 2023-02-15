// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @author Matter Labs
 * @notice Contract that stores some of the context variables, that may be either
 * block-scoped, tx-scoped or system-wide.
 */
interface ISystemContext {
    function chainId() external view returns (uint256);

    function origin() external view returns (address);

    function gasPrice() external view returns (uint256);

    function blockGasLimit() external view returns (uint256);

    function coinbase() external view returns (address);

    function difficulty() external view returns (uint256);

    function baseFee() external view returns (uint256);

    function blockHash(uint256 _block) external view returns (bytes32);

    function getBlockHashEVM(uint256 _block) external view returns (bytes32);

    function getBlockNumberAndTimestamp() external view returns (uint256 blockNumber, uint256 blockTimestamp);

    // Note, that for now, the implementation of the bootloader allows this variables to
    // be incremented multiple times inside a block, so it should not relied upon right now.
    function getBlockNumber() external view returns (uint256);

    function getBlockTimestamp() external view returns (uint256);
}
