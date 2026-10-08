// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AddressIntrospector} from "deploy-scripts/utils/AddressIntrospector.sol";
import {FIRST_PROTOCOL_VERSION_WITH_INTEROP_FEE} from "deploy-scripts/utils/Types.sol";

import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {CommitterFacet} from "contracts/state-transition/chain-deps/facets/Committer.sol";
import {IInteropFeeManager} from "contracts/core/interop-fee/IInteropFeeManager.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

/// @notice Fee manager discovery used by the default upgrade scripts: a release from v35 on reuses the manager the
///         current Committer facet charges, so the chains' prepaid balances stay in place.
/// @dev The CTM is mocked: discovery only reads its protocol version, and standing up a CTM with chains is unrelated
///      to what is under test. The Committer facet is real.
contract AddressIntrospectorInteropFeeTest is Test {
    ChainTypeManager internal ctm;
    address internal manager;
    address internal committerFacet;

    function setUp() public {
        ctm = ChainTypeManager(makeAddr("ctm"));
        manager = makeAddr("interopFeeManager");
        committerFacet = address(new CommitterFacet(block.chainid, IInteropFeeManager(manager)));
    }

    function test_reusesTheManagerOfTheCurrentCommitter() public {
        _mockProtocolVersion(FIRST_PROTOCOL_VERSION_WITH_INTEROP_FEE);
        assertEq(AddressIntrospector._getInteropFeeManager(ctm, committerFacet), manager);

        _mockProtocolVersion(FIRST_PROTOCOL_VERSION_WITH_INTEROP_FEE + 1);
        assertEq(AddressIntrospector._getInteropFeeManager(ctm, committerFacet), manager);
    }

    /// @dev Older Committer facets have no getter, so they are never called.
    function test_noManagerBeforeTheReleaseThatIntroducedIt() public {
        _mockProtocolVersion(FIRST_PROTOCOL_VERSION_WITH_INTEROP_FEE - 1);
        assertEq(AddressIntrospector._getInteropFeeManager(ctm, makeAddr("legacyCommitterFacet")), address(0));
    }

    function test_noManagerWithoutAnUpToDateChain() public {
        _mockProtocolVersion(FIRST_PROTOCOL_VERSION_WITH_INTEROP_FEE);
        assertEq(AddressIntrospector._getInteropFeeManager(ctm, address(0)), address(0));
    }

    function _mockProtocolVersion(uint32 _minor) internal {
        vm.mockCall(
            address(ctm),
            abi.encodeCall(IChainTypeManager.protocolVersion, ()),
            abi.encode(SemVer.packSemVer(0, _minor, 0))
        );
    }
}
