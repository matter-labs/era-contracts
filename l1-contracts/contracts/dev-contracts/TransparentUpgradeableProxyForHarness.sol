// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

// This file has no runtime purpose. It exists so that a targeted
// `forge build contracts/dev-contracts/TransparentUpgradeableProxyForHarness.sol`
// also compiles `TransparentUpgradeableProxy`, placing its artifact into
// forge `out/` where the Anvil multichain harness loads the
// `ITransparentUpgradeableProxy` ABI to drive the real proxy-admin upgrade
// when installing `L1ChainAssetHandlerDev`.
// See `test/anvil-interop/build-dev-artifacts.sh`.
// solhint-disable no-unused-import
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
// solhint-enable no-unused-import
