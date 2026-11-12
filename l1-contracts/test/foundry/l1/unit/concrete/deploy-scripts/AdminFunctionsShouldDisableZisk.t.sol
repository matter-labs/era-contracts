// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AdminFunctions} from "deploy-scripts/AdminFunctions.s.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

/// @notice Stands in for the chain's diamond: the decision consults only `facetAddress`.
contract MockChainLoupe {
    mapping(bytes4 selector => address facet) public facetAddress;

    function setFacetAddress(bytes4 _selector, address _facet) external {
        facetAddress[_selector] = _facet;
    }
}

/// @notice Exposes the internal decision, since `upgradeChainFromCTM` itself reads the cut through
/// `eth_getLogs`, which needs a live RPC.
contract AdminFunctionsHarness is AdminFunctions {
    function shouldDisableZisk(
        IZKChain _chain,
        Diamond.DiamondCutData memory _diamondCut,
        bool _enableZisk
    ) external view returns (bool) {
        return _shouldDisableZisk(_chain, _diamondCut, _enableZisk);
    }
}

/// @notice Unit tests for the ZiSK disable `AdminFunctions.upgradeChainFromCTM` adds after the cut.
contract AdminFunctionsShouldDisableZiskTest is Test {
    address internal constant FACET = address(0xFACE);

    AdminFunctionsHarness internal harness;
    MockChainLoupe internal chain;

    function setUp() public {
        harness = new AdminFunctionsHarness();
        chain = new MockChainLoupe();
    }

    /// @dev The cut a CTM upgrade stores: remove every selector the chain has, then add the new facets'.
    function _cut(
        bytes4[] memory _removed,
        bytes4[] memory _added
    ) internal pure returns (Diamond.DiamondCutData memory) {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(0),
            action: Diamond.Action.Remove,
            isFreezable: false,
            selectors: _removed
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: FACET,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: _added
        });
        return Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: address(0), initCalldata: ""});
    }

    function _preV34Selectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IAdmin.setPendingAdmin.selector;
        selectors[1] = IGetters.getProtocolVersion.selector;
    }

    function _v34Selectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = IAdmin.setPendingAdmin.selector;
        selectors[1] = IAdmin.setProofSystemStatus.selector;
        selectors[2] = IGetters.getProtocolVersion.selector;
    }

    function _shouldDisableZisk(
        Diamond.DiamondCutData memory _diamondCut,
        bool _enableZisk
    ) internal view returns (bool) {
        return harness.shouldDisableZisk(IZKChain(address(chain)), _diamondCut, _enableZisk);
    }

    /// @dev Regression: with the CTM already on v34, a chain two versions behind gets the cut stored for its
    /// own version, which lands on v33. The setter does not exist after it, so disabling ZiSK would revert
    /// the whole multicall.
    function test_laggingChain_cutWithoutSetter_doesNotDisable() public view {
        assertFalse(_shouldDisableZisk(_cut(_preV34Selectors(), _preV34Selectors()), false));
    }

    /// @dev A verifier-only upgrade cuts no facets, so it never installs the setter, whatever version it lands on.
    function test_verifierOnlyCut_doesNotDisable() public view {
        Diamond.DiamondCutData memory verifierOnly = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: ""
        });
        assertFalse(_shouldDisableZisk(verifierOnly, false));
    }

    function test_cutInstallingSetter_disables() public view {
        assertTrue(_shouldDisableZisk(_cut(_preV34Selectors(), _v34Selectors()), false));
    }

    function test_cutInstallingSetter_enableZisk_doesNotDisable() public view {
        assertFalse(_shouldDisableZisk(_cut(_preV34Selectors(), _v34Selectors()), true));
    }

    /// @dev Upgrades after the one into v34 remove and re-add the setter; they must keep the chain's choice.
    function test_chainWithSetter_doesNotDisable() public {
        chain.setFacetAddress(IAdmin.setProofSystemStatus.selector, FACET);
        assertFalse(_shouldDisableZisk(_cut(_v34Selectors(), _v34Selectors()), false));
    }

    /// @dev Only an `Add` can install a selector the chain lacks, so a `Remove` or `Replace` naming it does not count.
    function test_setterOnlyInNonAddCuts_doesNotDisable() public view {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(0),
            action: Diamond.Action.Remove,
            isFreezable: false,
            selectors: _v34Selectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: FACET,
            action: Diamond.Action.Replace,
            isFreezable: false,
            selectors: _v34Selectors()
        });
        Diamond.DiamondCutData memory cut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: ""
        });
        assertFalse(_shouldDisableZisk(cut, false));
    }

    /// @dev The setter is found in any added facet, at any position.
    function testFuzz_setterAnywhereInAddedFacets_disables(
        uint8 _facetCount,
        uint8 _facetIndex,
        uint8 _selectorIndex
    ) public view {
        uint256 facetCount = bound(_facetCount, 1, 5);
        uint256 facetIndex = bound(_facetIndex, 0, facetCount - 1);
        uint256 selectorIndex = bound(_selectorIndex, 0, 3);

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](facetCount);
        for (uint256 i = 0; i < facetCount; ++i) {
            bytes4[] memory selectors = new bytes4[](4);
            for (uint256 j = 0; j < 4; ++j) {
                selectors[j] = bytes4(keccak256(abi.encode(i, j)));
            }
            if (i == facetIndex) {
                selectors[selectorIndex] = IAdmin.setProofSystemStatus.selector;
            }
            facetCuts[i] = Diamond.FacetCut({
                facet: FACET,
                action: Diamond.Action.Add,
                isFreezable: false,
                selectors: selectors
            });
        }
        Diamond.DiamondCutData memory cut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: ""
        });
        assertTrue(_shouldDisableZisk(cut, false));
    }
}
