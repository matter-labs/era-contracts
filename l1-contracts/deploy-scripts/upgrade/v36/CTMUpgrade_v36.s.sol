// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable gas-custom-errors

import {AuthoredL2Plan} from "contracts/upgrades/registry/RegistryTypes.sol";
import {L2EcosystemContract} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

import {AuthoredL2Side, DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {CoreOnGatewayHelper} from "../../ecosystem/CoreOnGatewayHelper.sol";
import {Utils} from "../../utils/Utils.sol";

/// @notice The v36 CTM upgrade — the first REGISTRY-DRIVEN edge after the v35 bootstrap, run by
///         the base pipeline: a fresh release (facets, DiamondInit, upgrade engine) pinned by a
///         write-once `CTMTransition`, committed by the governance call
///         `CTMUpgradeExecutor.applyCTMUpgrade(transition)` the merge derives. Its L2 leg installs
///         the built-ins whose code changed, derived on-chain from the release pair, and runs
///         `L2DefaultUpgrade` after them.
/// @dev L1SLOAD ({protocol-docs/l1sload.md#upgrade-from-v35}) changes the executable code of the Admin, Getters,
///      Mailbox, Executor and Committer facets, and of L2 built-ins among which the L2 Bridgehub, InteropCenter,
///      AtomicFlowManager, L2AssetRouter and L2InteropRootStorage. Against the v35 build at `2d08bda` the Migrator
///      facet, `DiamondInit` and `L1GenesisUpgrade` differ in their CBOR metadata alone. Recheck the list against the
///      v35 release build before preparing.
// solhint-disable-next-line contract-name-capwords
contract CTMUpgrade_v36 is DefaultCTMUpgrade {
    /// @notice The composer of `L2DefaultUpgrade`'s arguments that this edge's L2 plan pins.
    address public l2DelegateComposer;

    /// @inheritdoc DefaultCTMUpgrade
    function changedReleaseMembers() internal view virtual override returns (string[] memory names) {
        names = new string[](8);
        names[0] = "AdminFacet";
        names[1] = "GettersFacet";
        names[2] = "MailboxFacet";
        names[3] = "ExecutorFacet";
        names[4] = "CommitterFacet";
        names[5] = "MigratorFacet";
        names[6] = "DiamondInit";
        names[7] = "L1GenesisUpgrade";
    }

    /// @inheritdoc DefaultCTMUpgrade
    function deployNewCTMContracts() public virtual override {
        super.deployNewCTMContracts();
        // Named by the L2 side (see `authorL2Side`), so deployed before that side is prepared.
        l2DelegateComposer = deploySimpleContract("L2DefaultDelegateCalldataComposer");
    }

    /// @notice The L2 side: the delegate (`L2DefaultUpgrade`), its pinned composer, and every bytecode the
    ///         composed transaction needs published — the built-ins, the ZKsync OS baselines and the delegate.
    /// @dev Virtual so bytecode-light test harnesses can substitute an L1-only edge.
    function authorL2Side() internal virtual override returns (AuthoredL2Side memory side) {
        require(l2DelegateComposer != address(0), "L2 delegate composer not deployed");
        side.plan = AuthoredL2Plan({
            delegateBytecodeInfo: Utils.getZKOSBytecodeInfoForContract("L2DefaultUpgrade.sol", "L2DefaultUpgrade"),
            extraBytecodeInfos: new bytes[](0),
            delegateComposer: l2DelegateComposer
        });
        L2EcosystemContract[] memory delegateArtifact = new L2EcosystemContract[](1);
        delegateArtifact[0] = L2EcosystemContract.L2DefaultUpgrade;
        side.factoryDependencies = CoreOnGatewayHelper.getFullListOfFactoryDependencies(delegateArtifact);
    }

    function getCreationCalldata(string memory _contractName) internal view virtual override returns (bytes memory) {
        if (compareStrings(_contractName, "L2DefaultDelegateCalldataComposer")) {
            return abi.encode();
        }
        return super.getCreationCalldata(_contractName);
    }
}
