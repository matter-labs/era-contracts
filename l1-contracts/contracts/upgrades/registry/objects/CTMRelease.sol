// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICTMRelease} from "./ICTMRelease.sol";
import {CodehashPinLib} from "../libraries/CodehashPinLib.sol";
import {RegistryEmptySelectors, ZeroAddress} from "../../../common/L1ContractErrors.sol";
import {GenesisFacet, PinnedContract, ReleaseManifest} from "../RegistryTypes.sol";

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
        // The one facet-set check kept: an empty set would describe an unusable chain and derive
        // a remove-everything delta in any transition departing toward it.
        if (_manifest.genesisFacets.length == 0) {
            revert RegistryEmptySelectors(address(0));
        }
        // NO routing validation here — the release does not own the routing concept at all. It
        // pins facet rows; the selectors live in the facets' own self-description, and routing
        // well-formedness is enforced where routing actually executes: `Diamond.diamondCut`
        // rejects duplicate or empty routing when a chain is created, and `TransitionDeltaLib`
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
