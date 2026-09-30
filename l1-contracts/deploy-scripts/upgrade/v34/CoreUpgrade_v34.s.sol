// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";

/// @notice Prepares the shared ecosystem contracts for v34. See {protocol-docs/chain-config.md}.
// solhint-disable-next-line contract-name-capwords
contract CoreUpgrade_v34 is DefaultCoreUpgrade {}
