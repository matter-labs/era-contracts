// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import "lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {Call} from "contracts/governance/Common.sol";
import {NoCallsProvided, RestrictionWasAlreadyPresent, RestrictionWasNotPresent} from "contracts/common/L1ContractErrors.sol";
import {Utils} from "test/foundry/unit/concrete/Utils/Utils.sol";

contract ChainAdminTest is Test {
    ChainAdmin internal chainAdmin;
    AccessControlRestriction internal restriction;
    GettersFacet internal gettersFacet;

    address internal owner;
    uint32 internal major;
    uint32 internal minor;
    uint32 internal patch;

    function setUp() public {
        owner = makeAddr("random address");

        restriction = new AccessControlRestriction(0, owner);
        address[] memory restrictions = new address[](1);
        restrictions[0] = address(restriction);

        chainAdmin = new ChainAdmin(restrictions);

        gettersFacet = new GettersFacet();
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

        vm.prank(address(chainAdmin));
        vm.expectEmit();
        emit IChainAdmin.RestrictionAdded(owner);
        chainAdmin.addRestriction(owner);
    }

    function test_addRestrictionRevert() public {
        vm.startPrank(address(chainAdmin));
        chainAdmin.addRestriction(owner);

        vm.expectRevert(abi.encodeWithSelector(RestrictionWasAlreadyPresent.selector, owner));
        chainAdmin.addRestriction(owner);
    }

    function test_removeRestriction() public {
        address[] memory restrictions = chainAdmin.getRestrictions();
        vm.prank(address(chainAdmin));
        chainAdmin.addRestriction(owner);

        vm.prank(address(chainAdmin));
        vm.expectEmit();
        emit IChainAdmin.RestrictionRemoved(owner);
        chainAdmin.removeRestriction(owner);
    }

    function test_removeRestrictionRevert() public {
        address[] memory restrictions = chainAdmin.getRestrictions();
        vm.startPrank(address(chainAdmin));
        chainAdmin.addRestriction(owner);
        chainAdmin.removeRestriction(owner);

        vm.expectRevert(abi.encodeWithSelector(RestrictionWasNotPresent.selector, owner));
        chainAdmin.removeRestriction(owner);
    }

    function test_setUpgradeTimestamp() public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 protocolVersion = packSemver(major, minor, patch + 1);

        vm.expectEmit();
        emit IChainAdmin.UpdateUpgradeTimestamp(protocolVersion, 10);
        vm.prank(address(chainAdmin));
        chainAdmin.setUpgradeTimestamp(protocolVersion, 10);
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
        vm.startPrank(owner);
        chainAdmin.multicall(calls, true);
    }

    function test_multicall() public {
        Call[] memory calls = new Call[](2);
        calls[0] = Call({target: address(gettersFacet), value: 0, data: abi.encodeCall(gettersFacet.getAdmin, ())});
        calls[1] = Call({target: address(gettersFacet), value: 0, data: abi.encodeCall(gettersFacet.getVerifier, ())});

        vm.startPrank(owner);
        chainAdmin.multicall(calls, true);
    }

    function packSemver(uint32 major, uint32 minor, uint32 patch) public returns (uint256) {
        uint256 SEMVER_MINOR_VERSION_MULTIPLIER = 4294967296;
        if (major != 0) {
            revert("Major version must be 0");
        }

        return minor * SEMVER_MINOR_VERSION_MULTIPLIER + patch;
    }
}