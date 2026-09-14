// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {L2CanonicalTransaction} from "../../../common/Messaging.sol";
import {BootstrapManifest, L2UpgradePlan} from "../RegistryTypes.sol";

/// @notice The read surface of `RegistryBootstrapMigration`: what the bootstrap engine reads at
///         execution ({IBootstrapUpgrade.upgradeFromBootstrap}) and what tooling reads to relay
///         the edge's L2 leg.
interface IRegistryBootstrapMigration {
    /// @notice The whole manifest, exactly as it was pinned.
    function getManifest() external view returns (BootstrapManifest memory);

    /// @notice The FINAL, executable L2 plan of the edge: the stored derived-plus-extra
    ///         deployments with the authored delegate leg and factory dependencies.
    function l2Plan() external view returns (L2UpgradePlan memory);

    /// @notice The L2 protocol upgrade transaction the edge commits on every chain BEFORE the
    ///         engine's per-chain substitution: composed from {l2Plan}, the genesis release and the
    ///         version edge for the ecosystem the CTM belongs to, by the same composer transitions
    ///         use. All-zero (`txType == 0`) for an L1-only edge.
    function l2UpgradeTx() external view returns (L2CanonicalTransaction memory);

    /// @notice The diamond cut this edge commits — no facet cuts, the pinned engine's
    ///         `upgradeFromBootstrap(this)` init. Chains crossing the edge take exactly these bytes
    ///         by hand.
    function upgradeCut() external view returns (Diamond.DiamondCutData memory);
}
