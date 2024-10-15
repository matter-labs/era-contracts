// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import "@openzeppelin/contracts-v4/utils/Strings.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {Call} from "contracts/governance/Common.sol";
import {DummyRestriction} from "contracts/dev-contracts/DummyRestriction.sol";
import {NotARestriction, NoCallsProvided, RestrictionWasAlreadyPresent, RestrictionWasNotPresent, AccessToFallbackDenied, AccessToFunctionDenied} from "contracts/common/L1ContractErrors.sol";
import {Utils} from "test/foundry/l1/unit/concrete/Utils/Utils.sol";

contract ChainAdminTest is Test {
    ChainAdmin internal chainAdmin;
    AccessControlRestriction internal restriction;
    GettersFacet internal gettersFacet;
    DummyRestriction internal dummyRestriction;

    address internal owner;
    uint32 internal major;
    uint32 internal minor;
    uint32 internal patch;
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    function setUp() public {
        owner = makeAddr("random address");

        restriction = new AccessControlRestriction(0, owner);
        address[] memory restrictions = new address[](1);
        restrictions[0] = address(restriction);

        chainAdmin = new ChainAdmin(restrictions);

        gettersFacet = new GettersFacet();
        dummyRestriction = new DummyRestriction(true);
    }

    function test_getRestrictions() public {
        address[] memory restrictions = chainAdmin.getRestrictions();
        assertEq(restrictions[0], address(restriction));
    }

    function test_isRestrictionActive() public {
        bool isActive = chainAdmin.isRestrictionActive(address(restriction));
        assertEq(isActive, true);
    }

    function test_addRestriction() public {
        address[] memory restrictions = chainAdmin.getRestrictions();

        vm.expectEmit(true, false, false, true);
        emit IChainAdmin.RestrictionAdded(address(dummyRestriction));

        vm.prank(address(chainAdmin));
        chainAdmin.addRestriction(address(dummyRestriction));
    }

    function test_addRestrictionRevertInvalidRestriction() public {
        vm.startPrank(address(chainAdmin));
        vm.expectRevert();
        chainAdmin.addRestriction(makeAddr("emptyRestriction"));
        vm.stopPrank();
    }

    function test_addRestrictionRevertInvalidRestrictionMagic() public {
        DummyRestriction badRestriction = new DummyRestriction(false);

        vm.startPrank(address(chainAdmin));
        vm.expectRevert(abi.encodeWithSelector(NotARestriction.selector, address(badRestriction)));
        chainAdmin.addRestriction(address(badRestriction));
        vm.stopPrank();
    }

    function test_addRestrictionZeroAddress() public {
        address[] memory restrictions = chainAdmin.getRestrictions();

        vm.prank(address(chainAdmin));
        vm.expectRevert();
        chainAdmin.addRestriction(address(0));
    }

    function test_addRestrictionRevert() public {
        vm.startPrank(address(chainAdmin));
        chainAdmin.addRestriction(address(dummyRestriction));

        vm.expectRevert(abi.encodeWithSelector(RestrictionWasAlreadyPresent.selector, address(dummyRestriction)));
        chainAdmin.addRestriction(address(dummyRestriction));
        vm.stopPrank();
    }

    function test_removeRestriction() public {
        address[] memory restrictions = chainAdmin.getRestrictions();

        vm.startPrank(address(chainAdmin));
        chainAdmin.addRestriction(address(dummyRestriction));

        vm.expectEmit(true, false, false, true);
        emit IChainAdmin.RestrictionRemoved(address(dummyRestriction));

        chainAdmin.removeRestriction(address(dummyRestriction));
        vm.stopPrank();
    }

    function test_removeRestrictionRevert() public {
        address[] memory restrictions = chainAdmin.getRestrictions();

        vm.startPrank(address(chainAdmin));
        chainAdmin.addRestriction(address(dummyRestriction));
        chainAdmin.removeRestriction(address(dummyRestriction));

        vm.expectRevert(abi.encodeWithSelector(RestrictionWasNotPresent.selector, dummyRestriction));
        chainAdmin.removeRestriction(address(dummyRestriction));
        vm.stopPrank();
    }

    function test_setUpgradeTimestamp(uint256 semverMinorVersionMultiplier, uint256 timestamp) public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 protocolVersion = packSemver(major, minor, patch + 1, semverMinorVersionMultiplier);

        vm.expectEmit(true, false, false, true);
        emit IChainAdmin.UpdateUpgradeTimestamp(protocolVersion, timestamp);

        vm.prank(address(chainAdmin));
        chainAdmin.setUpgradeTimestamp(protocolVersion, timestamp);
    }

    function test_multicallRevertNoCalls() public {
        Call[] memory calls = new Call[](0);

        vm.expectRevert(NoCallsProvided.selector);
        chainAdmin.multicall(calls, false);
    }

    function test_multicallRevertFailedCall() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(chainAdmin), value: 0, data: abi.encodeCall(gettersFacet.getAdmin, ())});

        vm.expectRevert();
        vm.prank(owner);
        chainAdmin.multicall(calls, true);
    }

    function test_validateCallAccessToFunctionDenied(bytes32 role) public {
        vm.assume(role != DEFAULT_ADMIN_ROLE);

        Call[] memory calls = new Call[](2);
        calls[0] = Call({target: address(gettersFacet), value: 0, data: abi.encodeCall(gettersFacet.getAdmin, ())});
        calls[1] = Call({target: address(gettersFacet), value: 0, data: abi.encodeCall(gettersFacet.getVerifier, ())});

        vm.prank(owner);
        restriction.setRequiredRoleForCall(address(gettersFacet), gettersFacet.getAdmin.selector, role);

        vm.expectRevert(
            abi.encodeWithSelector(
                AccessToFunctionDenied.selector,
                address(gettersFacet),
                gettersFacet.getAdmin.selector,
                owner
            )
        );
        vm.prank(owner);
        chainAdmin.multicall(calls, true);
    }

    function test_validateCallAccessToFallbackDenied(bytes32 role) public {
        vm.assume(role != DEFAULT_ADMIN_ROLE);

        Call[] memory calls = new Call[](2);
        calls[0] = Call({target: address(gettersFacet), value: 0, data: ""});
        calls[1] = Call({target: address(gettersFacet), value: 0, data: abi.encodeCall(gettersFacet.getVerifier, ())});

        vm.prank(owner);
        restriction.setRequiredRoleForFallback(address(gettersFacet), role);

        vm.expectRevert(abi.encodeWithSelector(AccessToFallbackDenied.selector, address(gettersFacet), owner));
        vm.prank(owner);
        chainAdmin.multicall(calls, true);
    }

    function test_multicall() public {
        Call[] memory calls = new Call[](2);
        calls[0] = Call({target: address(gettersFacet), value: 0, data: abi.encodeCall(gettersFacet.getAdmin, ())});
        calls[1] = Call({target: address(gettersFacet), value: 0, data: abi.encodeCall(gettersFacet.getVerifier, ())});

        vm.prank(owner);
        chainAdmin.multicall(calls, true);
    }

    function packSemver(
        uint32 major,
        uint32 minor,
        uint32 patch,
        uint256 semverMinorVersionMultiplier
    ) public returns (uint256) {
        if (major != 0) {
            revert("Major version must be 0");
        }

        return minor * semverMinorVersionMultiplier + patch;
    }
}
