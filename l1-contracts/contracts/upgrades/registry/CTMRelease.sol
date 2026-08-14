// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GenesisFacet, ICTMRelease} from "./ICTMRelease.sol";
import {CodehashPinLib} from "./CodehashPinLib.sol";
import {
    RegistryAlreadyInitialized,
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

    bool public initialized;
    bytes32 public manifestHash;

    address internal releaseDiamondInit;
    bytes32 internal diamondInitCodehash;
    address internal releaseVerifier;
    bytes32 internal verifierCodehash;
    GenesisFacet[] internal releaseGenesisFacets;
    bytes32 internal bootloaderHash;
    bytes32 internal defaultAccountHash;
    bytes32 internal evmEmulatorHash;
    bytes internal releaseFixedForceDeploymentsData;
    address internal genesisUpgrade;
    bytes32 internal genesisUpgradeCodehash;
    bytes32 internal genesisBatchHash;
    bytes32 internal genesisBatchCommitment;
    uint64 internal genesisIndexRepeatedStorageChanges;

    function initialize(ReleaseManifest calldata _manifest) external {
        if (initialized) {
            revert RegistryAlreadyInitialized();
        }
        if (
            _manifest.diamondInit == address(0) ||
            _manifest.genesisUpgrade == address(0) ||
            _manifest.verifier == address(0)
        ) {
            revert ZeroAddress();
        }

        _requirePin(_manifest.diamondInit, _manifest.diamondInitCodehash);
        _requirePin(_manifest.genesisUpgrade, _manifest.genesisUpgradeCodehash);
        _requirePin(_manifest.verifier, _manifest.verifierCodehash);
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
            // complete selector list (transitions derive their cuts from these) and its pin.
            uint256 selectorsLength = _manifest.genesisFacets[i].selectors.length;
            if (selectorsLength == 0) {
                revert RegistryEmptySelectors(_manifest.genesisFacets[i].facet);
            }
            _requirePin(_manifest.genesisFacets[i].facet, _manifest.genesisFacets[i].codehash);
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

        initialized = true;
        manifestHash = keccak256(abi.encode(_manifest));
        releaseDiamondInit = _manifest.diamondInit;
        diamondInitCodehash = _manifest.diamondInitCodehash;
        releaseVerifier = _manifest.verifier;
        verifierCodehash = _manifest.verifierCodehash;
        for (uint256 i = 0; i < length; ++i) {
            releaseGenesisFacets.push(_manifest.genesisFacets[i]);
        }
        bootloaderHash = _manifest.bootloaderHash;
        defaultAccountHash = _manifest.defaultAccountHash;
        evmEmulatorHash = _manifest.evmEmulatorHash;
        releaseFixedForceDeploymentsData = _manifest.fixedForceDeploymentsData;
        genesisUpgrade = _manifest.genesisUpgrade;
        genesisUpgradeCodehash = _manifest.genesisUpgradeCodehash;
        genesisBatchHash = _manifest.genesisBatchHash;
        genesisBatchCommitment = _manifest.genesisBatchCommitment;
        genesisIndexRepeatedStorageChanges = _manifest.genesisIndexRepeatedStorageChanges;
    }

    function diamondInit() external view returns (address) {
        return releaseDiamondInit;
    }

    function verifier() external view returns (address) {
        return releaseVerifier;
    }

    function genesisFacets() external view returns (GenesisFacet[] memory) {
        return releaseGenesisFacets;
    }

    function baseSystemContractHashes() external view returns (bytes32, bytes32, bytes32) {
        return (bootloaderHash, defaultAccountHash, evmEmulatorHash);
    }

    function fixedForceDeploymentsData() external view returns (bytes memory) {
        return releaseFixedForceDeploymentsData;
    }

    function genesisParams() external view returns (address, bytes32, bytes32, uint64) {
        return (genesisUpgrade, genesisBatchHash, genesisBatchCommitment, genesisIndexRepeatedStorageChanges);
    }

    function validate() external view {
        if (!initialized) {
            revert RegistryUnknownKey();
        }
        _requirePin(releaseDiamondInit, diamondInitCodehash);
        _requirePin(genesisUpgrade, genesisUpgradeCodehash);
        _requirePin(releaseVerifier, verifierCodehash);
        uint256 length = releaseGenesisFacets.length;
        for (uint256 i = 0; i < length; ++i) {
            _requirePin(releaseGenesisFacets[i].facet, releaseGenesisFacets[i].codehash);
        }
    }

    function verifyAll() external view returns (bool) {
        if (!initialized) {
            return false;
        }
        if (
            !CodehashPinLib.pinHolds(releaseDiamondInit, diamondInitCodehash) ||
            !CodehashPinLib.pinHolds(genesisUpgrade, genesisUpgradeCodehash) ||
            !CodehashPinLib.pinHolds(releaseVerifier, verifierCodehash)
        ) {
            return false;
        }
        uint256 length = releaseGenesisFacets.length;
        for (uint256 i = 0; i < length; ++i) {
            if (!CodehashPinLib.pinHolds(releaseGenesisFacets[i].facet, releaseGenesisFacets[i].codehash)) {
                return false;
            }
        }
        return true;
    }

    function _requirePin(address _target, bytes32 _expectedCodehash) private view {
        CodehashPinLib.requirePin(_target, _expectedCodehash);
    }
}
