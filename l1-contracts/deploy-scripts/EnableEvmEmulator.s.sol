// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";

import {Call} from "contracts/governance/Common.sol";
import {Utils} from "./Utils.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";

contract EnableEvmEmulator is Script {
    function run() external {
        chainAllowEvmEmulation(vm.envAddress("CHAIN_ADMIN_ADDRESS"), vm.envAddress("CHAIN_DIAMOND_PROXY_ADDRESS"));
    }

    function governanceAllowEvmEmulation(address governor, address target) public {
        IAdmin adminContract = IAdmin(target);
        Utils.executeUpgrade({
            _governor: governor,
            _salt: bytes32(0),
            _target: target,
            _data: abi.encodeCall(adminContract.allowEvmEmulation, ()),
            _value: 0,
            _delay: 0
        });
    }

    function chainAllowEvmEmulation(address chainAdmin, address target) public {
        IChainAdmin admin = IChainAdmin(chainAdmin);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: target, value: 0, data: abi.encodeCall(IAdmin.allowEvmEmulation, ())});

        vm.startBroadcast();
        admin.multicall(calls, true);
        vm.stopBroadcast();
    }
}
