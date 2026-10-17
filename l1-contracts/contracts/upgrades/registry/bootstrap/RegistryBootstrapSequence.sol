// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import {Call} from "../../../governance/Common.sol";
import {ProxyUpgradeDomainMismatch, ZeroAddress} from "../../../common/L1ContractErrors.sol";
import {CoreUpgradeExecutor} from "../executors/CoreUpgradeExecutor.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {CTMContract} from "../libraries/ContractIdentifiers.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {IProxyUpgradeTransition} from "../objects/IProxyUpgradeTransition.sol";
import {BootstrapManifest, ProxyUpgradeDomain} from "../RegistryTypes.sol";
import {BootstrapAction, IRegistryBootstrapSequence} from "./IRegistryBootstrapSequence.sol";
import {RegistryBootstrapMigration} from "./RegistryBootstrapMigration.sol";

/// @title RegistryBootstrapSequence
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Derives the bootstrap edge's complete governance bundle — both domains, ending in the
///         edge's completion check — from the two objects the edge already deploys. See the
///         Bootstrap section of {docs/registry-driven-upgrades.md}.
/// @dev DESCRIBES the bundle, it never executes it: every call runs on the authority of the
///      governance account that sends it, and `Governance` issues ordinary calls.
/// @dev Everything but the two objects is derived: the manifest names the CTM, its `ProxyAdmin` and
///      both domain executors, and the core executor names the ecosystem `ProxyAdmin`. Derivation is at read time, so a sequence read against a drifted ecosystem
///      answers with the drift rather than a stale snapshot of it.
contract RegistryBootstrapSequence is IRegistryBootstrapSequence {
    using ObjectAnchorLib for address;

    string private constant GOVERNANCE = "protocol governance";

    /// @inheritdoc IRegistryBootstrapSequence
    address public immutable override MIGRATION;

    /// @inheritdoc IRegistryBootstrapSequence
    address public immutable override CORE_TRANSITION;

    /// @param _migration The write-once edge object this sequence describes.
    /// @param _coreTransition The Core-domain transition the edge's core leg applies.
    constructor(RegistryBootstrapMigration _migration, IProxyUpgradeTransition _coreTransition) {
        if (address(_migration) == address(0) || address(_coreTransition) == address(0)) {
            revert ZeroAddress();
        }
        address(_migration).requireCode();
        MIGRATION = address(_migration);
        CORE_TRANSITION = address(_coreTransition);
        // The core transition is the one input the edge does not name, so the sequence pins it here:
        // the bundle applies exactly this address, and a reviewer reads it off the derived calls.
        // Which transition that is remains governance's decision, established by review — see
        // "Provenance and validation" in {docs/registry-driven-upgrades.md}.
        address(_coreTransition).requireCode();
        ProxyUpgradeDomain transitionDomain = _coreTransition.domain();
        if (transitionDomain != ProxyUpgradeDomain.Core) {
            revert ProxyUpgradeDomainMismatch(uint8(ProxyUpgradeDomain.Core), uint8(transitionDomain));
        }
    }

    /// @inheritdoc IRegistryBootstrapSequence
    /// @dev Until the ServerNotifier is owned by the CTM executor, the first call completes the
    ///      one-time handover: the ChainAdmin has already moved the notifier under the CTM-domain
    ///      `ProxyAdmin` and nominated the executor (see {docs/upgrade-operations.md}), so the
    ///      bundle reverts until that half is done. The ecosystem `ProxyAdmin` handover comes before
    ///      `migrate()`, which refuses unless it has reached the core executor.
    function actions() external view returns (BootstrapAction[] memory actions_) {
        BootstrapManifest memory m = RegistryBootstrapMigration(MIGRATION).getManifest();
        CoreUpgradeExecutor coreExecutor = CoreUpgradeExecutor(payable(m.coreExecutor));
        address notifier = m.ctmProxyUpgrades[uint256(CTMContract.ServerNotifier)].proxy;
        bool acceptNotifier = Ownable2Step(notifier).owner() != m.ctmExecutor;
        uint256 offset = acceptNotifier ? 1 : 0;
        actions_ = new BootstrapAction[](offset + 6);
        if (acceptNotifier) {
            Call[] memory accept = new Call[](1);
            accept[0] = Call({target: notifier, value: 0, data: abi.encodeCall(Ownable2Step.acceptOwnership, ())});
            actions_[0] = BootstrapAction({
                label: "accept the ServerNotifier ownership the ChainAdmin nominated the CTM executor for",
                authority: "CTM executor owner (governance)",
                call: Call({
                    target: m.ctmExecutor,
                    value: 0,
                    data: abi.encodeCall(UpgradeExecutorBase.forward, (accept))
                })
            });
        }
        actions_[offset] = BootstrapAction({
            label: "hand the ecosystem ProxyAdmin to the bound core executor",
            authority: "ecosystem ProxyAdmin owner (governance)",
            call: Call({
                target: address(coreExecutor.PROXY_ADMIN()),
                value: 0,
                data: abi.encodeCall(Ownable.transferOwnership, (address(coreExecutor)))
            })
        });
        actions_[offset + 1] = BootstrapAction({
            label: "apply the pinned ecosystem inventory (applyL1Upgrade)",
            authority: "core executor owner (governance)",
            call: Call({
                target: address(coreExecutor),
                value: 0,
                data: abi.encodeCall(CoreUpgradeExecutor.applyL1Upgrade, (IProxyUpgradeTransition(CORE_TRANSITION)))
            })
        });
        actions_[offset + 2] = BootstrapAction({
            label: "nominate the bootstrap migration as CTM owner",
            authority: GOVERNANCE,
            call: Call({target: m.ctm, value: 0, data: abi.encodeCall(Ownable2Step.transferOwnership, (MIGRATION))})
        });
        actions_[offset + 3] = BootstrapAction({
            label: "hand the CTM-domain ProxyAdmin to the bootstrap migration",
            authority: "CTM-domain ProxyAdmin owner (governance)",
            call: Call({
                target: address(m.ctmProxyAdmin),
                value: 0,
                data: abi.encodeCall(Ownable.transferOwnership, (MIGRATION))
            })
        });
        actions_[offset + 4] = BootstrapAction({
            label: "run the bootstrap edge (migrate)",
            authority: "permissionless, state-gated (authorities held and bound, pins hold)",
            call: Call({target: MIGRATION, value: 0, data: abi.encodeCall(RegistryBootstrapMigration.migrate, ())})
        });
        actions_[offset + 5] = BootstrapAction({
            label: "check the edge completed (validateApplied)",
            authority: "anyone (read-only)",
            call: Call({
                target: MIGRATION,
                value: 0,
                data: abi.encodeCall(RegistryBootstrapMigration.validateApplied, ())
            })
        });
    }
}
