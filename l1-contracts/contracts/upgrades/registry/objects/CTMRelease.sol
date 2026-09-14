// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICTMRelease} from "./ICTMRelease.sol";
import {CodehashPinLib} from "../libraries/CodehashPinLib.sol";
import {ReleaseFacetReader} from "../libraries/ReleaseFacetReader.sol";
import {
    RegistryEmptySelectors,
    RegistryInventoryLengthMismatch,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {GenesisFacet, PinnedContract, ReleaseManifest} from "../RegistryTypes.sol";
import {L2_ECOSYSTEM_CONTRACT_COUNT} from "../libraries/ContractIdentifiers.sol";

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

    /// @dev The pins of `_pins` that are not facet rows: `diamondInit`, `genesisUpgrade`, `verifier`.
    uint256 private constant FIXED_PIN_COUNT = 3;

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
        // The L2 table is an enum-indexed inventory: the length check makes every slot an
        // explicit statement (content is governance-reviewed data, like the rest of the
        // manifest). Checked against the count at THIS release's construction — later enum
        // appends grow the table of later releases only.
        if (_manifest.l2BytecodeInfos.length != L2_ECOSYSTEM_CONTRACT_COUNT) {
            revert RegistryInventoryLengthMismatch(L2_ECOSYSTEM_CONTRACT_COUNT, _manifest.l2BytecodeInfos.length);
        }
        // NO routing validation here — the release does not own the routing concept at all. It
        // pins facet rows; the selectors live in the facets' own self-description, and routing
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
        return getManifest().diamondInit.addr;
    }

    function verifier() external view returns (address) {
        return getManifest().verifier.addr;
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

    function genesisParams() external view returns (address, bytes32, bytes32, uint64) {
        ReleaseManifest memory m = getManifest();
        return (
            m.genesisUpgrade.addr,
            m.genesis.genesisBatchHash,
            m.genesis.genesisBatchCommitment,
            m.genesis.genesisIndexRepeatedStorageChanges
        );
    }

    /// @notice Whether `_chain`'s live diamond routing is EXACTLY this release's: same facets,
    ///         same per-facet selector sets, nothing extra. The on-chain form of the "upgrade
    ///         path equals genesis path" guarantee, for post-upgrade checks and monitoring.
    function verifyChainRouting(address _chain) external view returns (bool) {
        return ReleaseFacetReader.chainMatchesFacetRows(getManifest().genesisFacets, _chain);
    }

    /// @inheritdoc ICTMRelease
    function validate() external view {
        PinnedContract[] memory pins = _pins(getManifest());
        uint256 length = pins.length;
        for (uint256 i = 0; i < length; ++i) {
            CodehashPinLib.requirePin(pins[i]);
        }
    }

    /// @inheritdoc ICTMRelease
    function verifyAll() external view returns (bool) {
        PinnedContract[] memory pins = _pins(getManifest());
        uint256 length = pins.length;
        for (uint256 i = 0; i < length; ++i) {
            if (!CodehashPinLib.pinHolds(pins[i])) {
                return false;
            }
        }
        return true;
    }

    /// @dev THE enumeration of what this release pins, in check order: `diamondInit`,
    ///      `genesisUpgrade`, `verifier`, then every genesis facet. Both `validate()` and
    ///      `verifyAll()` walk this one list, so a pinned field added to the manifest is added
    ///      here once and cannot be enforced by one surface and missed by the other.
    function _pins(ReleaseManifest memory _m) private pure returns (PinnedContract[] memory pins) {
        uint256 facetsLength = _m.genesisFacets.length;
        pins = new PinnedContract[](FIXED_PIN_COUNT + facetsLength);
        pins[0] = _m.diamondInit;
        pins[1] = _m.genesisUpgrade;
        pins[2] = _m.verifier;
        for (uint256 i = 0; i < facetsLength; ++i) {
            pins[FIXED_PIN_COUNT + i] = _m.genesisFacets[i].facet;
        }
    }
}
