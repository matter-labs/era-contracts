// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import {Call} from "../../../governance/Common.sol";
import {IBridgehubBase} from "../../../core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "../../../core/chain-asset-handler/IChainAssetHandler.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {ZeroAddress} from "../../../common/L1ContractErrors.sol";
import {GovernanceUpgradeTimer} from "../../GovernanceUpgradeTimer.sol";
import {CoreUpgradeExecutor} from "../executors/CoreUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "../executors/EcosystemUpgradeExecutor.sol";
import {ICTMUpgradeExecutor} from "../executors/ICTMUpgradeExecutor.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {ICoreRegistry} from "../objects/ICoreRegistry.sol";
import {BootstrapManifest} from "../RegistryTypes.sol";
import {BootstrapAction, IRegistryBootstrapSequence} from "./IRegistryBootstrapSequence.sol";
import {RegistryBootstrapMigration} from "./RegistryBootstrapMigration.sol";

/// @title RegistryBootstrapSequence
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Derives the bootstrap edge's complete governance call sequence — both domains, all
///         three stages — from the two objects the edge already deploys. See the Bootstrap
///         section of {docs/registry-driven-upgrades.md}.
/// @dev DESCRIBES the sequence, it never executes it: every call runs on the authority of the
///      governance account that sends it, and `Governance` issues ordinary calls. The one thing
///      this contract executes is the read-only completion gate that terminates stage 2.
/// @dev Everything but the two objects is derived: the coordinator names the core executor, that
///      executor names the ecosystem `ProxyAdmin`, the manifest names the CTM, its `ProxyAdmin`,
///      the bound CTM executor and the timer, and the CTM names the chain asset handler through
///      its Bridgehub. Derivation is at read time, so a sequence read against a drifted ecosystem
///      answers with the drift rather than a stale snapshot of it.
contract RegistryBootstrapSequence is IRegistryBootstrapSequence {
    using ObjectAnchorLib for address;

    string private constant CAH_OWNER = "ChainAssetHandler owner (governance)";
    string private constant CTM_GOVERNANCE = "protocol governance (CTM owner)";
    string private constant CORE_EXECUTOR_OWNER = "core executor owner (governance)";

    /// @inheritdoc IRegistryBootstrapSequence
    address public immutable override MIGRATION;

    /// @inheritdoc IRegistryBootstrapSequence
    address public immutable override CORE_REGISTRY;

    /// @param _migration The write-once edge object this sequence describes.
    /// @param _coreRegistry The ecosystem inventory the edge's core leg applies.
    constructor(RegistryBootstrapMigration _migration, ICoreRegistry _coreRegistry) {
        if (address(_migration) == address(0) || address(_coreRegistry) == address(0)) {
            revert ZeroAddress();
        }
        address(_migration).requireCode();
        MIGRATION = address(_migration);
        CORE_REGISTRY = address(_coreRegistry);
        // The registry is the one input the edge does not name, so the sequence pins it here:
        // stage 1 applies exactly this address, and a reviewer reads it off the derived calls.
        // Which registry that is remains governance's decision, established by review — see
        // "Provenance and validation" in {docs/registry-driven-upgrades.md}.
        address(_coreRegistry).requireCode();
    }

    /// @inheritdoc IRegistryBootstrapSequence
    function stage0Actions() external view returns (BootstrapAction[] memory actions) {
        BootstrapManifest memory m = _manifest();
        actions = new BootstrapAction[](2);
        actions[0] = _pauseAction(m.ctm, "pause chain migrations for the upgrade");
        actions[1] = BootstrapAction({
            label: "start the pinned upgrade timer",
            authority: CTM_GOVERNANCE,
            call: Call({target: m.upgradeTimer, value: 0, data: abi.encodeCall(GovernanceUpgradeTimer.startTimer, ())})
        });
    }

    /// @inheritdoc IRegistryBootstrapSequence
    function stage1Actions() external view returns (BootstrapAction[] memory actions) {
        BootstrapManifest memory m = _manifest();
        CoreUpgradeExecutor coreExecutor = _coreExecutor(m.coordinator);
        actions = new BootstrapAction[](6);
        // The emergency-upgrade path's built-in pre-step unpauses, and the CTM's version commit
        // refuses to run while migrations are unpaused, so the pause is re-asserted here.
        actions[0] = _pauseAction(m.ctm, "re-assert the migration pause");
        actions[1] = BootstrapAction({
            label: "hand the ecosystem ProxyAdmin to the bound core executor",
            authority: "ecosystem ProxyAdmin owner (governance)",
            call: Call({
                target: address(coreExecutor.PROXY_ADMIN()),
                value: 0,
                data: abi.encodeCall(Ownable.transferOwnership, (address(coreExecutor)))
            })
        });
        actions[2] = BootstrapAction({
            label: "apply the pinned ecosystem inventory (applyL1Upgrade)",
            authority: CORE_EXECUTOR_OWNER,
            call: Call({
                target: address(coreExecutor),
                value: 0,
                data: abi.encodeCall(CoreUpgradeExecutor.applyL1Upgrade, (ICoreRegistry(CORE_REGISTRY)))
            })
        });
        actions[3] = BootstrapAction({
            label: "nominate the bootstrap migration as CTM owner",
            authority: CTM_GOVERNANCE,
            call: Call({target: m.ctm, value: 0, data: abi.encodeCall(Ownable2Step.transferOwnership, (MIGRATION))})
        });
        actions[4] = BootstrapAction({
            label: "hand the CTM-domain ProxyAdmin to the bootstrap migration",
            authority: "CTM-domain ProxyAdmin owner (governance)",
            call: Call({
                target: address(m.ctmProxyAdmin),
                value: 0,
                data: abi.encodeCall(Ownable.transferOwnership, (MIGRATION))
            })
        });
        actions[5] = BootstrapAction({
            label: "run the bootstrap edge (migrate)",
            authority: "permissionless, state-gated (both authorities held, timer passed, pins hold)",
            call: Call({target: MIGRATION, value: 0, data: abi.encodeCall(RegistryBootstrapMigration.migrate, ())})
        });
    }

    /// @inheritdoc IRegistryBootstrapSequence
    function stage2Actions() external view returns (BootstrapAction[] memory actions) {
        BootstrapManifest memory m = _manifest();
        CoreUpgradeExecutor coreExecutor = _coreExecutor(m.coordinator);
        actions = new BootstrapAction[](4);
        actions[0] = BootstrapAction({
            label: "bind the core executor to the lifecycle coordinator",
            authority: CORE_EXECUTOR_OWNER,
            call: Call({
                target: address(coreExecutor),
                value: 0,
                data: abi.encodeCall(CoreUpgradeExecutor.setCoordinator, (m.coordinator))
            })
        });
        // Before the completion gate, which requires the CTM's migrations unpaused again.
        actions[1] = BootstrapAction({
            label: "unpause chain migrations",
            authority: CAH_OWNER,
            call: Call({
                target: _chainAssetHandler(m.ctm),
                value: 0,
                data: abi.encodeCall(IChainAssetHandlerBase.unpauseMigration, ())
            })
        });
        actions[2] = BootstrapAction({
            label: "bind the coordinator to the CTM executor",
            authority: "coordinator owner (governance)",
            call: Call({
                target: m.coordinator,
                value: 0,
                data: abi.encodeCall(EcosystemUpgradeExecutor.setCTMExecutor, (ICTMUpgradeExecutor(m.ctmExecutor)))
            })
        });
        actions[3] = BootstrapAction({
            label: "bootstrap completion gate (both domains applied)",
            authority: "any (view)",
            call: Call({
                target: address(this),
                value: 0,
                data: abi.encodeCall(IRegistryBootstrapSequence.validateApplied, ())
            })
        });
    }

    /// @inheritdoc IRegistryBootstrapSequence
    /// @dev Terminates every derived stage-2 sequence, so a bundle cannot complete the edge while
    ///      either domain is unapplied — and cannot drop half the assertion either, because both
    ///      halves ride one call.
    function validateApplied() external view {
        BootstrapManifest memory m = _manifest();
        _coreExecutor(m.coordinator).validateUpgradeApplied(ICoreRegistry(CORE_REGISTRY));
        RegistryBootstrapMigration(MIGRATION).validateApplied();
    }

    function _manifest() private view returns (BootstrapManifest memory) {
        return RegistryBootstrapMigration(MIGRATION).getManifest();
    }

    /// @param _coordinator The coordinator the edge's CTM executor answers to.
    function _coreExecutor(address _coordinator) private view returns (CoreUpgradeExecutor) {
        return EcosystemUpgradeExecutor(payable(_coordinator)).CORE_EXECUTOR();
    }

    /// @param _ctm The CTM the edge migrates.
    function _chainAssetHandler(address _ctm) private view returns (address) {
        return IBridgehubBase(IChainTypeManager(_ctm).BRIDGE_HUB()).chainAssetHandler();
    }

    /// @param _ctm The CTM the edge migrates.
    /// @param _label The runbook wording of this particular pause.
    function _pauseAction(address _ctm, string memory _label) private view returns (BootstrapAction memory) {
        return
            BootstrapAction({
                label: _label,
                authority: CAH_OWNER,
                call: Call({
                    target: _chainAssetHandler(_ctm),
                    value: 0,
                    data: abi.encodeCall(IChainAssetHandlerBase.pauseMigration, ())
                })
            });
    }
}
