// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {L2AdminFactory} from "contracts/governance/L2AdminFactory.sol";
import {DummyRestriction} from "contracts/dev-contracts/DummyRestriction.sol";
import {NotARestriction} from "contracts/common/L1ContractErrors.sol";

/// @dev `L2AdminFactory` is deployed on L2, but it neither reads L2-only state nor relies on
/// EraVM deployment semantics, so it is exercised here as a plain unit test. The `allowL2Admin`
/// counterpart on `PermanentRestriction` is covered in `PermanentRestriction.t.sol`.
contract L2AdminFactoryTest is Test {
    event AdminDeployed(address indexed admin);

    address internal validRestriction1;
    address internal validRestriction2;
    address internal invalidRestriction;

    function setUp() public {
        validRestriction1 = address(new DummyRestriction(true));
        validRestriction2 = address(new DummyRestriction(true));
        invalidRestriction = address(new DummyRestriction(false));
    }

    function test_RevertWhen_InvalidInitialRestriction() public {
        address[] memory requiredRestrictions = new address[](1);
        requiredRestrictions[0] = invalidRestriction;

        vm.expectRevert(abi.encodeWithSelector(NotARestriction.selector, invalidRestriction));
        new L2AdminFactory(requiredRestrictions);
    }

    function test_RevertWhen_InvalidAdditionalRestriction() public {
        address[] memory requiredRestrictions = new address[](1);
        requiredRestrictions[0] = validRestriction1;
        L2AdminFactory factory = new L2AdminFactory(requiredRestrictions);

        address[] memory additionalRestrictions = new address[](1);
        additionalRestrictions[0] = invalidRestriction;

        vm.expectRevert(abi.encodeWithSelector(NotARestriction.selector, invalidRestriction));
        factory.deployAdmin(additionalRestrictions);
    }

    /// @dev The deployed admin must carry the factory's required restrictions first, then the
    /// caller-supplied ones — that ordering is what makes the required set unavoidable.
    function test_deployAdmin_AppliesRequiredAndAdditionalRestrictions() public {
        address[] memory requiredRestrictions = new address[](1);
        requiredRestrictions[0] = validRestriction1;
        L2AdminFactory factory = new L2AdminFactory(requiredRestrictions);
        assertEq(factory.requiredRestrictions(0), validRestriction1, "required restriction not stored");

        address[] memory additionalRestrictions = new address[](1);
        additionalRestrictions[0] = validRestriction2;

        vm.recordLogs();
        address admin = factory.deployAdmin(additionalRestrictions);

        address[] memory applied = ChainAdmin(payable(admin)).getRestrictions();
        assertEq(applied.length, 2, "unexpected restriction count");
        assertEq(applied[0], validRestriction1, "required restriction missing");
        assertEq(applied[1], validRestriction2, "additional restriction missing");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawAdminDeployed;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == AdminDeployed.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), admin, "AdminDeployed carries wrong admin");
                sawAdminDeployed = true;
            }
        }
        assertTrue(sawAdminDeployed, "AdminDeployed not emitted");
    }

    /// @dev Edge case: no additional restrictions still yields an admin bound by the required set.
    function test_deployAdmin_NoAdditionalRestrictions() public {
        address[] memory requiredRestrictions = new address[](1);
        requiredRestrictions[0] = validRestriction1;
        L2AdminFactory factory = new L2AdminFactory(requiredRestrictions);

        address admin = factory.deployAdmin(new address[](0));

        address[] memory applied = ChainAdmin(payable(admin)).getRestrictions();
        assertEq(applied.length, 1, "unexpected restriction count");
        assertEq(applied[0], validRestriction1, "required restriction missing");
    }
}
