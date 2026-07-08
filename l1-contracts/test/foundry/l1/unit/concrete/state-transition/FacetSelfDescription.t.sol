// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Utils as DeployUtils} from "deploy-scripts/utils/Utils.sol";

import {ISelfDescribingFacet} from "contracts/state-transition/chain-interfaces/ISelfDescribingFacet.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {MigratorFacet} from "contracts/state-transition/chain-deps/facets/Migrator.sol";
import {CommitterFacet} from "contracts/state-transition/chain-deps/facets/Committer.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";

/// @notice Drift guard for the facets' embedded `selectors()` lists: each list must equal the
///         selector set actually extracted from the facet's deployed bytecode (the same
///         `Utils.getAllSelectors` extraction production deployments register in the diamond,
///         which excludes the unregistered helper views `getName()` and `selectors()`).
/// @dev If a facet gains or loses an external function without its `selectors()` list being
///      regenerated, the corresponding test here fails.
contract FacetSelfDescriptionTest is Test {
    function _assertSelfDescription(ISelfDescribingFacet _facet, string memory _name) internal {
        bytes4[] memory declared = _sort(_facet.selectors());
        bytes4[] memory extracted = _sort(DeployUtils.getAllSelectors(address(_facet).code));

        assertEq(declared.length, extracted.length, string.concat(_name, ": selector count drift"));
        for (uint256 i = 0; i < declared.length; ++i) {
            assertEq(declared[i], extracted[i], string.concat(_name, ": selector set drift"));
        }
    }

    function _sort(bytes4[] memory _selectors) internal pure returns (bytes4[] memory) {
        for (uint256 i = 1; i < _selectors.length; ++i) {
            bytes4 key = _selectors[i];
            uint256 j = i;
            while (j > 0 && uint32(_selectors[j - 1]) > uint32(key)) {
                _selectors[j] = _selectors[j - 1];
                --j;
            }
            _selectors[j] = key;
        }
        return _selectors;
    }

    function test_adminFacetSelfDescription() public {
        _assertSelfDescription(new AdminFacet(block.chainid, RollupDAManager(address(0))), "AdminFacet");
    }

    function test_gettersFacetSelfDescription() public {
        _assertSelfDescription(new GettersFacet(), "GettersFacet");
    }

    function test_mailboxFacetSelfDescription() public {
        _assertSelfDescription(
            new MailboxFacet(
                9,
                block.chainid,
                makeAddr("chainAssetHandler"),
                IEIP7702Checker(makeAddr("eip7702Checker")),
                false
            ),
            "MailboxFacet"
        );
    }

    function test_executorFacetSelfDescription() public {
        _assertSelfDescription(new ExecutorFacet(block.chainid), "ExecutorFacet");
    }

    function test_migratorFacetSelfDescription() public {
        _assertSelfDescription(new MigratorFacet(block.chainid, false), "MigratorFacet");
    }

    function test_committerFacetSelfDescription() public {
        _assertSelfDescription(new CommitterFacet(block.chainid), "CommitterFacet");
    }
}
