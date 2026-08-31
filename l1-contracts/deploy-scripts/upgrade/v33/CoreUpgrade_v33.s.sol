// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {L1InteropHandler} from "contracts/interop/interop-handler/L1InteropHandler.sol";

import {Call} from "contracts/governance/Common.sol";

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";
import {DeployL1CoreUtils} from "../../ecosystem/DeployL1CoreUtils.s.sol";

/// @notice Core (ecosystem-wide) half of the v33 upgrade flow. CTM-side deploys live in
///         `CTMUpgrade_v33`; the per-chain diamond cut is driven by `AdminFunctions.s.sol`.
///
/// @dev Everything generic lives in {DefaultCoreUpgrade}: the `noGovernancePrepare` entry point, the
///      refresh of all L1 core implementations, the stage-1 `ProxyAdmin.upgrade` calls that point the
///      core proxies at them, and `stage3`'s `bridgedOut` population. This file holds only what is
///      genuinely new in v33 — `L1InteropHandler`, which has no proxy on an older ecosystem.
contract CoreUpgrade_v33 is Script, DefaultCoreUpgrade {
    /// @notice Deploy the interop handler, which this release introduces.
    /// @dev No "already deployed?" branch: v33 upgrades a v31 ecosystem, which by definition has no
    ///      handler. If one is found, discovery or the target ecosystem is not what this script
    ///      expects, and guessing is worse than stopping.
    /// @dev Ownership: the proxy is initialized straight to governance via the
    ///      {getInitializeCalldata} override below, rather than to the deployer followed by a
    ///      transfer. `L1InteropHandler.initialize` sets the owner outright (`_transferOwnership`),
    ///      so there is no pending-owner step and nothing to accept in stage 1.
    ///      `Create2AndTransfer` does not apply here — it transfers from the CREATE2 deployer, which
    ///      only owns contracts that take ownership in their constructor (as `ProxyAdmin` does), not
    ///      a transparent proxy whose owner comes from an `initialize` call.
    function deployVersionSpecificEcosystemContractsL1() public virtual override {
        require(
            coreAddresses.bridges.proxies.l1InteropHandler == address(0),
            "L1InteropHandler already exists; this release is the one that introduces it"
        );

        (
            coreAddresses.bridges.implementations.l1InteropHandler,
            coreAddresses.bridges.proxies.l1InteropHandler
        ) = deployTuppWithContract("L1InteropHandler", false);
    }

    /// @inheritdoc DeployL1CoreUtils
    /// @dev Hands the interop handler straight to governance; see {deployVersionSpecificEcosystemContractsL1}.
    ///      Every other contract keeps the shared deployment behaviour.
    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override returns (bytes memory) {
        if (keccak256(bytes(contractName)) == keccak256(bytes("L1InteropHandler"))) {
            return abi.encodeCall(L1InteropHandler.initialize, (getOwnerAddress()));
        }
        return super.getInitializeCalldata(contractName, isZKBytecode);
    }

    /// @notice Stage-1 calls that wire a freshly deployed `L1InteropHandler` into the bridges.
    /// @dev Both setters are one-shot, which is consistent with the deploy step refusing to run
    ///      against an ecosystem that already has a handler.
    function prepareVersionSpecificStage1GovernanceCallsL1() public virtual override returns (Call[] memory calls) {
        address l1InteropHandlerProxy = coreAddresses.bridges.proxies.l1InteropHandler;
        require(l1InteropHandlerProxy != address(0), "L1InteropHandler proxy not deployed");

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
