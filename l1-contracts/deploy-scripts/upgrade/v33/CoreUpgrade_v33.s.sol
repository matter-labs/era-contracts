// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {Call} from "contracts/governance/Common.sol";

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";
import {ICoreUpgradeV33} from "contracts/script-interfaces/IUpgradeV33.sol";
import {UpgradeUtils} from "../default-upgrade/UpgradeUtils.sol";
import {CoreUpgradeParams} from "../default-upgrade/UpgradeParams.sol";

/// @notice Core (ecosystem-wide) half of the v33 upgrade flow. CTM-side deploys live in
///         `CTMUpgrade_v33`; the per-chain diamond cut is driven by `AdminFunctions.s.sol`.
///
/// @dev Deliberately extends {DefaultCoreUpgrade} rather than `CoreUpgrade_v31`. The v31 script
///      carries one-time v30 -> v31 migration work that must not run again on a v33 upgrade:
///        - stage 2's legacy-Gateway decommission (historical migration intervals + old-GW
///          blacklist, read from `[legacy_gateway]`), and
///        - `stage3`'s bridged-token registration in the NTV plus `bridgedOut` population.
///      Both were completed by the v31 upgrade itself. Re-running them against a v31 ecosystem
///      would at best no-op and at worst target live chains, so this release simply does not
///      expose them: there is no stage-2 override here and no `stage3` entry point.
///
/// @dev What the default already does, so this script does not: {prepareUpgradeProxiesCalls}
///      builds the stage-1 `ProxyAdmin.upgrade` calls for the seven core proxies (bridgehub,
///      nullifier, asset router, native token vault, message root, CTM deployment tracker,
///      chain asset handler). It builds them from `coreAddresses.*.implementations.*` though,
///      and `DefaultCoreUpgrade.deployNewEcosystemContractsL1` is an empty body — so on the bare
///      default those seven calls would point every proxy at `address(0)`. The deploy override
///      below is what gives them something to point at.
///
/// @dev What this script therefore supplies:
///        - the deployment of those seven core implementations,
///        - a refreshed `ChainRegistrationSender` implementation *and* its proxy upgrade, which
///          is not one of the default seven, and
///        - `L1InteropHandler`, which is new in this release: a pre-v33 ecosystem has no proxy
///          for it, so one is deployed and wired into the bridges in stage 1.
contract CoreUpgrade_v33 is Script, DefaultCoreUpgrade, ICoreUpgradeV33 {
    /// @notice Whether this run deployed the `L1InteropHandler` proxy, i.e. the ecosystem did not
    ///         already have one. Its ownership then has to be handed to governance and its address
    ///         wired into the bridges.
    bool internal deployedL1InteropHandler;

    /// @notice Single-call entry point invoked by the protocol-ops CLI.
    ///         Runs the ecosystem-wide core deploys; CTM deploys are handled by `CTMUpgrade_v33`.
    function noGovernancePrepare(CoreUpgradeParams memory _params) public {
        initializeWithArgs(
            _params.bridgehubProxyAddress,
            _params.isZKsyncOS,
            _params.create2FactorySalt,
            _params.upgradeInputPath,
            _params.outputPath
        );
        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();
    }

    function deployNewEcosystemContractsL1() public virtual override {
        deployNewEcosystemContractsL1NoConnections();
        updateContractConnections();
    }

    /// @notice Deploy contracts only (no side effects like setAddresses / transferOwnership).
    /// @dev Used by the test harness for idempotent re-runs where connections are already set up.
    function deployNewEcosystemContractsL1NoConnections() public virtual {
        coreAddresses.bridgehub.implementations.bridgehub = deploySimpleContract("L1Bridgehub", false);
        coreAddresses.bridgehub.implementations.messageRoot = deploySimpleContract("L1MessageRoot", false);
        coreAddresses.bridges.implementations.l1Nullifier = deploySimpleContract("L1Nullifier", false);
        coreAddresses.bridges.implementations.l1AssetRouter = deploySimpleContract("L1AssetRouter", false);
        coreAddresses.bridges.implementations.l1NativeTokenVault = deploySimpleContract("L1NativeTokenVault", false);
        coreAddresses.bridgehub.implementations.ctmDeploymentTracker = deploySimpleContract(
            "CTMDeploymentTracker",
            false
        );
        coreAddresses.bridgehub.implementations.chainAssetHandler = deploySimpleContract("L1ChainAssetHandler", false);

        // The sender exists since v31, and its proxy is kept: it holds the registration history, and the
        // bridgehub authorizes service transactions by that address. Only the implementation is refreshed
        // (its validation changed in this release), through the proxy upgrade in stage 1.
        require(
            coreAddresses.bridgehub.proxies.chainRegistrationSender != address(0),
            "Bridgehub has no ChainRegistrationSender registered; register it before this upgrade"
        );
        coreAddresses.bridgehub.implementations.chainRegistrationSender = deploySimpleContract(
            "ChainRegistrationSender",
            false
        );

        // The interop handler is new in this release: an ecosystem that predates it has no proxy, so deploy
        // one and let stage 1 wire it into the bridges. An ecosystem that already has one only gets a fresh
        // implementation, which keeps this script idempotent across re-runs.
        if (coreAddresses.bridges.proxies.l1InteropHandler == address(0)) {
            (
                coreAddresses.bridges.implementations.l1InteropHandler,
                coreAddresses.bridges.proxies.l1InteropHandler
            ) = deployTuppWithContract("L1InteropHandler", false);
            deployedL1InteropHandler = true;
        } else {
            coreAddresses.bridges.implementations.l1InteropHandler = deploySimpleContract("L1InteropHandler", false);
        }
    }

    /// @notice Configure contract connections after deployment.
    function updateContractConnections() internal {
        address properOwner = getOwnerAddress();

        if (deployedL1InteropHandler) {
            console.log("Transferring L1InteropHandler ownership to governance:", properOwner);
            vm.broadcast(getBroadcasterAddress());
            Ownable2StepUpgradeable(coreAddresses.bridges.proxies.l1InteropHandler).transferOwnership(properOwner);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Override to properly set deployerAddress in upgrade context.
    /// @dev In Forge scripts with `vm.broadcast()`, `msg.sender` is the script address while
    ///      `tx.origin` is the address of the private key being used for broadcasts.
    function initializeL1CoreUtilsConfig() internal override {
        super.initializeL1CoreUtilsConfig();

        config.deployerAddress = getBroadcasterAddress();
        console.log("Overriding deployerAddress in upgrade context:");
        console.log("  msg.sender (script):", msg.sender);
        console.log("  actual deployer:", getBroadcasterAddress());
        console.log("  config.deployerAddress:", config.deployerAddress);
    }

    /// @notice Version-specific governance calls for stage 1.
    /// @dev Stage 1 runs after the proxy upgrades, so the new `L1ChainAssetHandler` implementation
    ///      is already in place when these calls execute.
    function prepareVersionSpecificStage1GovernanceCallsL1() public virtual override returns (Call[] memory calls) {
        console.log("Preparing v33-specific stage1 governance calls...");

        address chainAssetHandlerProxy = coreAddresses.bridgehub.proxies.chainAssetHandler;
        require(chainAssetHandlerProxy != address(0), "ChainAssetHandler proxy address not found");
        console.log("ChainAssetHandler address:", chainAssetHandlerProxy);

        Call[][] memory allCalls = new Call[][](2);

        allCalls[0] = new Call[](2);

        // Point the inherited ChainRegistrationSender proxy at the refreshed implementation.
        allCalls[0][0] = _buildCallProxyUpgrade(
            coreAddresses.bridgehub.proxies.chainRegistrationSender,
            coreAddresses.bridgehub.implementations.chainRegistrationSender
        );

        // Cache messageRoot/assetRouter inside the new ChainAssetHandler implementation
        // so its facets don't re-query bridgehub on every call.
        allCalls[0][1] = Call({
            target: chainAssetHandlerProxy,
            value: 0,
            data: abi.encodeCall(L1ChainAssetHandler.setAddresses, ())
        });

        allCalls[1] = _buildL1InteropHandlerWiringCalls();

        return UpgradeUtils.mergeCallsArray(allCalls);
    }

    /// @notice Stage-1 calls that wire a freshly deployed `L1InteropHandler` into the bridges.
    /// @dev Empty when the ecosystem already had a handler, so the same script serves an upgrade and a
    ///      re-run. Both setters are one-shot and only exist on the new implementations, hence stage 1
    ///      rather than the deploy step.
    function _buildL1InteropHandlerWiringCalls() internal virtual returns (Call[] memory calls) {
        // Checked before the early return below: a zero address here means discovery failed to report the
        // handler, which is a broken run whether or not this script deployed it.
        address l1InteropHandlerProxy = coreAddresses.bridges.proxies.l1InteropHandler;
        require(l1InteropHandlerProxy != address(0), "L1InteropHandler proxy not deployed");

        if (!deployedL1InteropHandler) {
            return calls;
        }

        console.log("Wiring the freshly deployed L1InteropHandler:", l1InteropHandlerProxy);
        calls = new Call[](3);
        calls[0] = Call({
            target: l1InteropHandlerProxy,
            value: 0,
            data: abi.encodeCall(Ownable2StepUpgradeable.acceptOwnership, ())
        });
        calls[1] = Call({
            target: coreAddresses.bridges.proxies.l1Nullifier,
            value: 0,
            data: abi.encodeCall(IL1Nullifier.setL1InteropHandler, (l1InteropHandlerProxy))
        });
        calls[2] = Call({
            target: coreAddresses.bridges.proxies.l1AssetRouter,
            value: 0,
            data: abi.encodeCall(IL1AssetRouter.setL1InteropHandler, (l1InteropHandlerProxy))
        });
    }
}
