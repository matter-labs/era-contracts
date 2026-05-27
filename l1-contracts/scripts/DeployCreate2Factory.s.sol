// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// solhint-disable no-console
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/// @notice Deploy the Arachnid deterministic-deployment-proxy (CREATE2 factory)
///         at the canonical address 0x4e59b44847b379578588920cA78FbF26c0B4956C.
///
/// The factory is deployed by funding the presigned deployer EOA and then
/// broadcasting the presigned raw transaction. Two steps:
///
///   1. Fund 0x3fAB184622Dc19b6109349B94811493BF2a45362 with enough native
///      token to cover gas (gasPrice=100gwei × gasLimit=100000 = 0.01 native).
///   2. Broadcast the presigned raw tx via eth_sendRawTransaction.
///
/// Usage:
///   # Step 1: fund the deployer
///   forge script scripts/DeployCreate2Factory.s.sol:DeployCreate2Factory \
///     --rpc-url $RPC_URL --broadcast --private-key $PK
///
///   # Step 2: publish the presigned tx (forge can't do this, use cast)
///   cast publish "0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222" \
///     --rpc-url $RPC_URL
///
/// See https://github.com/Arachnid/deterministic-deployment-proxy
contract DeployCreate2Factory is Script {
    error FundingFailed();

    address internal constant PRESIGNED_DEPLOYER = 0x3fAB184622Dc19b6109349B94811493BF2a45362;
    address internal constant EXPECTED_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// Enough to cover gasPrice=100gwei × gasLimit=100000 with margin.
    uint256 internal constant FUND_AMOUNT = 0.1 ether;

    function run() external {
        if (EXPECTED_FACTORY.code.length > 0) {
            return;
        }

        uint256 balance = PRESIGNED_DEPLOYER.balance;

        if (balance < FUND_AMOUNT) {
            uint256 needed = FUND_AMOUNT - balance;

            vm.broadcast();
            (bool ok, ) = PRESIGNED_DEPLOYER.call{value: needed}("");
            if (!ok) revert FundingFailed();
        }

        console.log("");
        console.log("Now run step 2 manually:");
        console.log(
            "cast publish \"0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222\" --rpc-url <RPC_URL>"
        );
    }
}
