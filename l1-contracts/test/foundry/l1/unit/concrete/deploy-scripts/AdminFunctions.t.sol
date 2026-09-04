// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import {AdminFunctions} from "deploy-scripts/AdminFunctions.s.sol";
import {Call} from "contracts/governance/Common.sol";

/// @notice Isolates Ownable2Step sender resolution from the deployment flow.
contract OperationalOwnableMock is Ownable2Step {
    uint256 public value;

    function initialize(address _owner) external {
        require(owner() == address(0), "already initialized");
        _transferOwnership(_owner);
    }

    function setValue(uint256 _value) external onlyOwner {
        value = _value;
    }
}

contract AdminFunctionsHarness is AdminFunctions {
    function resolveOperationalCallSender(Call memory _call) external view returns (address) {
        return _operationalCallSender(_call);
    }
}

contract AdminFunctionsTest is Test {
    AdminFunctionsHarness internal harness;
    ProxyAdmin internal proxyAdmin;
    OperationalOwnableMock internal ownable;
    address internal operationalAdmin;

    function setUp() public {
        harness = new AdminFunctionsHarness();
        operationalAdmin = makeAddr("operational admin");

        proxyAdmin = new ProxyAdmin();
        OperationalOwnableMock implementation = new OperationalOwnableMock();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            abi.encodeCall(OperationalOwnableMock.initialize, (address(this)))
        );
        ownable = OperationalOwnableMock(address(proxy));

        proxyAdmin.transferOwnership(operationalAdmin);
        ownable.transferOwnership(operationalAdmin);
    }

    function test_resolvesPendingProxyAdminOwnerForAcceptOwnership() public view {
        Call memory call = Call({
            target: address(ownable),
            value: 0,
            data: abi.encodeCall(Ownable2Step.acceptOwnership, ())
        });

        assertEq(harness.resolveOperationalCallSender(call), operationalAdmin);
    }

    function test_resolvesAcceptedOwnerForTheFollowingCall() public {
        Call memory acceptCall = Call({
            target: address(ownable),
            value: 0,
            data: abi.encodeCall(Ownable2Step.acceptOwnership, ())
        });
        address acceptSender = harness.resolveOperationalCallSender(acceptCall);

        vm.prank(acceptSender);
        ownable.acceptOwnership();

        uint256 expectedValue = uint256(keccak256("expected value"));
        Call memory ownerCall = Call({
            target: address(ownable),
            value: 0,
            data: abi.encodeCall(OperationalOwnableMock.setValue, (expectedValue))
        });
        address ownerCallSender = harness.resolveOperationalCallSender(ownerCall);
        assertEq(ownerCallSender, operationalAdmin);

        vm.prank(ownerCallSender);
        ownable.setValue(expectedValue);
        assertEq(ownable.value(), expectedValue);
    }

    function test_revertsWhenPendingOwnerDoesNotMatchProxyAdminOwner() public {
        ownable.transferOwnership(makeAddr("unexpected pending owner"));
        Call memory call = Call({
            target: address(ownable),
            value: 0,
            data: abi.encodeCall(Ownable2Step.acceptOwnership, ())
        });

        vm.expectRevert(bytes("pending owner does not match proxy admin owner"));
        harness.resolveOperationalCallSender(call);
    }

    function test_resolvesCurrentOwnerForOtherCalls() public view {
        Call memory call = Call({
            target: address(ownable),
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (operationalAdmin))
        });

        assertEq(harness.resolveOperationalCallSender(call), address(this));
    }
}
