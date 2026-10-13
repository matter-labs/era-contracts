// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SystemContractProxyAdmin} from "contracts/l2-upgrades/SystemContractProxyAdmin.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ConstructorsNotSupported, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {RAND_ADDRESS} from "test/foundry/TestConstants.sol";

/// @notice Access control of the L2 `SystemContractProxyAdmin`: it is placed at genesis without running a
/// constructor (etched here, as on L2), and only the ComplexUpgrader may set its owner.
contract SystemContractProxyAdminTest is Test {
    address internal proxyAdmin;

    function setUp() public {
        proxyAdmin = makeAddr("proxyAdmin");
        vm.etch(proxyAdmin, type(SystemContractProxyAdmin).runtimeCode);
    }

    function test_ConstructorReverts() public {
        vm.expectRevert(ConstructorsNotSupported.selector);
        new SystemContractProxyAdmin();
    }

    function test_ForceSetOwner_ByComplexUpgrader() public {
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        SystemContractProxyAdmin(proxyAdmin).forceSetOwner(RAND_ADDRESS);

        assertEq(SystemContractProxyAdmin(proxyAdmin).owner(), RAND_ADDRESS, "owner not set");
    }

    function testFuzz_RevertWhen_ForceSetOwnerByAnyoneElse(address _caller, address _newOwner) public {
        vm.assume(_caller != L2_COMPLEX_UPGRADER_ADDR);

        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        SystemContractProxyAdmin(proxyAdmin).forceSetOwner(_newOwner);

        assertEq(SystemContractProxyAdmin(proxyAdmin).owner(), address(0), "owner changed");
    }
}
