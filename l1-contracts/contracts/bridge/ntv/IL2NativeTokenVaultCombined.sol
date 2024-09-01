// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {INativeTokenVault} from "./INativeTokenVault.sol";
import {IL2NativeTokenVault} from "./IL2NativeTokenVault.sol";

/// @title L1 Native token vault contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2NativeTokenVaultCombined is IL2NativeTokenVault, INativeTokenVault {}
