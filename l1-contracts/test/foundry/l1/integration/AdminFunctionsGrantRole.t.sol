// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";

import {AdminFunctions} from "deploy-scripts/AdminFunctions.s.sol";
import {RoleAccessDenied} from "contracts/common/L1ContractErrors.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
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

    function test_grantsOnlyTheGivenRole() public {
        bytes32 upgraderRole = validatorTimelock.UPGRADER_ROLE();
        vm.expectEmit(true, true, true, true, address(validatorTimelock));
        emit AccessControlEnumerablePerChainAddressUpgradeable.RoleGranted(chain, upgraderRole, operator);
        _grant(address(chainAdmin), upgraderRole);

        assertTrue(validatorTimelock.hasRole(chain, upgraderRole, operator), "upgrader role");
        assertFalse(validatorTimelock.hasRole(chain, validatorTimelock.COMMITTER_ROLE(), operator), "committer role");
        assertFalse(validatorTimelock.hasRole(chain, validatorTimelock.EXECUTOR_ROLE(), operator), "executor role");
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
