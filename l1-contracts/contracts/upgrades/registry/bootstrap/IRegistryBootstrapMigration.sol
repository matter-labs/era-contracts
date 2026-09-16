// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICommittedUpgrade} from "../objects/ICommittedUpgrade.sol";
import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {L2CanonicalTransaction} from "../../../common/Messaging.sol";
import {BootstrapManifest} from "../RegistryTypes.sol";

/// @notice The read surface of `RegistryBootstrapMigration`: what the bootstrap engine reads at
///         execution ({IBootstrapUpgrade.upgradeFromBootstrap}) and what tooling reads to relay
///         the edge's L2 leg.
interface IRegistryBootstrapMigration is ICommittedUpgrade {
    /// @notice Emitted once the ecosystem has crossed into the registry-driven model.
    event EcosystemBootstrapped(address indexed ctm, address indexed currentRelease, uint256 newProtocolVersion);

    /// @notice The whole manifest, exactly as it was pinned.
    function getManifest() external view returns (BootstrapManifest memory);

    /// @notice The L2 protocol upgrade transaction the edge commits on chain `_chainId` — the FINAL
    ///         transaction, exactly as the chain stores its hash: composed from {l2Plan}, the genesis
    ///         release and the version edge for the ecosystem the CTM belongs to, by the same
    ///         composer transitions use. All-zero (`txType == 0`) for an L1-only edge.
    /// @param _chainId The chain to compose for.
    function l2UpgradeTx(uint256 _chainId) external view returns (L2CanonicalTransaction memory);

    /// @notice The diamond cut this edge commits — no facet cuts, the engine's
    ///         `upgradeFromBootstrap(this)` init. Chains crossing the edge take exactly these bytes
    ///         by hand.
    function upgradeCut() external view returns (Diamond.DiamondCutData memory);
}
