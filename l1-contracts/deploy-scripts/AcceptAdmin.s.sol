// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {Utils} from "./Utils.sol";

contract AcceptAdmin is Script {
    // This function should be called by the owner to accept the owner role
    function acceptOwner(address governor, address target) public {
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
    function acceptAdmin(address payable _admin, address _target) public {
        IZkSyncHyperchain hyperchain = IZkSyncHyperchain(_target);
        ChainAdmin chainAdmin = ChainAdmin(_admin);

        IChainAdmin.Call[] memory calls = new IChainAdmin.Call[](1);
        calls[0] = IChainAdmin.Call({target: _target, value: 0, data: abi.encodeCall(hyperchain.acceptAdmin, ())});

        vm.startBroadcast();
        chainAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }

    function setDAValidatorPair(
        address payable _admin,
        address diamondProxyAddress,
        address l1DAValidatorAddress, 
        address l2DAValidatorAddress
    ) public {
        ChainAdmin chainAdmin = ChainAdmin(_admin);

        ChainAdmin.Call[] memory calls = new ChainAdmin.Call[](1);
        calls[0] = IChainAdmin.Call({target: diamondProxyAddress, value: 0, data: abi.encodeCall(AdminFacet.setDAValidatorPair, (l1DAValidatorAddress, l2DAValidatorAddress))});

        vm.startBroadcast();
        chainAdmin.multicall(calls, true);
        vm.stopBroadcast();  
    }
}