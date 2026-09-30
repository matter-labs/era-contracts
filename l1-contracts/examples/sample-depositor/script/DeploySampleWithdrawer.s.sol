// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

// solhint-disable no-console

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {SampleWithdrawer} from "../contracts/SampleWithdrawer.sol";

/// @notice Deploys a `SampleWithdrawer` on a ZK chain.
/// @dev Environment: `PRIVATE_KEY`, the deployer (becomes the withdrawer's owner).
contract DeploySampleWithdrawer is Script {
    function run() external returns (SampleWithdrawer withdrawer) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(privateKey);
        withdrawer = new SampleWithdrawer();
        vm.stopBroadcast();

        console2.log("SampleWithdrawer:", address(withdrawer));
    }
}
