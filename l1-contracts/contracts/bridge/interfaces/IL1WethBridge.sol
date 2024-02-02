// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./IL1Bridge.sol";
import "./IL1BridgeLegacy.sol";

import {ConfirmL2TxStatus} from "./IL1Bridge.sol";

/// @title L1 ERC20 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1WethBridge is IL1Bridge {
    function l1WethAddress() external view returns (address payable);

    function l2WethAddress(uint256 _chainId) external view returns (address);

    /// @dev Event emitted when ETH is received by the contract.
    event EthReceived(uint256 amount);

    /// @notice Emitted when the withdrawal is finalized on L1 and funds are released.
    /// @param to The address to which the funds were sent
    /// @param amount The amount of funds that were sent
    event EthWithdrawalFinalized(uint256 chainId, address indexed to, uint256 amount);
}
