// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {ReleaseFacetReader} from "contracts/upgrades/registry/libraries/ReleaseFacetReader.sol";
import {MockSelfDescribingFacet} from "contracts/dev-contracts/test/MockSelfDescribingFacet.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {RegistryDuplicateFacetRow} from "contracts/common/L1ContractErrors.sol";
import {GenesisFacet, ReleaseGenesisData, ReleaseManifest} from "contracts/upgrades/registry/RegistryTypes.sol";
import {L2_ECOSYSTEM_CONTRACT_COUNT} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

/// @notice Exposes the internal comparison so it can be driven with rows no live object would
///         serve — which is the point: the comparison must be correct even for rows read off an
///         object whose construction the caller cannot attest.
contract FacetRowsHarness {
    function chainMatchesFacetRows(GenesisFacet[] memory _facets, address _chain) external view returns (bool) {
        return ReleaseFacetReader.chainMatchesFacetRows(_facets, _chain);
    }
}

/// @notice A `CTMRelease` whose stored manifest was written by creation code of its own choosing,
///         so it serves rows its constructor would have refused.
/// @dev Same storage layout as `CTMRelease` (one `bytes` at slot 0); the constructor returns the
///      audited runtime code over it. Deliberately built as real initcode rather than by poking a
///      legitimate object's storage — that IS the adversary being defended against.
contract CounterfeitRelease {
    bytes internal encodedManifest;

    constructor(bytes memory _canonicalRuntime, bytes memory _encodedManifest) {
        encodedManifest = _encodedManifest;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            return(add(_canonicalRuntime, 0x20), mload(_canonicalRuntime))
        }
    }
}

