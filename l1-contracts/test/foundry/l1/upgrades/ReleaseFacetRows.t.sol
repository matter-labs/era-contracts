// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {MockSelfDescribingFacet} from "contracts/dev-contracts/test/MockSelfDescribingFacet.sol";
import {RegistryDuplicateFacetRow} from "contracts/common/L1ContractErrors.sol";
import {GenesisFacet, ReleaseGenesisData, ReleaseManifest} from "contracts/upgrades/registry/RegistryTypes.sol";
import {L2_ECOSYSTEM_CONTRACT_COUNT} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {L2PlanFixtures} from "foundry-test/l1/unit/concrete/Upgrades/registry/L2PlanFixtures.sol";

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

/// @notice A release's facet rows name each facet once: refused at construction and again by `validate()`.
contract ReleaseFacetRowsTest is Test {
    address internal facetA;

    bytes4 internal constant SEL_A = bytes4(uint32(0xAA));

    function setUp() public {
        facetA = address(new MockSelfDescribingFacet(_one(SEL_A)));
    }

    /// A release cannot be CONSTRUCTED with a repeated facet row.
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

    /// @dev `validate()` checks member code BEFORE the row check, so a manifest exercising the
    ///      row check must name members that are deployed.
    function _stub(string memory _name) internal returns (address addr) {
        addr = makeAddr(_name);
        vm.etch(addr, bytes.concat(hex"00", bytes(_name)));
    }

    function _manifest(GenesisFacet[] memory _rows) internal returns (ReleaseManifest memory) {
        return
            ReleaseManifest({
                protocolVersion: 0,
                diamondInit: _stub("diamondInit"),
                verifier: _stub("verifier"),
                genesisUpgrade: _stub("genesisUpgrade"),
                genesisFacets: _rows,
                genesis: ReleaseGenesisData({
                    fixedForceDeploymentsData: L2PlanFixtures.emptyTableForceDeploymentsData(),
                    genesisBatchHash: bytes32(uint256(1)),
                    genesisIndexRepeatedStorageChanges: 1
                }),
                l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT),
                l2SystemProxyBytecodeInfo: ""
            });
    }
}
