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
}
