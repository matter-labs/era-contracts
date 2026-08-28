// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICTMRelease} from "./ICTMRelease.sol";
import {CodehashPinLib} from "../libraries/CodehashPinLib.sol";
import {
    RegistryDuplicateFacetRow,
    RegistryDuplicateSelector,
    RegistryEmptySelectors,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {GenesisFacet, ReleaseManifest} from "../RegistryTypes.sol";
import {ISelfDescribingFacet} from "../../../state-transition/chain-interfaces/ISelfDescribingFacet.sol";

/// @notice Storage-backed, write-once description of one CTM release.
/// @dev Every pinned address carries its expected `EXTCODEHASH` INLINE and MANDATORILY — the
///      facets in their `GenesisFacet` rows, `DiamondInit` and the genesis upgrade beside their
///      addresses. Initialization refuses a manifest whose pins do not match the live code, and
///      `validate()` / `verifyAll()` re-check the same pins afterwards. There is no optional,
///      detached pin list: what the release names, the release pins.
contract CTMRelease is ICTMRelease {
    /// @dev THE manifest, stored as its own ABI encoding. Structured storage would need the
    ///      constructor to transcribe the struct field by field — the legacy codegen pipeline
    ///      cannot copy a struct ARRAY from memory to storage — which is exactly the second,
    ///      drift-prone copy of the shape this object is supposed to BE. One blob, one
    ///      assignment, and `manifestHash` is its hash by construction.
    bytes internal encodedManifest;

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
        // path, which is where the property is actually needed.
        uint256 length = _manifest.genesisFacets.length;
        // A release IS a complete chain routing — an empty one would describe an unusable chain
        // and, worse, derive a remove-everything delta in any transition that departs from a
        // populated release toward it. Whole-routing validity is enforced at THIS boundary, not
        // only when a transition later derives from the release.
        if (length == 0) {
            revert RegistryEmptySelectors(address(0));
        }
        // Routing is read from the facets' own self-description (see {GenesisFacet}); the reads
        // here freeze the shape checks against the exact code the rows pin.
        bytes4[][] memory routing = new bytes4[][](length);
        for (uint256 i = 0; i < length; ++i) {
            routing[i] = ISelfDescribingFacet(_manifest.genesisFacets[i].facet).selectors();
            uint256 selectorsLength = routing[i].length;
            if (selectorsLength == 0) {
                revert RegistryEmptySelectors(_manifest.genesisFacets[i].facet);
            }
            // Exactly ONE row per facet address. A facet describes its complete selector list,
            // so a second row is never needed — and `Diamond._addOneFunction` requires every
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
                bytes4 selector = routing[i][j];
                for (uint256 k = 0; k <= i; ++k) {
                    uint256 upperBound = k == i ? j : routing[k].length;
                    for (uint256 m = 0; m < upperBound; ++m) {
                        if (routing[k][m] == selector) {
                            revert RegistryDuplicateSelector(selector);
                        }
                    }
                }
            }
        }

        encodedManifest = abi.encode(_manifest);
    }

    /// @notice `keccak256(abi.encode(manifest))` — the 32-byte commitment governance compares
    ///         against the audited manifest. Computed from the stored encoding, not stored
    ///         separately: no contract reads it, and a second copy could only ever agree.
    function manifestHash() external view returns (bytes32) {
        return keccak256(encodedManifest);
    }

    /// @notice The whole manifest, exactly as it was pinned.
    function getManifest() public view returns (ReleaseManifest memory) {
        return abi.decode(encodedManifest, (ReleaseManifest));
    }

    function diamondInit() external view returns (address) {
        return getManifest().diamondInit;
    }

    function verifier() external view returns (address) {
        return getManifest().verifier;
    }

    function genesisFacets() external view returns (GenesisFacet[] memory) {
        return getManifest().genesisFacets;
    }

    function baseSystemContractHashes() external view returns (bytes32, bytes32, bytes32) {
        ReleaseManifest memory m = getManifest();
        return (m.genesis.bootloaderHash, m.genesis.defaultAccountHash, m.genesis.evmEmulatorHash);
    }

    function fixedForceDeploymentsData() external view returns (bytes memory) {
        return getManifest().genesis.fixedForceDeploymentsData;
    }

    function genesisParams() external view returns (address, bytes32, bytes32, uint64) {
        ReleaseManifest memory m = getManifest();
        return (
            m.genesisUpgrade,
            m.genesis.genesisBatchHash,
            m.genesis.genesisBatchCommitment,
            m.genesis.genesisIndexRepeatedStorageChanges
        );
    }

    function validate() external view {
        ReleaseManifest memory m = getManifest();
        _requirePin(m.diamondInit, m.diamondInitCodehash);
        _requirePin(m.genesisUpgrade, m.genesisUpgradeCodehash);
        _requirePin(m.verifier, m.verifierCodehash);
        uint256 length = m.genesisFacets.length;
        for (uint256 i = 0; i < length; ++i) {
            _requirePin(m.genesisFacets[i].facet, m.genesisFacets[i].codehash);
        }
    }

    function verifyAll() external view returns (bool) {
        ReleaseManifest memory m = getManifest();
        if (
            !CodehashPinLib.pinHolds(m.diamondInit, m.diamondInitCodehash) ||
            !CodehashPinLib.pinHolds(m.genesisUpgrade, m.genesisUpgradeCodehash) ||
            !CodehashPinLib.pinHolds(m.verifier, m.verifierCodehash)
        ) {
            return false;
        }
        uint256 length = m.genesisFacets.length;
        for (uint256 i = 0; i < length; ++i) {
            if (!CodehashPinLib.pinHolds(m.genesisFacets[i].facet, m.genesisFacets[i].codehash)) {
                return false;
            }
        }
        return true;
    }

    function _requirePin(address _target, bytes32 _expectedCodehash) private view {
        CodehashPinLib.requirePin(_target, _expectedCodehash);
    }
}
