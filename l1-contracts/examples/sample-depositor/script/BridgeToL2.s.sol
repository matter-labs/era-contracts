// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

// solhint-disable no-console

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {SampleDepositor} from "../contracts/SampleDepositor.sol";

/// @notice Bridges tokens from a `SampleDepositor` (L1) to an address on a ZK chain.
/// @dev Environment:
/// - `PRIVATE_KEY`: the depositor's owner.
/// - `DEPOSITOR`: the `SampleDepositor` address.
/// - `L2_CHAIN_ID`, `L2_RECEIVER`, `AMOUNT`: destination chain, recipient on it (e.g. a `SampleWithdrawer`) and amount.
/// - `L2_GAS_LIMIT` (optional, default 2,000,000): gas limit of the L2 transaction finalizing the deposit.
/// - `L1_GAS_PRICE_WEI` (optional, default 50 gwei): L1 gas price the L2 gas is quoted at. The quote must not be
///   below the gas price the transaction is mined with; the surplus is refunded on L2.
/// - `REFUND_RECIPIENT` (optional, default: the owner): L2 address refunded the surplus.
contract BridgeToL2 is Script {
    uint256 internal constant DEFAULT_L2_GAS_LIMIT = 2_000_000;
    uint256 internal constant DEFAULT_L1_GAS_PRICE_WEI = 50 gwei;

    function run() external returns (bytes32 canonicalTxHash) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        SampleDepositor depositor = SampleDepositor(vm.envAddress("DEPOSITOR"));
        uint256 chainId = vm.envUint("L2_CHAIN_ID");
        address l2Receiver = vm.envAddress("L2_RECEIVER");
        uint256 amount = vm.envUint("AMOUNT");
        uint256 l2GasLimit = vm.envOr("L2_GAS_LIMIT", DEFAULT_L2_GAS_LIMIT);
        uint256 l1GasPrice = vm.envOr("L1_GAS_PRICE_WEI", DEFAULT_L1_GAS_PRICE_WEI);
        address refundRecipient = vm.envOr("REFUND_RECIPIENT", vm.addr(privateKey));

        uint256 mintValue = depositor.BRIDGEHUB().l2TransactionBaseCost({
            _chainId: chainId,
            _gasPrice: l1GasPrice,
            _l2GasLimit: l2GasLimit,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        });

        vm.startBroadcast(privateKey);
        canonicalTxHash = depositor.bridgeTo{value: mintValue}({
            _chainId: chainId,
            _l2Receiver: l2Receiver,
            _amount: amount,
            _l2GasLimit: l2GasLimit,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _refundRecipient: refundRecipient
        });
        vm.stopBroadcast();

        console2.log("L2 gas paid (wei):", mintValue);
        console2.log("Canonical L1 -> L2 tx hash:");
        console2.logBytes32(canonicalTxHash);
    }
}
