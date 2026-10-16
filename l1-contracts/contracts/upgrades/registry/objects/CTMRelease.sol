// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ManifestStorage} from "./ManifestStorage.sol";
import {ICTMRelease} from "./ICTMRelease.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {ISelfDescribingFacet} from "../../../state-transition/chain-interfaces/ISelfDescribingFacet.sol";
import {FixedForceDeploymentsData} from "../../../state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {
    GenesisBatchHashZero,
    RegistryDuplicateFacetRow,
    RegistryDuplicateSelector,
    RegistryEmptySelectors,
    RegistryInventoryLengthMismatch,
    ReleaseForceDeploymentMismatch,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {GenesisFacet, ReleaseManifest} from "../RegistryTypes.sol";
import {L2EcosystemContract, L2_ECOSYSTEM_CONTRACT_COUNT} from "../libraries/ContractIdentifiers.sol";

/// @notice Storage-backed, write-once description of one CTM release.
/// @dev A release names its members by ADDRESS. What those addresses run is what governance
///      reviewed before approving this object; the contract's own job is to refuse a member
///      that is not a deployed contract at all, which `validate()` does on every path that
///      installs or applies the release.
contract CTMRelease is ICTMRelease, ManifestStorage {
    /// @notice Pins the full manifest. There is NO state-mutating function on this contract: the
    ///         manifest is written once, at construction, so write-once is structural rather than a
    ///         runtime guard and `manifestHash` can never describe a stale object.
    constructor(ReleaseManifest memory _manifest) ManifestStorage(abi.encode(_manifest)) {
        if (
            _manifest.diamondInit == address(0) ||
            _manifest.genesisUpgrade == address(0) ||
            _manifest.verifier == address(0)
        ) {
            revert ZeroAddress();
        }
        // Batch zero of every chain created from this release commits to it, and nothing else on
        // the install path can tell a zero hash from a defaulted field.
        if (_manifest.genesis.genesisBatchHash == bytes32(0)) {
            revert GenesisBatchHashZero();
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
        _requireForceDeploymentsMatchTable(_manifest);
    }

    /// @notice The whole manifest, exactly as it was pinned.
    function getManifest() public view returns (ReleaseManifest memory) {
        return abi.decode(encodedManifest, (ReleaseManifest));
    }

    /// @inheritdoc ICTMRelease
    function protocolVersion() external view returns (uint256) {
        return getManifest().protocolVersion;
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

    /// @inheritdoc ICTMRelease
    function validate() external view {
        ReleaseManifest memory m = getManifest();
        ObjectAnchorLib.requireCode(m.diamondInit);
        ObjectAnchorLib.requireCode(m.genesisUpgrade);
        ObjectAnchorLib.requireCode(m.verifier);
        _requireUniqueFacetRows(m.genesisFacets);
        uint256 facetsLength = m.genesisFacets.length;
        bytes4[][] memory routing = new bytes4[][](facetsLength);
        for (uint256 i = 0; i < facetsLength; ++i) {
            address facet = m.genesisFacets[i].facet;
            // Not merely defensive: the facets are the one member set this contract READS
            // through (`ISelfDescribingFacet.selectors()`), and a codeless target answers that
            // read with an empty revert instead of a usable failure.
            ObjectAnchorLib.requireCode(facet);
            routing[i] = ISelfDescribingFacet(facet).selectors();
            // A selector-less row would reach the installing paths (`DiamondInit`, the bootstrap
            // engine) as an empty `Add` cut, which `Diamond.diamondCut` rejects on every chain.
            if (routing[i].length == 0) {
                revert RegistryEmptySelectors(facet);
            }
        }
        // Same reason: the installing paths add every facet's routing, and `Diamond.diamondCut`
        // rejects a selector added twice. The bootstrap and `ChainTypeManager.initialize` install
        // a release without cutting a diamond, so this is where a collision has to be caught.
        _requireNoDuplicateSelectors(routing);
    }

    /// @dev The genesis force-deployments blob names the implementation of each table member a
    ///      second time; both copies must agree, so the genesis path and the upgrade path cannot
    ///      describe different L2 code. `beaconDeployerInfo` has no table member and is not compared.
    function _requireForceDeploymentsMatchTable(ReleaseManifest memory _manifest) private pure {
        FixedForceDeploymentsData memory data = abi.decode(
            _manifest.genesis.fixedForceDeploymentsData,
            (FixedForceDeploymentsData)
        );
        bytes[] memory table = _manifest.l2BytecodeInfos;
        bytes memory shell = _manifest.l2SystemProxyBytecodeInfo;
        _requireTableField(data.bridgehubBytecodeInfo, table, shell, L2EcosystemContract.L2Bridgehub);
        _requireTableField(data.l2AssetRouterBytecodeInfo, table, shell, L2EcosystemContract.L2AssetRouter);
        _requireTableField(data.l2NtvBytecodeInfo, table, shell, L2EcosystemContract.L2NativeTokenVault);
        _requireTableField(data.messageRootBytecodeInfo, table, shell, L2EcosystemContract.L2MessageRoot);
        _requireTableField(data.chainAssetHandlerBytecodeInfo, table, shell, L2EcosystemContract.L2ChainAssetHandler);
        _requireTableField(data.interopCenterBytecodeInfo, table, shell, L2EcosystemContract.InteropCenter);
        _requireTableField(data.interopHandlerBytecodeInfo, table, shell, L2EcosystemContract.L2InteropHandler);
        _requireTableField(data.assetTrackerBytecodeInfo, table, shell, L2EcosystemContract.L2AssetTracker);
        _requireTableField(data.baseTokenHolderBytecodeInfo, table, shell, L2EcosystemContract.BaseTokenHolder);
    }

    /// @dev A blob field is the `(implementation, proxy shell)` descriptor of its member's table
    ///      row, and empty when the row is.
    function _requireTableField(
        bytes memory _field,
        bytes[] memory _table,
        bytes memory _shell,
        L2EcosystemContract _member
    ) private pure {
        bytes memory row = _table[uint256(_member)];
        bytes memory expected = row.length == 0 ? bytes("") : abi.encode(row, _shell);
        if (keccak256(_field) != keccak256(expected)) {
            revert ReleaseForceDeploymentMismatch(uint256(_member));
        }
    }

    /// @dev One row per facet address. A repeated address describes a routing no diamond can hold
    ///      (`Diamond.diamondCut` would re-add selectors already routed). Checked at construction
    ///      AND on every `validate()`, because the two answer to different threats: a mistake in an
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

    /// @dev An open-addressing set over the release's selectors: `validate()` runs on every chain
    ///      creation, where a pairwise scan of the ~a hundred selectors costs ~0.9M gas. A slot holds
    ///      `selector + 1`, so zero marks it empty; the table is never more than half full, so a
    ///      probe always ends at an empty slot.
    function _requireNoDuplicateSelectors(bytes4[][] memory _routing) private pure {
        uint256 routingLength = _routing.length;
        uint256 total = 0;
        for (uint256 i = 0; i < routingLength; ++i) {
            total += _routing[i].length;
        }
        uint256 tableSize = 2 * total + 1;
        uint256[] memory table = new uint256[](tableSize);
        for (uint256 i = 0; i < routingLength; ++i) {
            bytes4[] memory selectors = _routing[i];
            uint256 selectorsLength = selectors.length;
            for (uint256 j = 0; j < selectorsLength; ++j) {
                uint256 entry = uint256(uint32(selectors[j])) + 1;
                uint256 slot = entry % tableSize;
                while (table[slot] != 0) {
                    if (table[slot] == entry) {
                        revert RegistryDuplicateSelector(selectors[j]);
                    }
                    slot = (slot + 1) % tableSize;
                }
                table[slot] = entry;
            }
        }
    }
}
