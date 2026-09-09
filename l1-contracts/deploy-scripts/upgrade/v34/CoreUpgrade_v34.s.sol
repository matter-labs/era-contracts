// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

import {Call} from "contracts/governance/Common.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {ICoreRegistry} from "contracts/upgrades/registry/objects/ICoreRegistry.sol";

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";
import {ExternalActionsLib} from "../default-upgrade/ExternalActionsLib.sol";
import {BytecodeUtils} from "../../utils/bytecode/BytecodeUtils.s.sol";

/// @notice Core (ecosystem) side of the v34 upgrade: deploys the new shared-singleton
///         implementation set, pins it in a write-once `CoreRegistry` (the enum-indexed
///         inventory — one slot per `L1EcosystemContract` member, inert slots explicit), and
///         hands the ecosystem `ProxyAdmin` to the bound `EcosystemUpgradeExecutor`. Stage 1
///         carries TWO ecosystem calls — the ProxyAdmin handover and `applyL1Upgrade(registry)`
///         — instead of one raw `ProxyAdmin.upgrade` per proxy; the rows are source-checked
///         edges, so a replay can never downgrade a proxy a later upgrade has moved on.
contract CoreUpgrade_v34 is DefaultCoreUpgrade {
    /// @notice The bound executor the ecosystem `ProxyAdmin` lands under. Deployed by this
    ///         prepare run.
    EcosystemUpgradeExecutor public ecosystemUpgradeExecutor;

    /// @notice Deploy the v34 ecosystem-wide implementation set (implementations only).
    function deployNewEcosystemContractsL1() public virtual override {
        // Defensive: on ecosystems whose discovery misses the ChainRegistrationSender proxy
        // (see the v32 script for the introspection edge case), read it from the bridgehub so
        // the force-deployments data carries the correct aliased sender.
        if (coreAddresses.bridgehub.proxies.chainRegistrationSender == address(0)) {
            coreAddresses.bridgehub.proxies.chainRegistrationSender = IBridgehubBase(
                coreAddresses.bridgehub.proxies.bridgehub
            ).chainRegistrationSender();
        }

        coreAddresses.bridgehub.implementations.bridgehub = deploySimpleContract("L1Bridgehub");
        coreAddresses.bridgehub.implementations.messageRoot = deploySimpleContract("L1MessageRoot");
        coreAddresses.bridges.implementations.l1Nullifier = deploySimpleContract("L1Nullifier");
        coreAddresses.bridges.implementations.l1AssetRouter = deploySimpleContract("L1AssetRouter");
        coreAddresses.bridges.implementations.l1NativeTokenVault = deploySimpleContract("L1NativeTokenVault");
        coreAddresses.bridgehub.implementations.ctmDeploymentTracker = deploySimpleContract("CTMDeploymentTracker");
        coreAddresses.bridgehub.implementations.chainAssetHandler = deploySimpleContract("L1ChainAssetHandler");
        coreAddresses.bridgehub.implementations.chainRegistrationSender = deploySimpleContract(
            "ChainRegistrationSender"
        );
    }

    /// @notice The ecosystem executor this run deployed — the CTM prepare binds its executor to it.
    function getEcosystemUpgradeExecutor() public view virtual override returns (address) {
        return address(ecosystemUpgradeExecutor);
    }

    /// @notice The bootstrap edge deploys the registry AND the bound executor that will apply it
    ///         (a recurring prepare finds the executor live), then declares every governance call
    ///         of its one-time ecosystem leg.
    /// @dev Both ride the CREATE2 factory: the Safe bundle replays factory transactions only, so
    ///      a plain CREATE would leave the stage-1 calls pointing at codeless addresses.
    function deployEcosystemUpgradeObjects() public virtual override {
        deployCoreRegistry();
        require(address(coreRegistry) != address(0), "v34 deploys every ecosystem implementation");
        ecosystemUpgradeExecutor = EcosystemUpgradeExecutor(
            payable(
                deployViaCreate2AndNotify(
                    type(EcosystemUpgradeExecutor).creationCode,
                    abi.encode(
                        getOwnerAddress(),
                        ProxyAdmin(coreAddresses.shared.transparentProxyAdmin),
                        // The audited-object anchor for every registry this executor accepts,
                        // taken from the artifact those registries are DEPLOYED from (see
                        // {BytecodeUtils.getDeployedBytecodeHash}).
                        BytecodeUtils.getDeployedBytecodeHash("CoreRegistry.sol", "CoreRegistry")
                    ),
                    "EcosystemUpgradeExecutor"
                )
            )
        );
        _declareBootstrapActions();
    }

    /// @notice Every governance call of the bootstrap edge's ecosystem leg, declared as the
    ///         external action it is: this edge predates the transition lifecycle, so governance
    ///         itself pauses, hands the ecosystem `ProxyAdmin` to the bound executor, applies the
    ///         pinned inventory through it, gates on the executor's post-state check and unpauses.
    ///         Every later upgrade gets all of this from `CTMUpgradeExecutor.stage0/1/2`.
    function _declareBootstrapActions() internal virtual {
        address chainAssetHandler = coreAddresses.bridgehub.proxies.chainAssetHandler;
        require(chainAssetHandler != address(0), "chainAssetHandlerProxy is zero");
        string memory cahOwner = "ChainAssetHandler owner (governance)";
        Call memory pause = Call({
            target: chainAssetHandler,
            value: 0,
            data: abi.encodeCall(IChainAssetHandlerBase.pauseMigration, ())
        });
        declareExternalAction(
            ExternalActionsLib.PHASE_STAGE_0,
            "pause chain migrations for the upgrade",
            cahOwner,
            pause
        );
        // Re-asserted first in stage 1: the emergency-upgrade path's built-in pre-step unpauses,
        // and the CTM's version commit refuses to run while migrations are unpaused.
        declareExternalAction(ExternalActionsLib.PHASE_STAGE_1, "re-assert the migration pause", cahOwner, pause);
        declareExternalAction(
            ExternalActionsLib.PHASE_STAGE_1,
            "hand the ecosystem ProxyAdmin to the bound ecosystem executor",
            "ecosystem ProxyAdmin owner (governance)",
            Call({
                target: coreAddresses.shared.transparentProxyAdmin,
                value: 0,
                data: abi.encodeCall(Ownable.transferOwnership, (address(ecosystemUpgradeExecutor)))
            })
        );
        declareExternalAction(
            ExternalActionsLib.PHASE_STAGE_1,
            "apply the pinned ecosystem inventory (applyL1Upgrade)",
            "ecosystem executor owner (governance)",
            Call({
                target: address(ecosystemUpgradeExecutor),
                value: 0,
                data: abi.encodeCall(EcosystemUpgradeExecutor.applyL1Upgrade, (ICoreRegistry(address(coreRegistry))))
            })
        );
        declareExternalAction(
            ExternalActionsLib.PHASE_STAGE_2,
            "ecosystem post-state gate (validateUpgradeApplied)",
            "any (view)",
            Call({
                target: address(ecosystemUpgradeExecutor),
                value: 0,
                data: abi.encodeCall(
                    EcosystemUpgradeExecutor.validateUpgradeApplied,
                    (ICoreRegistry(address(coreRegistry)))
                )
            })
        );
        declareExternalAction(
            ExternalActionsLib.PHASE_STAGE_2,
            "unpause chain migrations",
            cahOwner,
            Call({
                target: chainAssetHandler,
                value: 0,
                data: abi.encodeCall(IChainAssetHandlerBase.unpauseMigration, ())
            })
        );
    }

    /// @notice Override to properly set deployerAddress in upgrade context.
    /// @dev In Forge scripts with vm.broadcast(), msg.sender is the script address, but the
    ///      actual deployer is the broadcast key — same fix as every upgrade script needs.
    function initializeL1CoreUtilsConfig() internal override {
        super.initializeL1CoreUtilsConfig();
        config.deployerAddress = getBroadcasterAddress();
        console.log("Overriding deployerAddress in upgrade context:", config.deployerAddress);
    }
}
