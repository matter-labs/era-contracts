// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import "openzeppelin-contracts/contracts/utils/Strings.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {Call} from "contracts/governance/Common.sol";
import {NoCallsProvided, RestrictionWasAlreadyPresent, RestrictionWasNotPresent, AccessToFallbackDenied, AccessToFunctionDenied} from "contracts/common/L1ContractErrors.sol";
import {Utils} from "test/foundry/unit/concrete/Utils/Utils.sol";

contract ChainAdminTest is Test {
    ChainAdmin internal chainAdmin;
    GettersFacet internal gettersFacet;

    address internal owner;
    uint32 internal major;
    uint32 internal minor;
    uint32 internal patch;
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    function setUp() public {
        owner = makeAddr("random address");

        chainAdmin = new ChainAdmin(owner, address(0));

        gettersFacet = new GettersFacet();
    }

    function test_setUpgradeTimestamp(uint256 semverMinorVersionMultiplier, uint256 timestamp) public {
        (major, minor, patch) = gettersFacet.getSemverProtocolVersion();
        uint256 protocolVersion = packSemver(major, minor, patch + 1, semverMinorVersionMultiplier);

        vm.expectEmit(true, false, false, true);
        emit IChainAdmin.UpdateUpgradeTimestamp(protocolVersion, timestamp);

        vm.prank(address(owner));
        chainAdmin.setUpgradeTimestamp(protocolVersion, timestamp);
    }

    function test_multicallRevertNoCalls() public {
        IChainAdmin.Call[] memory calls = new IChainAdmin.Call[](0);

        vm.prank(owner);
        vm.expectRevert(NoCallsProvided.selector);
        chainAdmin.multicall(calls, false);
    }

    function test_multicallRevertFailedCall() public {
        IChainAdmin.Call[] memory calls = new IChainAdmin.Call[](1);
        calls[0] = IChainAdmin.Call({target: address(chainAdmin), value: 0, data: abi.encodeCall(gettersFacet.getAdmin, ())});

        vm.expectRevert();
        vm.prank(owner);
        chainAdmin.multicall(calls, true);
    }

    function test_multicall() public {
        IChainAdmin.Call[] memory calls = new IChainAdmin.Call[](2);
        calls[0] = IChainAdmin.Call({target: address(gettersFacet), value: 0, data: abi.encodeCall(gettersFacet.getAdmin, ())});
        calls[1] = IChainAdmin.Call({target: address(gettersFacet), value: 0, data: abi.encodeCall(gettersFacet.getVerifier, ())});

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
