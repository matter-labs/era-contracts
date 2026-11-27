// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {MultisigCommitter} from "contracts/state-transition/validators/MultisigCommitter.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {ProxyAlreadyInitialized} from "contracts/common/L1ContractErrors.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";

/// @notice A timelock proxy that started as a plain `ValidatorTimelock` (initializer version 1) and was then
/// switched to `MultisigCommitter` with a bare `ProxyAdmin.upgrade`: `initializeV2` must not re-own it.
contract MultisigCommitterInitializationTest is Test {
    uint32 internal constant EXECUTION_DELAY = 10;

    ProxyAdmin internal proxyAdmin;
    DummyBridgehub internal dummyBridgehub;
    address internal timelockOwner;
    address internal proxy;

    function setUp() public {
        timelockOwner = makeAddr("timelockOwner");
        dummyBridgehub = new DummyBridgehub();
        proxyAdmin = new ProxyAdmin();

        ValidatorTimelock timelockImplementation = new ValidatorTimelock(address(dummyBridgehub));
        proxy = address(
            new TransparentUpgradeableProxy(
                address(timelockImplementation),
                address(proxyAdmin),
                abi.encodeCall(ValidatorTimelock.initialize, (timelockOwner, EXECUTION_DELAY))
            )
        );

        MultisigCommitter multisigCommitterImplementation = new MultisigCommitter(address(dummyBridgehub));
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(proxy), address(multisigCommitterImplementation));
    }

    function test_revertWhen_initializeV2_onAProxyAlreadyAtVersion1() public {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ProxyAlreadyInitialized.selector, uint8(1)));
        MultisigCommitter(proxy).initializeV2(attacker, type(uint32).max);

        assertEq(MultisigCommitter(proxy).owner(), timelockOwner, "the owner must not change");
        assertEq(MultisigCommitter(proxy).executionDelay(), EXECUTION_DELAY, "the delay must not change");
    }

    /// @dev The intended path for such a proxy: `reinitializeV2` keeps its owner and moves it to version 2,
    ///      after which `initializeV2` stays closed too.
    function test_reinitializeV2_keepsTheOwnerAndClosesInitializeV2() public {
        MultisigCommitter(proxy).reinitializeV2();

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ProxyAlreadyInitialized.selector, uint8(2)));
        MultisigCommitter(proxy).initializeV2(attacker, 0);

        assertEq(MultisigCommitter(proxy).owner(), timelockOwner, "the owner must not change");
        assertEq(MultisigCommitter(proxy).executionDelay(), EXECUTION_DELAY, "the delay must not change");
    }
}
