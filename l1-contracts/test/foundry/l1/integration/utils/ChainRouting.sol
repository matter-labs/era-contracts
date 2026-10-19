// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {GenesisFacet} from "contracts/upgrades/registry/RegistryTypes.sol";
import {ISelfDescribingFacet} from "contracts/state-transition/chain-interfaces/ISelfDescribingFacet.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";

/// @notice Test-side check that a live chain diamond routes EXACTLY a release's facets: the loupe's
///         `facets()` against each release facet's own `selectors()` (as sets) and `isFacetFreezable`
///         against the release row — same facet addresses, no extras, no omissions, order-insensitive.
/// @dev Facets with an empty self-description contribute no routing (genesis installs no cut for
///      them), so they are not expected in the loupe output. Releases refuse repeated facet rows at
///      construction, so each release row is matched against at most one live row.
library ChainRouting {
    function matchesRelease(ICTMRelease _release, address _chain) internal view returns (bool) {
        GenesisFacet[] memory expected = _release.genesisFacets();
        IGetters.Facet[] memory live = IGetters(_chain).facets();
        uint256 matched = 0;
        for (uint256 i = 0; i < expected.length; ++i) {
            bytes4[] memory selectors = ISelfDescribingFacet(expected[i].facet).selectors();
            if (selectors.length == 0) {
                continue;
            }
            bool found = false;
            for (uint256 j = 0; j < live.length; ++j) {
                if (live[j].addr != expected[i].facet) {
                    continue;
                }
                found =
                    _sameSet(selectors, live[j].selectors) &&
                    IGetters(_chain).isFacetFreezable(live[j].addr) == expected[i].isFreezable;
                break;
            }
            if (!found) {
                return false;
            }
            ++matched;
        }
        return live.length == matched;
    }

    /// @dev Both lists are duplicate-free (a diamond routes a selector once), so equal length plus
    ///      one-sided containment is set equality.
    function _sameSet(bytes4[] memory _a, bytes4[] memory _b) private pure returns (bool) {
        if (_a.length != _b.length) {
            return false;
        }
        for (uint256 i = 0; i < _a.length; ++i) {
            bool present = false;
            for (uint256 j = 0; j < _b.length; ++j) {
                if (_b[j] == _a[i]) {
                    present = true;
                    break;
                }
            }
            if (!present) {
                return false;
            }
        }
        return true;
    }
}
