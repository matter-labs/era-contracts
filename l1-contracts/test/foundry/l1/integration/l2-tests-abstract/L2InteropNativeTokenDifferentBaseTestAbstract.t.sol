// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {IBridgedStandardToken} from "contracts/bridge/interfaces/IBridgedStandardToken.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

import {
    L2_ASSET_ROUTER_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_INTEROP_CENTER,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";

import {BundleExecutionResult, L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";

abstract contract L2InteropNativeTokenDifferentBaseTestAbstract is L2InteropTestUtils {}
