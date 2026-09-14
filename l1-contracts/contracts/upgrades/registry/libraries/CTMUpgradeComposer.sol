// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICTMRelease} from "../objects/ICTMRelease.sol";
import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {IL2DelegateCalldataComposer} from "../objects/IL2DelegateCalldataComposer.sol";
import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {IComplexUpgrader} from "../../../state-transition/l2-deps/IComplexUpgrader.sol";
import {L2CanonicalTransactionLib} from "../../../state-transition/libraries/L2CanonicalTransactionLib.sol";
import {L2CanonicalTransaction} from "../../../common/Messaging.sol";
import {
    PRIORITY_TX_MAX_GAS_LIMIT,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE
} from "../../../common/Config.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR} from "../../../common/l2-helpers/L2ContractAddresses.sol";
import {SEMVER_MINOR_OFFSET} from "../../../common/libraries/SemVer.sol";
import {L2UpgradePlan, TransitionManifest} from "../RegistryTypes.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Composes the CTM-scoped payloads of a protocol upgrade — the diamond cut that names the
///         pinned object and the L2 protocol upgrade transaction — from that object's constants, at
///         execution time, on-chain. Facet changes are NOT composed here: they are derived at
///         transition initialization and applied verbatim from `transition.facetCuts()`. New-chain
///         genesis data comes from the release the CTM pins, not from a composed
///         `ChainCreationParams`.
/// @dev Everything here is CTM-scoped, including the L2 force-deployments keyed by
///      `L2EcosystemContract`: L2 system-contract bytecodes are pinned per CTM (Era and ZKsyncOS ship
///      different sets). Ecosystem-wide (core) L1 upgrades have no composition to do beyond
///      proxy/impl lookups and live in `EcosystemUpgradeExecutor`.
/// @dev Because the upgrade path (existing chains) and the genesis path (new chains) both resolve
///      to the same pinned release, they cannot drift apart.
library CTMUpgradeComposer {
    /// @notice Builds the diamond cut that upgrades an existing chain: no `facetCuts` of its own.
    ///         The committed cut names the write-once object (a transition, or the bootstrap
    ///         migration); the engine reads the facet cuts and every other input straight from that
    ///         same object at execution time, so nothing is carried in the cut and facet changes and
    ///         payload composition share one source of truth.
    function buildUpgradeCutData(
        address _initAddress,
        bytes memory _initCalldata
    ) internal pure returns (Diamond.DiamondCutData memory) {
        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: _initAddress,
                initCalldata: _initCalldata
            });
    }

    /// @notice The composed transaction of a transition for one chain (see {buildL2UpgradeTxFromPlan}).
    /// @dev For callers holding only the transition address; an executing engine already holds the
    ///      manifest and enters at {buildL2UpgradeTxFromPlan} to avoid decoding it twice.
    function buildL2UpgradeTx(
        ICTMTransition _transition,
        address _bridgehub,
        uint256 _chainId
    ) internal view returns (L2CanonicalTransaction memory) {
        TransitionManifest memory m = _transition.getManifest();
        return
            buildL2UpgradeTxFromPlan({
                _plan: _transition.l2Plan(),
                _newRelease: ICTMRelease(m.newRelease),
                _newProtocolVersion: m.newProtocolVersion,
                _bridgehub: _bridgehub,
                _chainId: _chainId
            });
    }

    /// @notice The FINAL L1 -> L2 protocol upgrade transaction of a chain for a FINAL L2 plan: the
    ///         force deployments, the delegate call the `L2ComplexUpgrader` performs after them (its
    ///         calldata defined by the plan's pinned composer from `_newRelease`, `_bridgehub` and
    ///         `_chainId`) and the factory dependencies. Every caller reaches this one function, so
    ///         the transition path and the bootstrap edge compose the same transaction from the
    ///         same inputs; the bootstrap has a plan and a release but no transition object to
    ///         unpack. The engine commits the result as is: there is no later per-chain rewrite.
    function buildL2UpgradeTxFromPlan(
        L2UpgradePlan memory _plan,
        ICTMRelease _newRelease,
        uint256 _newProtocolVersion,
        address _bridgehub,
        uint256 _chainId
    ) internal view returns (L2CanonicalTransaction memory) {
        if (_plan.deployments.length == 0 && _plan.delegateTo == address(0)) {
            // No L2 side (patch upgrades, or L1-only minor upgrades): an all-zero transaction
            // (txType == 0) makes `BaseZkSyncUpgrade` skip the L2 protocol upgrade transaction.
            return L2CanonicalTransactionLib.emptyL2CanonicalTransaction();
        }
        L2CanonicalTransaction memory transaction = L2CanonicalTransactionLib.emptyL2CanonicalTransaction();
        // The repository is ZKsync-OS-only: every chain a release describes runs ZKsync OS.
        transaction.txType = ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE;
        transaction.from = uint256(uint160(L2_FORCE_DEPLOYER_ADDR));
        transaction.to = uint256(uint160(L2_COMPLEX_UPGRADER_ADDR));
        transaction.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        transaction.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        transaction.nonce = protocolUpgradeNonce(_newProtocolVersion);
        // What the delegate is called WITH is defined by the pinned version-specific composer
        // from authoritative inputs — never by authored bytes (see {IL2DelegateCalldataComposer}).
        bytes memory delegateCalldata = _plan.delegateComposer == address(0)
            ? bytes("")
            : IL2DelegateCalldataComposer(_plan.delegateComposer).composeDelegateCalldata(
                _newRelease,
                _bridgehub,
                _chainId
            );
        transaction.data = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (_plan.deployments, _plan.delegateTo, delegateCalldata)
        );
        transaction.factoryDeps = _plan.factoryDepHashes;
        return transaction;
    }

    /// @notice The nonce of the L2 protocol upgrade transaction for a packed SemVer version.
    /// @dev Mirrors `UpgradeHelperLib.getProtocolUpgradeNonce`: the packed version without its
    ///      patch component. `BaseZkSyncUpgrade` enforces this equals the new minor version.
    function protocolUpgradeNonce(uint256 _protocolVersion) internal pure returns (uint256) {
        return _protocolVersion >> SEMVER_MINOR_OFFSET;
    }
}
