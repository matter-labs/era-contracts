// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IBridgehubBase} from "./IBridgehubBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Interface for L2-specific Bridgehub functionality
interface IL2Bridgehub is IBridgehubBase {}
