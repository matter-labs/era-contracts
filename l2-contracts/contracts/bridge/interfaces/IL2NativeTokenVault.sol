// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {INativeTokenVault} from "./INativeTokenVault.sol";

/// @author Matter Labs
interface IL2NativeTokenVault is INativeTokenVault {
    function l2TokenAddress(address _l1Token) external view returns (address);
}
