// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title MockSelfDescribingFacet
/// @notice Test-only facet stand-in with a configurable self-described selector list. Registry
///         objects read facet routing from `ISelfDescribingFacet.selectors()`, so synthetic
///         facets in tests must actually answer it.
/// @dev Does not declare the interface: `ISelfDescribingFacet.selectors()` is `pure` (real
///      facets embed their list in code), while this mock reads its configurable list from
///      storage — the staticcall ABI is identical either way.
contract MockSelfDescribingFacet {
    bytes4[] internal facetSelectors;

    constructor(bytes4[] memory _selectors) {
        facetSelectors = _selectors;
    }

    function selectors() external view returns (bytes4[] memory) {
        return facetSelectors;
    }
}
