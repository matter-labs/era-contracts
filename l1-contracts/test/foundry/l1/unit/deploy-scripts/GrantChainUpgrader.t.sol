// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GrantChainUpgrader} from "deploy-scripts/GrantChainUpgrader.s.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {IValidatorTimelock} from "contracts/state-transition/validators/interfaces/IValidatorTimelock.sol";
import {AccessControlEnumerablePerChainAddressUpgradeable} from "contracts/state-transition/AccessControlEnumerablePerChainAddressUpgradeable.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

contract GrantChainUpgraderTest is Test {
    GrantChainUpgrader internal script;
    ChainAdminOwnable internal admin;
    ValidatorTimelock internal timelock;
    DummyBridgehub internal bridgehub;
    address internal owner;
    address internal operator;
    address internal chain;
    uint256 internal chainId;

    function setUp() public {
        owner = makeAddr("owner");
        operator = makeAddr("operator");
        chain = makeAddr("chain");
        chainId = block.chainid;
        script = new GrantChainUpgrader();
        admin = new ChainAdminOwnable(owner, address(0));
        bridgehub = new DummyBridgehub();
        bridgehub.setZKChain(chainId, chain);
        timelock = ValidatorTimelock(
            address(
                new TransparentUpgradeableProxy(
                    address(new ValidatorTimelock(address(bridgehub))),
                    address(new ProxyAdmin()),
                    abi.encodeCall(ValidatorTimelock.initialize, (owner, 0))
                )
            )
        );
        // Isolate the chain-discovery getters. The real ChainAdmin, timelock
        // proxy and access-control logic execute every authorization and grant.
        vm.mockCall(chain, abi.encodeCall(IGetters.getChainId, ()), abi.encode(chainId));
        vm.mockCall(chain, abi.encodeCall(IGetters.getAdmin, ()), abi.encode(address(admin)));
        vm.mockCall(chain, abi.encodeCall(IGetters.isValidator, (address(timelock))), abi.encode(true));
    }

    function _prepare() internal view returns (GrantChainUpgrader.Transaction memory) {
        return script.prepare(block.chainid, address(bridgehub), chainId, address(timelock), operator);
    }

    function _execute(GrantChainUpgrader.Transaction memory _transaction) internal {
        vm.prank(_transaction.sender);
        (bool success, bytes memory result) = _transaction.chainAdmin.call(_transaction.data);
        if (!success) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    function test_GrantsOnlyUpgraderThroughOwner() public {
        GrantChainUpgrader.Transaction memory transaction = _prepare();
        assertEq(transaction.sender, owner);
        assertEq(transaction.chainAdmin, address(admin));
        assertEq(transaction.chainAddress, chain);
        assertEq(transaction.role, timelock.UPGRADER_ROLE());
        assertFalse(timelock.hasRole(chain, transaction.role, operator));

        vm.expectEmit(true, true, true, true, address(timelock));
        emit AccessControlEnumerablePerChainAddressUpgradeable.RoleGranted(chain, transaction.role, operator);
        _execute(transaction);

        assertTrue(timelock.hasRole(chain, transaction.role, operator));
        assertEq(timelock.getRoleMemberCount(chain, transaction.role), 1);
        assertEq(timelock.getRoleMember(chain, transaction.role, 0), operator);
        assertFalse(timelock.hasRole(chain, timelock.PRECOMMITTER_ROLE(), operator));
        assertFalse(timelock.hasRole(chain, timelock.COMMITTER_ROLE(), operator));
        assertFalse(timelock.hasRole(chain, timelock.REVERTER_ROLE(), operator));
        assertFalse(timelock.hasRole(chain, timelock.PROVER_ROLE(), operator));
        assertFalse(timelock.hasRole(chain, timelock.EXECUTOR_ROLE(), operator));
        assertFalse(timelock.hasRole(makeAddr("other chain"), transaction.role, operator));
    }

    function test_RunWritesSimulatedWalletRequest() public {
        string memory output = "script-out/grant-upgrader-test.json";
        vm.createDir("script-out", true);
        GrantChainUpgrader.Transaction memory transaction = script.run(
            block.chainid,
            address(bridgehub),
            chainId,
            address(timelock),
            operator,
            output
        );
        string memory json = vm.readFile(output);
        assertEq(vm.parseJsonAddress(json, ".from"), owner);
        assertEq(vm.parseJsonAddress(json, ".to"), address(admin));
        assertEq(vm.parseJsonAddress(json, ".account"), operator);
        assertEq(vm.parseJsonAddress(json, ".chainAddress"), chain);
        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid);
        assertEq(vm.parseJsonUint(json, ".zkChainId"), chainId);
        assertEq(vm.parseJsonUint(json, ".value"), 0);
        assertEq(vm.parseJsonBytes(json, ".data"), transaction.data);
        assertEq(vm.readFile(string.concat(output, ".calldata")), vm.toString(transaction.data));
        assertGt(bytes(vm.readFile(string.concat(output, ".md"))).length, 0);
        assertTrue(timelock.hasRole(chain, transaction.role, operator));
        vm.removeFile(output);
        vm.removeFile(string.concat(output, ".calldata"));
        vm.removeFile(string.concat(output, ".md"));
    }

    function test_RejectsAlreadyGranted() public {
        _execute(_prepare());
        vm.expectRevert(GrantChainUpgrader.AlreadyGranted.selector);
        _prepare();
    }

    function test_RunRejectsSuccessfulCallWithoutGrant() public {
        GrantChainUpgrader.Transaction memory transaction = _prepare();
        // Isolate the postcondition from execution: a successful response from
        // the ChainAdmin must not allow writing a request whose grant was a no-op.
        vm.mockCall(address(admin), transaction.data, bytes(""));
        vm.expectRevert(GrantChainUpgrader.GrantNotApplied.selector);
        script.run(block.chainid, address(bridgehub), chainId, address(timelock), operator, "script-out/no-grant.json");
        assertFalse(timelock.hasRole(chain, transaction.role, operator));
        assertFalse(vm.exists("script-out/no-grant.json"));
    }

    function test_RejectsZeroAccount() public {
        vm.expectRevert(GrantChainUpgrader.InvalidAccount.selector);
        script.prepare(block.chainid, address(bridgehub), chainId, address(timelock), address(0));
    }

    function test_RejectsWrongL1() public {
        vm.expectRevert(GrantChainUpgrader.WrongL1Chain.selector);
        script.prepare(block.chainid + 1, address(bridgehub), chainId, address(timelock), operator);
    }

    function test_RejectsUnknownChain() public {
        bridgehub.setZKChain(chainId, address(0));
        vm.expectRevert(GrantChainUpgrader.InvalidChain.selector);
        _prepare();
    }

    function test_RejectsMismatchedChainId() public {
        vm.mockCall(chain, abi.encodeCall(IGetters.getChainId, ()), abi.encode(chainId + 1));
        vm.expectRevert(GrantChainUpgrader.InvalidChain.selector);
        _prepare();
    }

    function test_RejectsUnregisteredTimelock() public {
        vm.mockCall(chain, abi.encodeCall(IGetters.isValidator, (address(timelock))), abi.encode(false));
        vm.expectRevert(GrantChainUpgrader.InvalidTimelock.selector);
        _prepare();
    }

    function test_RejectsWrongBridgehub() public {
        DummyBridgehub otherBridgehub = new DummyBridgehub();
        otherBridgehub.setZKChain(chainId, chain);
        vm.expectRevert(GrantChainUpgrader.InvalidTimelock.selector);
        script.prepare(block.chainid, address(otherBridgehub), chainId, address(timelock), operator);
    }

    function test_RejectsMissingRoleAdmin() public {
        bytes32 role = timelock.UPGRADER_ROLE();
        bytes32 adminRole = timelock.OPTIONAL_UPGRADER_ADMIN_ROLE();
        vm.prank(address(admin));
        timelock.setRoleAdmin(chain, role, adminRole);
        vm.expectRevert(GrantChainUpgrader.MissingRoleAdmin.selector);
        _prepare();
    }

    function test_UsesCurrentOwnerAfterTransfer() public {
        address nextOwner = makeAddr("next owner");
        vm.prank(owner);
        admin.transferOwnership(nextOwner);
        vm.prank(nextOwner);
        admin.acceptOwnership();
        GrantChainUpgrader.Transaction memory transaction = _prepare();
        assertEq(transaction.sender, nextOwner);
        _execute(transaction);
        assertTrue(timelock.hasRole(chain, transaction.role, operator));
    }

    function test_AllFalseRotationCanSucceedWithoutGranting() public {
        // Regression for the manual payload: success alone did not mean a grant.
        IValidatorTimelock.ValidatorRotationParams memory noRoles;
        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](1);
        calls[0] = IChainAdminOwnable.Call({
            target: address(timelock),
            value: 0,
            data: abi.encodeCall(timelock.addValidatorRoles, (chain, operator, noRoles))
        });
        vm.prank(owner);
        admin.multicall(calls, true);
        assertFalse(timelock.hasRole(chain, timelock.UPGRADER_ROLE(), operator));
        _execute(_prepare());
        assertTrue(timelock.hasRole(chain, timelock.UPGRADER_ROLE(), operator));
    }
}
