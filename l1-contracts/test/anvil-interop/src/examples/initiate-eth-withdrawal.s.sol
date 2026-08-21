// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {AmountMustBeGreaterThanZero, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L2_INTEROP_CENTER, L2_NATIVE_TOKEN_VAULT} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

/// @notice Starts an ETH withdrawal on L2 and publishes its interop bundle for later L1 finalization.
contract InitiateEthWithdrawal is Script {
    function run() external returns (bytes32 bundleHash) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        uint256 l1ChainId = vm.envUint("L1_CHAIN_ID");
        address l1Recipient = vm.envAddress("L1_RECIPIENT");
        uint256 amount = vm.envUint("WITHDRAWAL_AMOUNT_WEI");
        bytes32 salt = vm.envBytes32("WITHDRAWAL_SALT");

        if (l1Recipient == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }

        bytes32 baseTokenAssetId = L2_NATIVE_TOKEN_VAULT.BASE_TOKEN_ASSET_ID();
        bytes memory transferData = DataEncoding.encodeBridgeBurnData(amount, l1Recipient, address(0));
        InteropCallStarter[] memory calls =
            DataEncoding.encodeInteropBaseTokenWithdrawalCallStarters(baseTokenAssetId, transferData, amount);

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (salt));

        vm.startBroadcast(privateKey);
        bundleHash = L2_INTEROP_CENTER.sendBundle{value: amount}(
            InteroperableAddress.formatEvmV1(l1ChainId), calls, bundleAttributes
        );
        vm.stopBroadcast();

        console2.log("Withdrawal bundle hash:");
        console2.logBytes32(bundleHash);
    }
}
