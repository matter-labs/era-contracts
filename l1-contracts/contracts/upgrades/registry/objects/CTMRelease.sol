// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICTMRelease} from "./ICTMRelease.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {ReleaseFacetReader} from "../libraries/ReleaseFacetReader.sol";
import {
    RegistryDuplicateFacetRow,
    RegistryEmptySelectors,
    RegistryInventoryLengthMismatch,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {GenesisFacet, ReleaseManifest} from "../RegistryTypes.sol";
import {L2_ECOSYSTEM_CONTRACT_COUNT} from "../libraries/ContractIdentifiers.sol";

/// @notice Storage-backed, write-once description of one CTM release.
/// @dev A release names its members by ADDRESS. What those addresses run is what governance
///      reviewed before approving this object; the contract's own job is to refuse a member
///      that is not a deployed contract at all, which `validate()` does on every path that
///      installs or applies the release.
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

        // Code existence is deliberately NOT checked here: a release may legitimately be
        // constructed in the same transaction that deploys its members, and `validate()` holds
        // the requirement on every path that installs or applies the release, which is where it
        // is actually needed.
        // The one facet-set check kept: an empty set would describe an unusable chain and derive
        // a remove-everything delta in any transition departing toward it.
        if (_manifest.genesisFacets.length == 0) {
            revert RegistryEmptySelectors(address(0));
        }
        _requireUniqueFacetRows(_manifest.genesisFacets);
        // The L2 table is an enum-indexed inventory: the length check makes every slot an
        // explicit statement (content is governance-reviewed data, like the rest of the
        // manifest). Checked against the count at THIS release's construction — later enum
        // appends grow the table of later releases only.
        if (_manifest.l2BytecodeInfos.length != L2_ECOSYSTEM_CONTRACT_COUNT) {
            revert RegistryInventoryLengthMismatch(L2_ECOSYSTEM_CONTRACT_COUNT, _manifest.l2BytecodeInfos.length);
        }
        // NO routing validation here — the release does not own the routing concept at all. It
        // names facet rows; the selectors live in the facets' own self-description, and routing
        // well-formedness is enforced where routing actually executes: `Diamond.diamondCut`
        // rejects duplicate or empty routing when a chain is created, and `TransitionDerivationLib`
        // re-walks both releases' routing when a transition derives its delta — both before
        // anything is committed.
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

    function fixedForceDeploymentsData() external view returns (bytes memory) {
        return getManifest().genesis.fixedForceDeploymentsData;
    }

    function l2BytecodeInfos() external view returns (bytes[] memory) {
        return getManifest().l2BytecodeInfos;
    }

    function l2SystemProxyBytecodeInfo() external view returns (bytes memory) {
        return getManifest().l2SystemProxyBytecodeInfo;
    }

    function genesisParams() external view returns (address, bytes32, uint64) {
        ReleaseManifest memory m = getManifest();
        return (m.genesisUpgrade, m.genesis.genesisBatchHash, m.genesis.genesisIndexRepeatedStorageChanges);
    }

    /// @notice Whether `_chain`'s live diamond routing is EXACTLY this release's: same facets,
    ///         same per-facet selector sets, nothing extra. The on-chain form of the "upgrade
    ///         path equals genesis path" guarantee, for post-upgrade checks and monitoring.
    function verifyChainRouting(address _chain) external view returns (bool) {
        return ReleaseFacetReader.chainMatchesFacetRows(getManifest().genesisFacets, _chain);
    }

    /// @inheritdoc ICTMRelease
    function validate() external view {
        ReleaseManifest memory m = getManifest();
        ObjectAnchorLib.requireCode(m.diamondInit);
        ObjectAnchorLib.requireCode(m.genesisUpgrade);
        ObjectAnchorLib.requireCode(m.verifier);
        _requireUniqueFacetRows(m.genesisFacets);
        uint256 facetsLength = m.genesisFacets.length;
        for (uint256 i = 0; i < facetsLength; ++i) {
            // Not merely defensive: the facets are the one member set this contract READS
            // through (`ISelfDescribingFacet.selectors()`), and a codeless target answers that
            // read with an empty revert instead of a usable failure.
            ObjectAnchorLib.requireCode(m.genesisFacets[i].facet);
        }
    }

    /// @dev One row per facet address. A repeated address describes a routing no diamond can hold
    ///      (`Diamond.diamondCut` would re-add selectors already routed) and makes the release's
    ///      row count disagree with the facet count any live diamond can show — which is what
    ///      {ReleaseFacetReader.chainMatchesFacetRows} counts. Checked at construction AND on
    ///      every `validate()`, because the two answer to different threats: a mistake in an
    ///      authored manifest, and rows read off an object some caller could not attest.
    function _requireUniqueFacetRows(GenesisFacet[] memory _facets) private pure {
        uint256 length = _facets.length;
        for (uint256 i = 0; i < length; ++i) {
            address facet = _facets[i].facet;
            if (facet == address(0)) {
                continue;
            }
            for (uint256 j = 0; j < i; ++j) {
                if (_facets[j].facet == facet) {
                    revert RegistryDuplicateFacetRow(facet);
                }
            }
        }
    }
}
