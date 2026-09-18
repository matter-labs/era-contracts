// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

// This file has no runtime purpose. It exists so that a targeted
// `forge build contracts/dev-contracts/TransparentUpgradeableProxyForHarness.sol`
// also compiles `TransparentUpgradeableProxy`, placing its artifact into
// forge `out/` where the Anvil multichain harness loads the
// `ITransparentUpgradeableProxy` ABI to drive the real proxy-admin upgrade
// when installing `L1ChainAssetHandlerDev`.
// See `test/anvil-interop/build-dev-artifacts.sh`.
// Both names are imported only so the compiler emits their artifacts; neither is referenced in code.
// This is load-bearing here, unlike in deploy-scripts: the harness runs a TARGETED
// `forge build <this file>`, which compiles only this file's dependency closure rather
// than all of `src`. A block disable is needed because the rule reports per imported name.
// solhint-disable no-unused-import
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
// solhint-enable no-unused-import
