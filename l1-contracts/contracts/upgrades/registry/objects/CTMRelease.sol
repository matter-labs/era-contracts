// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICTMRelease} from "./ICTMRelease.sol";
import {CodehashPinLib} from "../libraries/CodehashPinLib.sol";
import {
    RegistryDuplicateFacetRow,
    RegistryDuplicateSelector,
    RegistryEmptySelectors,
    RegistryUnsortedSelectors,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {GenesisFacet, PinnedContract, ReleaseManifest} from "../RegistryTypes.sol";
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
            _manifest.diamondInit.addr == address(0) ||
            _manifest.genesisUpgrade.addr == address(0) ||
            _manifest.verifier.addr == address(0)
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
        // here freeze the shape checks against the exact code the rows pin. Each facet's list
        // MUST be strictly ascending ({ISelfDescribingFacet}), which makes both duplicate checks
        // linear: within a facet by adjacency, across the whole routing by a k-way merge.
        bytes4[][] memory routing = new bytes4[][](length);
        for (uint256 i = 0; i < length; ++i) {
            routing[i] = ISelfDescribingFacet(_manifest.genesisFacets[i].facet.addr).selectors();
            uint256 selectorsLength = routing[i].length;
            if (selectorsLength == 0) {
                revert RegistryEmptySelectors(_manifest.genesisFacets[i].facet.addr);
            }
            // Strictly ascending also rules out duplicates WITHIN the facet.
            for (uint256 j = 1; j < selectorsLength; ++j) {
                if (routing[i][j] <= routing[i][j - 1]) {
                    revert RegistryUnsortedSelectors(_manifest.genesisFacets[i].facet.addr, routing[i][j]);
                }
            }
            // Exactly ONE row per facet address. A facet describes its complete selector list,
            // so a second row is never needed — and `Diamond._addOneFunction` requires every
            // selector of one facet address to share freezability, so two rows differing in
            // `isFreezable` would install at genesis only to revert
            // (`SelectorsMustAllHaveSameFreezability`). Reject the shape instead of pinning a
            // release that cannot be applied.
            for (uint256 prev = 0; prev < i; ++prev) {
                if (_manifest.genesisFacets[prev].facet.addr == _manifest.genesisFacets[i].facet.addr) {
                    revert RegistryDuplicateFacetRow(_manifest.genesisFacets[i].facet.addr);
                }
            }
        }
        // A diamond routes each selector exactly once — reject duplicates ACROSS rows with a
        // k-way merge over the (per-facet sorted) lists: repeatedly take the global minimum and
        // require it to strictly exceed the previous one.
        _requireGloballyUniqueSelectors(routing);

        encodedManifest = abi.encode(_manifest);
    }

    /// @dev K-way merge duplicate detection over per-facet ascending selector lists. `_cursors`
    ///      tracks per-facet progress; each step picks the smallest remaining selector, which must
    ///      strictly exceed the previously taken one. O(total · facets) with facets ~ 7.
    function _requireGloballyUniqueSelectors(bytes4[][] memory _routing) private pure {
        uint256 facetsLength = _routing.length;
        uint256[] memory cursors = new uint256[](facetsLength);
        bool first = true;
        bytes4 previous;
        while (true) {
            bool found = false;
            uint256 minFacet = 0;
            bytes4 minSelector;
            for (uint256 i = 0; i < facetsLength; ++i) {
                if (cursors[i] < _routing[i].length) {
                    bytes4 candidate = _routing[i][cursors[i]];
                    if (!found || candidate < minSelector) {
                        found = true;
                        minFacet = i;
                        minSelector = candidate;
                    }
                }
            }
            if (!found) {
                break;
            }
            if (!first && minSelector == previous) {
                revert RegistryDuplicateSelector(minSelector);
            }
            first = false;
            previous = minSelector;
            ++cursors[minFacet];
        }
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
        return getManifest().diamondInit.addr;
    }

    function verifier() external view returns (address) {
        return getManifest().verifier.addr;
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
            m.genesisUpgrade.addr,
            m.genesis.genesisBatchHash,
            m.genesis.genesisBatchCommitment,
            m.genesis.genesisIndexRepeatedStorageChanges
        );
    }

    function validate() external view {
        ReleaseManifest memory m = getManifest();
        _requirePin(m.diamondInit);
        _requirePin(m.genesisUpgrade);
        _requirePin(m.verifier);
        uint256 length = m.genesisFacets.length;
        for (uint256 i = 0; i < length; ++i) {
            _requirePin(m.genesisFacets[i].facet);
        }
    }

    function verifyAll() external view returns (bool) {
        ReleaseManifest memory m = getManifest();
        if (!_pinHolds(m.diamondInit) || !_pinHolds(m.genesisUpgrade) || !_pinHolds(m.verifier)) {
            return false;
        }
        uint256 length = m.genesisFacets.length;
        for (uint256 i = 0; i < length; ++i) {
            if (!_pinHolds(m.genesisFacets[i].facet)) {
                return false;
            }
        }
        return true;
    }

    function _requirePin(PinnedContract memory _pinned) private view {
        CodehashPinLib.requirePin(_pinned);
    }

    function _pinHolds(PinnedContract memory _pinned) private view returns (bool) {
        return CodehashPinLib.pinHolds(_pinned);
    }
}
