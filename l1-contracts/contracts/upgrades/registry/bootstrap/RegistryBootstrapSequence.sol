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
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {CTMContract} from "../libraries/ContractIdentifiers.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {ICoreTransition} from "../objects/ICoreTransition.sol";
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
///      this contract executes is the read-only completion check, run as its own call after
///      stage 2.
/// @dev Everything but the two objects is derived: the manifest names the CTM, its `ProxyAdmin`,
///      both domain executors, the coordinator and the timer, the core executor names the
///      ecosystem `ProxyAdmin`, and the CTM names the chain asset handler through its Bridgehub. Derivation is at read time, so a sequence read against a drifted ecosystem
///      answers with the drift rather than a stale snapshot of it.
contract RegistryBootstrapSequence is IRegistryBootstrapSequence {
    using ObjectAnchorLib for address;

    string private constant CAH_OWNER = "ChainAssetHandler owner (governance)";
    string private constant CTM_GOVERNANCE = "protocol governance (CTM owner)";
    string private constant CORE_EXECUTOR_OWNER = "core executor owner (governance)";

    /// @inheritdoc IRegistryBootstrapSequence
    address public immutable override MIGRATION;

    /// @inheritdoc IRegistryBootstrapSequence
    address public immutable override CORE_TRANSITION;

    /// @param _migration The write-once edge object this sequence describes.
    /// @param _coreTransition The ecosystem inventory the edge's core leg applies.
    constructor(RegistryBootstrapMigration _migration, ICoreTransition _coreTransition) {
        if (address(_migration) == address(0) || address(_coreTransition) == address(0)) {
            revert ZeroAddress();
        }
        address(_migration).requireCode();
        MIGRATION = address(_migration);
        CORE_TRANSITION = address(_coreTransition);
        // The core transition is the one input the edge does not name, so the sequence pins it here:
        // stage 1 applies exactly this address, and a reviewer reads it off the derived calls.
        // Which transition that is remains governance's decision, established by review — see
        // "Provenance and validation" in {docs/registry-driven-upgrades.md}.
        address(_coreTransition).requireCode();
    }

    /// @inheritdoc IRegistryBootstrapSequence
    /// @dev Until the ServerNotifier is owned by the CTM executor, the first call completes the
    ///      one-time handover: the ChainAdmin has already moved the notifier under the CTM-domain
    ///      `ProxyAdmin` and nominated the executor (see {docs/upgrade-stage-lifecycle.md}), so the
    ///      stage reverts until that half is done.
    function stage0Actions() external view returns (BootstrapAction[] memory actions) {
        BootstrapManifest memory m = _manifest();
        address notifier = m.proxyUpgrades[uint256(CTMContract.ServerNotifier)].proxy;
        bool acceptNotifier = Ownable2Step(notifier).owner() != m.ctmExecutor;
        actions = new BootstrapAction[](acceptNotifier ? 3 : 2);
        uint256 next = 0;
        if (acceptNotifier) {
            Call[] memory accept = new Call[](1);
            accept[0] = Call({target: notifier, value: 0, data: abi.encodeCall(Ownable2Step.acceptOwnership, ())});
            actions[0] = BootstrapAction({
                label: "accept the ServerNotifier ownership the ChainAdmin nominated the CTM executor for",
                authority: "CTM executor owner (governance)",
                call: Call({
                    target: m.ctmExecutor,
                    value: 0,
                    data: abi.encodeCall(UpgradeExecutorBase.forward, (accept))
                })
            });
            next = 1;
        }
        actions[next] = _pauseAction(m.ctm, "pause chain migrations for the upgrade");
        actions[next + 1] = BootstrapAction({
            label: "start the pinned upgrade timer",
            authority: CTM_GOVERNANCE,
            call: Call({target: m.upgradeTimer, value: 0, data: abi.encodeCall(GovernanceUpgradeTimer.startTimer, ())})
        });
    }

    /// @inheritdoc IRegistryBootstrapSequence
    /// @dev The bindings come first: `migrate()` (last) refuses unless both domain executors and
    ///      the coordinator are bound to each other and the ecosystem `ProxyAdmin` has reached the
    ///      core executor, so every handover of this stage reverts with it otherwise.
    function stage1Actions() external view returns (BootstrapAction[] memory actions) {
        BootstrapManifest memory m = _manifest();
        CoreUpgradeExecutor coreExecutor = CoreUpgradeExecutor(payable(m.coreExecutor));
        actions = new BootstrapAction[](8);
        // The emergency-upgrade path's built-in pre-step unpauses, and the CTM's version commit
        // refuses to run while migrations are unpaused, so the pause is re-asserted here.
        actions[0] = _pauseAction(m.ctm, "re-assert the migration pause");
        actions[1] = BootstrapAction({
            label: "bind the core executor to the lifecycle coordinator",
            authority: CORE_EXECUTOR_OWNER,
            call: Call({
                target: address(coreExecutor),
                value: 0,
                data: abi.encodeCall(CoreUpgradeExecutor.setCoordinator, (m.coordinator))
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
            label: "hand the ecosystem ProxyAdmin to the bound core executor",
            authority: "ecosystem ProxyAdmin owner (governance)",
            call: Call({
                target: address(coreExecutor.PROXY_ADMIN()),
                value: 0,
                data: abi.encodeCall(Ownable.transferOwnership, (address(coreExecutor)))
            })
        });
        actions[4] = BootstrapAction({
            label: "apply the pinned ecosystem inventory (applyL1Upgrade)",
            authority: CORE_EXECUTOR_OWNER,
            call: Call({
                target: address(coreExecutor),
                value: 0,
                data: abi.encodeCall(CoreUpgradeExecutor.applyL1Upgrade, (ICoreTransition(CORE_TRANSITION)))
            })
        });
        actions[5] = BootstrapAction({
            label: "nominate the bootstrap migration as CTM owner",
            authority: CTM_GOVERNANCE,
            call: Call({target: m.ctm, value: 0, data: abi.encodeCall(Ownable2Step.transferOwnership, (MIGRATION))})
        });
        actions[6] = BootstrapAction({
            label: "hand the CTM-domain ProxyAdmin to the bootstrap migration",
            authority: "CTM-domain ProxyAdmin owner (governance)",
            call: Call({
                target: address(m.ctmProxyAdmin),
                value: 0,
                data: abi.encodeCall(Ownable.transferOwnership, (MIGRATION))
            })
        });
        actions[7] = BootstrapAction({
            label: "run the bootstrap edge (migrate)",
            authority: "permissionless, state-gated (authorities held and bound, timer passed, pins hold)",
            call: Call({target: MIGRATION, value: 0, data: abi.encodeCall(RegistryBootstrapMigration.migrate, ())})
        });
    }

    /// @inheritdoc IRegistryBootstrapSequence
    function stage2Actions() external view returns (BootstrapAction[] memory actions) {
        BootstrapManifest memory m = _manifest();
        actions = new BootstrapAction[](1);
        actions[0] = BootstrapAction({
            label: "unpause chain migrations",
            authority: CAH_OWNER,
            call: Call({
                target: _chainAssetHandler(m.ctm),
                value: 0,
                data: abi.encodeCall(IChainAssetHandlerBase.unpauseMigration, ())
            })
        });
    }

    /// @inheritdoc IRegistryBootstrapSequence
    function validateApplied() external view {
        RegistryBootstrapMigration(MIGRATION).validateApplied();
    }

    function _manifest() private view returns (BootstrapManifest memory) {
        return RegistryBootstrapMigration(MIGRATION).getManifest();
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
