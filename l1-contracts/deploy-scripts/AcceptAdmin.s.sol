// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {Call} from "contracts/governance/Common.sol";
import {Utils} from "./Utils.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {L2WrappedBaseTokenStore} from "contracts/bridge/L2WrappedBaseTokenStore.sol";

bytes32 constant SET_TOKEN_MULTIPLIER_SETTER_ROLE = keccak256("SET_TOKEN_MULTIPLIER_SETTER_ROLE");

contract AcceptAdmin is Script {
    using stdToml for string;

    struct Config {
        address admin;
        address governor;
    }

    Config internal config;

    function initConfig() public {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-accept-admin.toml");
        string memory toml = vm.readFile(path);
        config.admin = toml.readAddress("$.target_addr");
        config.governor = toml.readAddress("$.governor");
    }

    // This function should be called by the owner to accept the admin role
    function governanceAcceptOwner(address governor, address target) public {
        Ownable2Step adminContract = Ownable2Step(target);
        Utils.executeUpgrade({
            _governor: governor,
            _salt: bytes32(0),
            _target: target,
            _data: abi.encodeCall(adminContract.acceptOwnership, ()),
            _value: 0,
            _delay: 0
        });
    }

    // This function should be called by the owner to accept the admin role
    function governanceAcceptAdmin(address governor, address target) public {
        IZKChain adminContract = IZKChain(target);
        Utils.executeUpgrade({
            _governor: governor,
            _salt: bytes32(0),
            _target: target,
            _data: abi.encodeCall(adminContract.acceptAdmin, ()),
            _value: 0,
            _delay: 0
        });
    }

    // This function should be called by the owner to accept the admin role
    function chainAdminAcceptAdmin(ChainAdmin chainAdmin, address target) public {
        IZKChain adminContract = IZKChain(target);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: target, value: 0, data: abi.encodeCall(adminContract.acceptAdmin, ())});

        vm.startBroadcast();
        chainAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }

    // This function should be called by the owner to update token multiplier setter role
    function chainSetTokenMultiplierSetter(
        address chainAdmin,
        address accessControlRestriction,
        address diamondProxyAddress,
        address setter
    ) public {
        if (accessControlRestriction == address(0)) {
            _chainSetTokenMultiplierSetterOwnable(chainAdmin, setter);
        } else {
            _chainSetTokenMultiplierSetterLatestChainAdmin(accessControlRestriction, diamondProxyAddress, setter);
        }
    }

    function _chainSetTokenMultiplierSetterOwnable(address chainAdmin, address setter) internal {
        IChainAdminOwnable admin = IChainAdminOwnable(chainAdmin);

        vm.startBroadcast();
        admin.setTokenMultiplierSetter(setter);
        vm.stopBroadcast();
    }

    function _chainSetTokenMultiplierSetterLatestChainAdmin(
        address accessControlRestriction,
        address diamondProxyAddress,
        address setter
    ) internal {
        AccessControlRestriction restriction = AccessControlRestriction(accessControlRestriction);

        if (
            restriction.requiredRoles(diamondProxyAddress, IAdmin.setTokenMultiplier.selector) !=
            SET_TOKEN_MULTIPLIER_SETTER_ROLE
        ) {
            vm.startBroadcast();
            restriction.setRequiredRoleForCall(
                diamondProxyAddress,
                IAdmin.setTokenMultiplier.selector,
                SET_TOKEN_MULTIPLIER_SETTER_ROLE
            );
            vm.stopBroadcast();
        }

        if (!restriction.hasRole(SET_TOKEN_MULTIPLIER_SETTER_ROLE, setter)) {
            vm.startBroadcast();
            restriction.grantRole(SET_TOKEN_MULTIPLIER_SETTER_ROLE, setter);
            vm.stopBroadcast();
        }
    }

    function governanceExecuteCalls(bytes memory callsToExecute, address governanceAddr) public {
        IGovernance governance = IGovernance(governanceAddr);
        Ownable2Step ownable = Ownable2Step(governanceAddr);

        Call[] memory calls = abi.decode(callsToExecute, (Call[]));

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: bytes32(0)
        });

        vm.startBroadcast(ownable.owner());
        governance.scheduleTransparent(operation, 0);
        // We assume that the total value is 0
        governance.execute{value: 0}(operation);
        vm.stopBroadcast();
    }

    function adminExecuteUpgrade(
        bytes memory diamondCut,
        address adminAddr,
        address accessControlRestriction,
        address chainDiamondProxy
    ) public {
        uint256 oldProtocolVersion = IZKChain(chainDiamondProxy).getProtocolVersion();
        Diamond.DiamondCutData memory upgradeCutData = abi.decode(diamondCut, (Diamond.DiamondCutData));

        Utils.adminExecute(
            adminAddr,
            accessControlRestriction,
            chainDiamondProxy,
            abi.encodeCall(IAdmin.upgradeChainFromVersion, (oldProtocolVersion, upgradeCutData)),
            0
        );
    }

    function adminScheduleUpgrade(
        address adminAddr,
        address accessControlRestriction,
        uint256 newProtocolVersion,
        uint256 timestamp
    ) public {
        Utils.adminExecute(
            adminAddr,
            accessControlRestriction,
            adminAddr,
            // We do instant upgrades, but obviously it should be different in prod
            abi.encodeCall(ChainAdmin.setUpgradeTimestamp, (newProtocolVersion, timestamp)),
            0
        );
    }

    function setDAValidatorPair(
        ChainAdmin chainAdmin,
        address target,
        address l1DaValidator,
        address l2DaValidator
    ) public {
        IZKChain adminContract = IZKChain(target);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: target,
            value: 0,
            data: abi.encodeCall(adminContract.setDAValidatorPair, (l1DaValidator, l2DaValidator))
        });

        vm.startBroadcast();
        chainAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }

    function makePermanentRollup(ChainAdmin chainAdmin, address target) public {
        IZKChain adminContract = IZKChain(target);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: target, value: 0, data: abi.encodeCall(adminContract.makePermanentRollup, ())});

        vm.startBroadcast();
        chainAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }

    function updateValidator(
        address adminAddr,
        address accessControlRestriction,
        address validatorTimelock,
        uint256 chainId,
        address validatorAddress,
        bool addValidator
    ) public {
        bytes memory data;
        // The interface should be compatible with both the new and the old ValidatorTimelock
        if (addValidator) {
            data = abi.encodeCall(ValidatorTimelock.addValidator, (chainId, validatorAddress));
        } else {
            data = abi.encodeCall(ValidatorTimelock.removeValidator, (chainId, validatorAddress));
        }

        Utils.adminExecute(adminAddr, accessControlRestriction, validatorTimelock, data, 0);
    }

    /// @notice Adds L2WrappedBaseToken of a chain to the store.
    /// @param storeAddress THe address of the `L2WrappedBaseTokenStore`.
    /// @param ecosystemAdmin The address of the ecosystem admin contract.
    /// @param chainId The chain id of the chain.
    /// @param l2WBaseToken The address of the L2WrappedBaseToken.
    function addL2WethToStore(
        address storeAddress,
        ChainAdmin ecosystemAdmin,
        uint256 chainId,
        address l2WBaseToken
    ) public {
        L2WrappedBaseTokenStore l2WrappedBaseTokenStore = L2WrappedBaseTokenStore(storeAddress);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: storeAddress,
            value: 0,
            data: abi.encodeCall(l2WrappedBaseTokenStore.initializeChain, (chainId, l2WBaseToken))
        });

        vm.startBroadcast();
        ecosystemAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }
}
