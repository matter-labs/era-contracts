// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AddressIntrospector} from "deploy-scripts/utils/AddressIntrospector.sol";
import {ProtocolVersionFeatures} from "deploy-scripts/utils/ProtocolVersionFeatures.sol";

import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

/// @notice Fee manager discovery used by the default upgrade scripts: a release from v35 on reuses the CTM's manager,
///         so the chains' prepaid balances stay in place.
/// @dev The CTM's protocol version is mocked: setting it for real needs an initialized CTM proxy, which is unrelated
///      to what is under test. The manager is read from a real CTM implementation.
contract AddressIntrospectorInteropFeeTest is Test {
    ChainTypeManager internal ctm;
    address internal manager;

    function setUp() public {
        manager = makeAddr("interopFeeManager");
        ctm = new ChainTypeManager(
            makeAddr("bridgehub"),
            makeAddr("interopCenter"),
            address(0),
            makeAddr("permissionlessValidator"),
            manager
        );
    }

    function test_reusesTheManagerOfTheCTM() public {
        _mockProtocolVersion(ctm, ProtocolVersionFeatures.CTM_INTEROP_FEE_MANAGER);
        assertEq(AddressIntrospector._getInteropFeeManager(ctm), manager);

        _mockProtocolVersion(ctm, ProtocolVersionFeatures.CTM_INTEROP_FEE_MANAGER + 1);
        assertEq(AddressIntrospector._getInteropFeeManager(ctm), manager);
    }

    /// @dev Older CTMs have no getter: the legacy CTM here has no code, so calling it would revert.
    function test_noManagerBeforeTheReleaseThatIntroducedIt() public {
        ChainTypeManager legacyCtm = ChainTypeManager(makeAddr("legacyCtm"));
        _mockProtocolVersion(legacyCtm, ProtocolVersionFeatures.CTM_INTEROP_FEE_MANAGER - 1);
        assertEq(AddressIntrospector._getInteropFeeManager(legacyCtm), address(0));
    }

    function _mockProtocolVersion(ChainTypeManager _ctm, uint32 _minor) internal {
        vm.mockCall(
            address(_ctm),
            abi.encodeCall(IChainTypeManager.protocolVersion, ()),
            abi.encode(SemVer.packSemVer(0, _minor, 0))
        );
    }
}
