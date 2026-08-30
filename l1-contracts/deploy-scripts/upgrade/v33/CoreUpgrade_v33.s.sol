// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {L1InteropHandler} from "contracts/interop/interop-handler/L1InteropHandler.sol";

import {Call} from "contracts/governance/Common.sol";

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";

/// @notice Core (ecosystem-wide) half of the v33 upgrade flow. CTM-side deploys live in
///         `CTMUpgrade_v33`; the per-chain diamond cut is driven by `AdminFunctions.s.sol`.
///
/// @dev Everything generic lives in {DefaultCoreUpgrade}: the `noGovernancePrepare` entry point, the
///      refresh of all L1 core implementations, and the stage-1 `ProxyAdmin.upgrade` calls that point
///      the core proxies at them. This file holds only what is genuinely new in v33 —
///      `L1InteropHandler`, which has no proxy on an older ecosystem.
contract CoreUpgrade_v33 is Script, DefaultCoreUpgrade {
    /// @notice Whether this run deployed the `L1InteropHandler` proxy, i.e. the ecosystem did not
    ///         already have one and the bridges still have to be pointed at it.
    bool internal deployedL1InteropHandler;

    /// @notice Deploy the interop handler when the ecosystem predates it.
    /// @dev Its proxy is initialized straight to the governance address rather than to the deployer:
    ///      `L1InteropHandler.initialize` sets the owner outright (`_transferOwnership`), so there is
    ///      no pending-owner step to complete and no ownership hand-off to broadcast separately.
    ///      `Create2AndTransfer` does not fit here — it transfers from the CREATE2 deployer, which
    ///      only owns contracts that take ownership in their constructor (as `ProxyAdmin` does), not
    ///      a transparent proxy whose owner comes from an `initialize` call.
    function deployVersionSpecificEcosystemContractsL1() public virtual override {
        if (coreAddresses.bridges.proxies.l1InteropHandler != address(0)) {
            // Already on a release that has it: refresh the implementation like any other core
            // contract and let the default stage-1 proxy upgrade point at it.
            coreAddresses.bridges.implementations.l1InteropHandler = deploySimpleContract("L1InteropHandler", false);
            return;
        }

        address implementation = deployViaCreate2AndNotify(
            getCreationCode("L1InteropHandler", false),
            getCreationCalldata("L1InteropHandler", false),
            "L1InteropHandler",
            "L1InteropHandler Implementation",
            false
        );
        address proxy = deployViaCreate2AndNotify(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(
                implementation,
                transparentProxyAdmin(),
                abi.encodeCall(L1InteropHandler.initialize, (getOwnerAddress()))
            ),
            "TransparentUpgradeableProxy",
            "L1InteropHandler Proxy",
            false
        );

        coreAddresses.bridges.implementations.l1InteropHandler = implementation;
        coreAddresses.bridges.proxies.l1InteropHandler = proxy;
        deployedL1InteropHandler = true;
    }

    /// @notice Stage-1 calls that wire a freshly deployed `L1InteropHandler` into the bridges.
    /// @dev Empty when the ecosystem already had a handler, so the same script serves an upgrade and
    ///      a re-run: both setters are one-shot and would revert on a replay.
    function prepareVersionSpecificStage1GovernanceCallsL1() public virtual override returns (Call[] memory calls) {
        // Checked before the early return below: a zero address here means discovery failed to report
        // the handler, which is a broken run whether or not this script deployed it.
        address l1InteropHandlerProxy = coreAddresses.bridges.proxies.l1InteropHandler;
        require(l1InteropHandlerProxy != address(0), "L1InteropHandler proxy not deployed");

        if (!deployedL1InteropHandler) {
            return calls;
        }

        console.log("Wiring the freshly deployed L1InteropHandler:", l1InteropHandlerProxy);
        calls = new Call[](2);
        calls[0] = Call({
            target: coreAddresses.bridges.proxies.l1Nullifier,
            value: 0,
            data: abi.encodeCall(IL1Nullifier.setL1InteropHandler, (l1InteropHandlerProxy))
        });
        calls[1] = Call({
            target: coreAddresses.bridges.proxies.l1AssetRouter,
            value: 0,
            data: abi.encodeCall(IL1AssetRouter.setL1InteropHandler, (l1InteropHandlerProxy))
        });
    }
}
