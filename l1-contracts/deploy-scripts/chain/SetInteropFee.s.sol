// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";
import {ISetInteropFee} from "contracts/script-interfaces/ISetInteropFee.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {Call} from "contracts/governance/Common.sol";

contract SetInteropFee is Script, ISetInteropFee {
    function setInteropFee(address chainAdmin, address target, uint256 fee) public {
        IChainAdmin admin = IChainAdmin(chainAdmin);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: target, value: 0, data: abi.encodeCall(IAdmin.setInteropFee, (fee))});

        vm.startBroadcast();
        admin.multicall(calls, true);
        vm.stopBroadcast();
    }
}
