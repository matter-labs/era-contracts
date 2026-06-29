// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Utils} from "../utils/Utils.sol";

import {stdToml} from "forge-std/StdToml.sol";
import {IProtocolUpgradeHandler} from "./interfaces/IProtocolUpgradeHandler.sol";
import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

contract SecurityCouncilEmergencyStageUpgrade is Script {
    using stdToml for string;

    function run() external {
        // Insert the address of the protocol upgrade handler here.
        IProtocolUpgradeHandler protocolUpgradeHandler = IProtocolUpgradeHandler(
            vm.envAddress("PROTOCOL_UPGRADE_HANDLER")
        );
        // Insert the private key of the stage governance
        Vm.Wallet memory wallet = vm.createWallet(uint256(vm.envBytes32("PRIVATE_KEY")));

        IProtocolUpgradeHandler.Call[] memory _calls = IProtocolUpgradeHandler.Call[](0);

        Utils.executeEmergencyProtocolUpgrade(protocolUpgradeHandler, wallet, _calls, bytes32(0));
    }
}
