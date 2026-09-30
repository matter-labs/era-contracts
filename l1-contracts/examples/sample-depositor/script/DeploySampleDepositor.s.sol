// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

// solhint-disable no-console

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {SampleDepositor} from "../contracts/SampleDepositor.sol";

/// @notice Deploys a `SampleDepositor` on L1 and optionally funds it.
/// @dev Environment:
/// - `PRIVATE_KEY`: deployer (becomes the depositor's owner).
/// - `BRIDGEHUB`: the ecosystem's L1 Bridgehub.
/// - `TOKEN` (optional): the ERC20 to bridge, e.g. USDC. When unset a mintable `TestnetERC20Token` is deployed.
/// - `FUND_AMOUNT` (optional): amount to put into the depositor; minted for a fresh test token, transferred from
///   the deployer's balance for an existing one.
contract DeploySampleDepositor is Script {
    function run() external returns (SampleDepositor depositor, IERC20 token) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        IL1Bridgehub bridgehub = IL1Bridgehub(vm.envAddress("BRIDGEHUB"));
        token = IERC20(vm.envOr("TOKEN", address(0)));
        uint256 fundAmount = vm.envOr("FUND_AMOUNT", uint256(0));

        vm.startBroadcast(privateKey);
        bool freshToken = address(token) == address(0);
        if (freshToken) {
            token = new TestnetERC20Token("Sample Token", "SMPL", 18);
        }
        depositor = new SampleDepositor(bridgehub, token);
        if (fundAmount > 0) {
            if (freshToken) {
                TestnetERC20Token(address(token)).mint(address(depositor), fundAmount);
            } else {
                token.transfer(address(depositor), fundAmount);
            }
        }
        vm.stopBroadcast();

        console2.log("Token:", address(token));
        console2.log("SampleDepositor:", address(depositor));
    }
}