/// @notice The duplicate-row finding, fixed in both places it had to be.
/// @dev Mocks are used for the live diamond only: `facets()` and `isFacetFreezable` are the two
///      loupe reads the comparison makes, and what is under test is the comparison's arithmetic,
///      not a real diamond's routing (that is covered end to end in `RegistryDrivenUpgrade.t.sol`).
contract ReleaseFacetRowsTest is Test {
    FacetRowsHarness internal harness;
    address internal chain = makeAddr("liveChain");

    address internal facetA;
    address internal facetB;

    bytes4 internal constant SEL_A = bytes4(uint32(0xAA));
    bytes4 internal constant SEL_B = bytes4(uint32(0xBB));

    function setUp() public {
        harness = new FacetRowsHarness();
        facetA = address(new MockSelfDescribingFacet(_one(SEL_A)));
        facetB = address(new MockSelfDescribingFacet(_one(SEL_B)));
    }

    /// The finding: expected `[A, A]` used to match live `[A, B]`. Each expected row matched the
    /// single live row carrying A without consuming it, and the row count then agreed — so B, a
    /// facet the release never named, was reported as accounted for.
    function test_duplicateExpectedRowsDoNotAccountForAnUnexaminedLiveFacet() public {
        _mockLiveFacets(_twoLiveRows(facetA, SEL_A, facetB, SEL_B));

        GenesisFacet[] memory expected = new GenesisFacet[](2);
        expected[0] = GenesisFacet({facet: facetA, isFreezable: false});
        expected[1] = GenesisFacet({facet: facetA, isFreezable: false});

        assertFalse(
            harness.chainMatchesFacetRows(expected, chain),
            "a live facet no expected row named must not be reported as matched"
        );
    }

    /// The same comparison still answers true for routing that genuinely agrees, so the fix
    /// discriminates rather than refusing everything.
    function test_matchingRowsStillMatch() public {
        _mockLiveFacets(_twoLiveRows(facetA, SEL_A, facetB, SEL_B));

        GenesisFacet[] memory expected = new GenesisFacet[](2);
        expected[0] = GenesisFacet({facet: facetA, isFreezable: false});
        expected[1] = GenesisFacet({facet: facetB, isFreezable: false});

        assertTrue(harness.chainMatchesFacetRows(expected, chain), "identical routing must match");
    }

    /// Order-insensitivity is the reason the match is a search rather than a zip, and consuming
    /// the matched row must not have broken it.
    function test_matchingIsStillOrderInsensitive() public {
        _mockLiveFacets(_twoLiveRows(facetB, SEL_B, facetA, SEL_A));

        GenesisFacet[] memory expected = new GenesisFacet[](2);
        expected[0] = GenesisFacet({facet: facetA, isFreezable: false});
        expected[1] = GenesisFacet({facet: facetB, isFreezable: false});

        assertTrue(harness.chainMatchesFacetRows(expected, chain), "row order must not matter");
    }

    /// The other half of the fix: a release cannot be CONSTRUCTED with a repeated facet row.
    function test_releaseConstructionRejectsDuplicateFacetRows() public {
        GenesisFacet[] memory rows = new GenesisFacet[](2);
        rows[0] = GenesisFacet({facet: facetA, isFreezable: false});
        rows[1] = GenesisFacet({facet: facetA, isFreezable: true});

        vm.expectRevert(abi.encodeWithSelector(RegistryDuplicateFacetRow.selector, facetA));
        new CTMRelease(_manifest(rows));
    }

    /// And why the constructor check alone is not enough. An object whose creation code wrote the
    /// manifest itself never ran that check, so `validate()` — which every acceptance point calls
    /// — has to make it again.
    function test_validateRejectsDuplicateFacetRowsOnAnObjectTheConstructorNeverSaw() public {
        GenesisFacet[] memory rows = new GenesisFacet[](2);
        rows[0] = GenesisFacet({facet: facetA, isFreezable: false});
        rows[1] = GenesisFacet({facet: facetA, isFreezable: false});

        address counterfeit = address(
            new CounterfeitRelease(vm.getDeployedCode("CTMRelease.sol:CTMRelease"), abi.encode(_manifest(rows)))
        );
        // It is a `CTMRelease` in every way a chain can observe...
        assertEq(ICTMRelease(counterfeit).genesisFacets().length, 2, "the counterfeit must serve the duplicate rows");
        // ...and `validate()` still refuses it.
        vm.expectRevert(abi.encodeWithSelector(RegistryDuplicateFacetRow.selector, facetA));
        ICTMRelease(counterfeit).validate();
    }

    // ───────────────────────────────── helpers ─────────────────────────────────

    function _one(bytes4 _selector) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = _selector;
    }

    function _twoLiveRows(
        address _first,
        bytes4 _firstSelector,
        address _second,
        bytes4 _secondSelector
    ) internal pure returns (IGetters.Facet[] memory live) {
        live = new IGetters.Facet[](2);
        live[0] = IGetters.Facet({addr: _first, selectors: _one(_firstSelector)});
        live[1] = IGetters.Facet({addr: _second, selectors: _one(_secondSelector)});
    }

    function _mockLiveFacets(IGetters.Facet[] memory _live) internal {
        vm.mockCall(chain, abi.encodeCall(IGetters.facets, ()), abi.encode(_live));
        uint256 length = _live.length;
        for (uint256 i = 0; i < length; ++i) {
            vm.mockCall(chain, abi.encodeCall(IGetters.isFacetFreezable, (_live[i].addr)), abi.encode(false));
        }
    }

    /// @dev `validate()` checks member code BEFORE the row check, so a manifest exercising the
    ///      row check must name members that are deployed.
    function _stub(string memory _name) internal returns (address addr) {
        addr = makeAddr(_name);
        vm.etch(addr, bytes.concat(hex"00", bytes(_name)));
    }

    function _manifest(GenesisFacet[] memory _rows) internal returns (ReleaseManifest memory) {
        return
            ReleaseManifest({
                diamondInit: _stub("diamondInit"),
                verifier: _stub("verifier"),
                genesisUpgrade: _stub("genesisUpgrade"),
                genesisFacets: _rows,
                genesis: ReleaseGenesisData({
                    fixedForceDeploymentsData: hex"f1",
                    genesisBatchHash: bytes32(uint256(1)),
                    genesisBatchCommitment: bytes32(uint256(1)),
                    genesisIndexRepeatedStorageChanges: 1
                }),
                l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT),
                l2SystemProxyBytecodeInfo: ""
            });
    }
}
