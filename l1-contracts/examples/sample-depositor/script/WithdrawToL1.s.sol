// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

// solhint-disable no-console

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {L2_NATIVE_TOKEN_VAULT} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {SampleWithdrawer} from "../contracts/SampleWithdrawer.sol";

/// @notice Withdraws tokens from a `SampleWithdrawer` (ZK chain) to an L1 address.
/// @dev Environment:
/// - `PRIVATE_KEY`: the withdrawer's owner.
/// - `WITHDRAWER`: the `SampleWithdrawer` address.
/// - `AMOUNT`, `L1_RECIPIENT`: amount and L1 recipient.
/// - `L2_TOKEN` or `L1_TOKEN`: the token to withdraw, either by its address on this chain or by its L1 address
///   (resolved through the L2NativeTokenVault; the token must have been bridged in before).
contract WithdrawToL1 is Script {
    function run() external returns (bytes32 bundleHash) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        SampleWithdrawer withdrawer = SampleWithdrawer(vm.envAddress("WITHDRAWER"));
        uint256 amount = vm.envUint("AMOUNT");
        address l1Recipient = vm.envAddress("L1_RECIPIENT");
        address l2Token = vm.envOr("L2_TOKEN", address(0));
        if (l2Token == address(0)) {
            l2Token = L2_NATIVE_TOKEN_VAULT.l2TokenAddress(vm.envAddress("L1_TOKEN"));
        }

        vm.startBroadcast(privateKey);
        bundleHash = withdrawer.withdraw(l2Token, amount, l1Recipient);
        vm.stopBroadcast();

        console2.log("L2 token:", l2Token);
        console2.log("Withdrawal bundle hash:");
        console2.logBytes32(bundleHash);
    }
}
