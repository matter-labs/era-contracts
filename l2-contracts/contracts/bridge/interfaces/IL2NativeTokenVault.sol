// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {INativeTokenVault} from "l1-contracts-imported/contracts/bridge/interfaces/INativeTokenVault.sol";

/// @author Matter Labs
interface IL2NativeTokenVault is INativeTokenVault {
    function l2TokenAddress(address _l1Token) external view returns (address);
}
