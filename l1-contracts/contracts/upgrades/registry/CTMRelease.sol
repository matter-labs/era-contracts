// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GenesisFacet, ICTMRelease} from "./ICTMRelease.sol";
import {CodehashPinLib} from "./CodehashPinLib.sol";
import {
    RegistryDuplicateFacetRow,
    RegistryDuplicateSelector,
    RegistryEmptySelectors,
    RegistryUnknownKey,
    ZeroAddress
} from "../../common/L1ContractErrors.sol";

/// @notice Storage-backed, write-once description of one CTM release.
/// @dev Every pinned address carries its expected `EXTCODEHASH` INLINE and MANDATORILY — the
///      facets in their `GenesisFacet` rows, `DiamondInit` and the genesis upgrade beside their
///      addresses. Initialization refuses a manifest whose pins do not match the live code, and
///      `validate()` / `verifyAll()` re-check the same pins afterwards. There is no optional,
///      detached pin list: what the release names, the release pins.
contract CTMRelease is ICTMRelease {
    // solhint-disable-next-line gas-struct-packing
    struct ReleaseManifest {
        address diamondInit;
        bytes32 diamondInitCodehash;
        address verifier;
        bytes32 verifierCodehash;
        GenesisFacet[] genesisFacets;
        bytes32 bootloaderHash;
        bytes32 defaultAccountHash;
        bytes32 evmEmulatorHash;
        bytes fixedForceDeploymentsData;
        address genesisUpgrade;
        bytes32 genesisUpgradeCodehash;
        bytes32 genesisBatchHash;
        bytes32 genesisBatchCommitment;
        uint64 genesisIndexRepeatedStorageChanges;
    }

    /// @notice `keccak256(abi.encode(manifest))`. No contract reads this — it is a review aid, a
    ///         single value to compare against the audited manifest. Provenance is the codehash.
    bytes32 public manifestHash;

    /// @dev THE manifest. The contract does not keep a second, transcribed copy of its own shape;
    ///      the getters below read out of this.
    ReleaseManifest internal manifest;

    /// @notice Pins the full manifest. There is NO state-mutating function on this contract: the
    ///         manifest is written once, at construction, so write-once is structural rather than a
    ///         runtime guard and `manifestHash` can never describe a stale object.
    constructor(ReleaseManifest memory _manifest) {
        if (
            _manifest.diamondInit == address(0) ||
            _manifest.genesisUpgrade == address(0) ||
            _manifest.verifier == address(0)
        ) {
            revert ZeroAddress();
        }

        // The pins are deliberately NOT checked here: the manifest author supplies both halves of
        // every (address, codehash) pair, so a construction-time check proves only that the pair is
        // self-consistent. `validate()` re-checks all of them against live code on every execution
        // path, which is where the property is actually needed — and keeping construction free of
        // live-code reads makes an object's address a pure function of its manifest.
        uint256 length = _manifest.genesisFacets.length;
        // A release IS a complete chain routing — an empty one would describe an unusable chain
        // and, worse, derive a remove-everything delta in any transition that departs from a
        // populated release toward it. Whole-routing validity is enforced at THIS boundary, not
        // only when a transition later derives from the release.
        if (length == 0) {
            revert RegistryEmptySelectors(address(0));
        }
        for (uint256 i = 0; i < length; ++i) {
            // Releases are the canonical routing source: every facet row carries its explicit,
            // complete selector list (transitions derive their cuts from these).
            uint256 selectorsLength = _manifest.genesisFacets[i].selectors.length;
            if (selectorsLength == 0) {
                revert RegistryEmptySelectors(_manifest.genesisFacets[i].facet);
            }
            // Exactly ONE row per facet address. A row carries that facet's complete selector
            // list, so a second row is never needed — and `Diamond._addOneFunction` requires every
            // selector of one facet address to share freezability, so two rows differing in
            // `isFreezable` would install at genesis only to revert
            // (`SelectorsMustAllHaveSameFreezability`). Reject the shape instead of pinning a
            // release that cannot be applied.
            for (uint256 prev = 0; prev < i; ++prev) {
                if (_manifest.genesisFacets[prev].facet == _manifest.genesisFacets[i].facet) {
                    revert RegistryDuplicateFacetRow(_manifest.genesisFacets[i].facet);
                }
            }
            // A diamond routes each selector exactly once — reject duplicates across the whole
            // routing (within AND across rows), not just when a transition later derives.
            for (uint256 j = 0; j < selectorsLength; ++j) {
                bytes4 selector = _manifest.genesisFacets[i].selectors[j];
                for (uint256 k = 0; k <= i; ++k) {
                    uint256 upperBound = k == i ? j : _manifest.genesisFacets[k].selectors.length;
                    for (uint256 m = 0; m < upperBound; ++m) {
                        if (_manifest.genesisFacets[k].selectors[m] == selector) {
                            revert RegistryDuplicateSelector(selector);
                        }
                    }
                }
            }
        }

        manifestHash = keccak256(abi.encode(_manifest));

        // Field-by-field: the legacy codegen pipeline cannot copy a struct ARRAY from memory to
        // storage, so `manifest = _manifest` is not available for `genesisFacets`.
        manifest.diamondInit = _manifest.diamondInit;
        manifest.diamondInitCodehash = _manifest.diamondInitCodehash;
        manifest.verifier = _manifest.verifier;
        manifest.verifierCodehash = _manifest.verifierCodehash;
        for (uint256 i = 0; i < length; ++i) {
            manifest.genesisFacets.push(_manifest.genesisFacets[i]);
        }
        manifest.bootloaderHash = _manifest.bootloaderHash;
        manifest.defaultAccountHash = _manifest.defaultAccountHash;
        manifest.evmEmulatorHash = _manifest.evmEmulatorHash;
        manifest.fixedForceDeploymentsData = _manifest.fixedForceDeploymentsData;
        manifest.genesisUpgrade = _manifest.genesisUpgrade;
        manifest.genesisUpgradeCodehash = _manifest.genesisUpgradeCodehash;
        manifest.genesisBatchHash = _manifest.genesisBatchHash;
        manifest.genesisBatchCommitment = _manifest.genesisBatchCommitment;
        manifest.genesisIndexRepeatedStorageChanges = _manifest.genesisIndexRepeatedStorageChanges;
    }

    function diamondInit() external view returns (address) {
        return manifest.diamondInit;
    }

    function verifier() external view returns (address) {
        return manifest.verifier;
    }

    function genesisFacets() external view returns (GenesisFacet[] memory) {
        return manifest.genesisFacets;
    }

    function baseSystemContractHashes() external view returns (bytes32, bytes32, bytes32) {
        return (manifest.bootloaderHash, manifest.defaultAccountHash, manifest.evmEmulatorHash);
    }

    function fixedForceDeploymentsData() external view returns (bytes memory) {
        return manifest.fixedForceDeploymentsData;
    }

    function genesisParams() external view returns (address, bytes32, bytes32, uint64) {
        return (
            manifest.genesisUpgrade,
            manifest.genesisBatchHash,
            manifest.genesisBatchCommitment,
            manifest.genesisIndexRepeatedStorageChanges
        );
    }

    function validate() external view {
        _requirePin(manifest.diamondInit, manifest.diamondInitCodehash);
        _requirePin(manifest.genesisUpgrade, manifest.genesisUpgradeCodehash);
        _requirePin(manifest.verifier, manifest.verifierCodehash);
        uint256 length = manifest.genesisFacets.length;
        for (uint256 i = 0; i < length; ++i) {
            _requirePin(manifest.genesisFacets[i].facet, manifest.genesisFacets[i].codehash);
        }
    }

    function verifyAll() external view returns (bool) {
        if (
            !CodehashPinLib.pinHolds(manifest.diamondInit, manifest.diamondInitCodehash) ||
            !CodehashPinLib.pinHolds(manifest.genesisUpgrade, manifest.genesisUpgradeCodehash) ||
            !CodehashPinLib.pinHolds(manifest.verifier, manifest.verifierCodehash)
        ) {
            return false;
        }
        uint256 length = manifest.genesisFacets.length;
        for (uint256 i = 0; i < length; ++i) {
            if (!CodehashPinLib.pinHolds(manifest.genesisFacets[i].facet, manifest.genesisFacets[i].codehash)) {
                return false;
            }
        }
        return true;
    }

    function _requirePin(address _target, bytes32 _expectedCodehash) private view {
        CodehashPinLib.requirePin(_target, _expectedCodehash);
    }
}
