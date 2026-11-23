// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";

import {AdminFunctions} from "deploy-scripts/AdminFunctions.s.sol";
import {RoleAccessDenied} from "contracts/common/L1ContractErrors.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {AccessControlEnumerablePerChainAddressUpgradeable} from "contracts/state-transition/AccessControlEnumerablePerChainAddressUpgradeable.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";

/// @notice `AdminFunctions.grantValidatorTimelockRole` on a deployed ecosystem, through an Ownable ChainAdmin.
contract AdminFunctionsGrantRoleTest is L1ContractDeployer, ZKChainDeployer {
    AdminFunctions internal adminFunctions;
    ValidatorTimelock internal validatorTimelock;
    ChainAdminOwnable internal chainAdmin;
    uint256 internal chainId;
    address internal chain;
    address internal chainAdminOwner = makeAddr("chainAdminOwner");
    address internal operator = makeAddr("operator");

    function setUp() public {
        _deployL1Contracts();
        _deployEra();
        chainId = zkChainIds[0];
        chain = addresses.bridgehub.getZKChain(chainId);
        validatorTimelock = ValidatorTimelock(addresses.chainTypeManager.validatorTimelockPostV29());
        adminFunctions = new AdminFunctions();

        // The test chain's admin is an EOA; hand it to an Ownable ChainAdmin, as on real chains.
        chainAdmin = new ChainAdminOwnable(chainAdminOwner, address(0));
        vm.prank(IZKChain(chain).getAdmin());
        IAdmin(chain).setPendingAdmin(address(chainAdmin));
        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](1);
        calls[0] = IChainAdminOwnable.Call({target: chain, value: 0, data: abi.encodeCall(IAdmin.acceptAdmin, ())});
        vm.prank(chainAdminOwner);
        chainAdmin.multicall(calls, true);
    }

    /// @dev "Only": exactly one RoleGranted, for this role, so no other role (operator or admin) is granted.
    function test_grantsOnlyTheGivenRole() public {
        bytes32 upgraderRole = validatorTimelock.UPGRADER_ROLE();
        vm.recordLogs();
        _grant(address(chainAdmin), upgraderRole);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 roleGranted = AccessControlEnumerablePerChainAddressUpgradeable.RoleGranted.selector;
        uint256 granted;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != roleGranted) continue;
            ++granted;
            assertEq(logs[i].emitter, address(validatorTimelock), "emitter");
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(chain))), "chain");
            assertEq(logs[i].topics[2], upgraderRole, "role");
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(operator))), "account");
        }
        assertEq(granted, 1, "RoleGranted count");
        assertTrue(validatorTimelock.hasRole(chain, upgraderRole, operator), "upgrader role");
    }

    /// @dev If the timelock isn't a validator of the diamond, the diamond rejects everything it forwards, so the
    ///      role would be useless. Here the CTM's owner removes it, as `ChainTypeManager.setValidator` allows.
    function test_revertsIfTheTimelockIsNotAValidatorOfTheChain() public {
        vm.prank(IOwnable(address(addresses.chainTypeManager)).owner());
        addresses.chainTypeManager.setValidator(chainId, address(validatorTimelock), false);
        assertFalse(IGetters(chain).isValidator(address(validatorTimelock)), "still a validator");

        bytes32 upgraderRole = validatorTimelock.UPGRADER_ROLE();
        vm.expectRevert("ValidatorTimelock is not a validator of the chain");
        _grant(address(chainAdmin), upgraderRole);
        assertFalse(validatorTimelock.hasRole(chain, upgraderRole, operator), "upgrader role");
    }

    function test_revertsForAnUnregisteredChain() public {
        uint256 unregisteredChainId = chainId + 1;
        assertEq(addresses.bridgehub.getZKChain(unregisteredChainId), address(0), "registered");
        bytes32 upgraderRole = validatorTimelock.UPGRADER_ROLE();
        vm.expectRevert("Chain not registered on the bridgehub");
        adminFunctions.grantValidatorTimelockRole({
            _bridgehub: address(addresses.bridgehub),
            _chainId: unregisteredChainId,
            _adminAddr: address(chainAdmin),
            _accessControlRestriction: address(0),
            _validatorTimelock: address(validatorTimelock),
            _role: upgraderRole,
            _account: operator
        });
    }

    /// @dev The timelock's per-chain grantRole would grant the role to the zero address.
    function test_revertsForTheZeroAccount() public {
        bytes32 upgraderRole = validatorTimelock.UPGRADER_ROLE();
        // The fixture already gives address(0) the operator roles, so compare with the state before the call.
        uint256 membersBefore = validatorTimelock.getRoleMemberCount(chain, upgraderRole);
        bool zeroHadRole = validatorTimelock.hasRole(chain, upgraderRole, address(0));
        vm.expectRevert("Account is the zero address");
        adminFunctions.grantValidatorTimelockRole({
            _bridgehub: address(addresses.bridgehub),
            _chainId: chainId,
            _adminAddr: address(chainAdmin),
            _accessControlRestriction: address(0),
            _validatorTimelock: address(validatorTimelock),
            _role: upgraderRole,
            _account: address(0)
        });
        assertEq(validatorTimelock.getRoleMemberCount(chain, upgraderRole), membersBefore, "upgrader role members");
        assertEq(validatorTimelock.hasRole(chain, upgraderRole, address(0)), zeroHadRole, "zero address's role");
    }

    /// @dev A ChainAdmin that is not the chain's admin is not the role's admin on the timelock.
    function test_revertsFromAnotherChainAdmin() public {
        ChainAdminOwnable otherAdmin = new ChainAdminOwnable(chainAdminOwner, address(0));
        bytes32 upgraderRole = validatorTimelock.UPGRADER_ROLE();
        bytes32 adminRole = validatorTimelock.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, chain, adminRole, address(otherAdmin)));
        _grant(address(otherAdmin), upgraderRole);
        assertFalse(validatorTimelock.hasRole(chain, upgraderRole, operator), "upgrader role");
    }

    function _grant(address _chainAdmin, bytes32 _role) internal {
        adminFunctions.grantValidatorTimelockRole({
            _bridgehub: address(addresses.bridgehub),
            _chainId: chainId,
            _adminAddr: _chainAdmin,
            _accessControlRestriction: address(0),
            _validatorTimelock: address(validatorTimelock),
            _role: _role,
            _account: operator
        });
    }
}
