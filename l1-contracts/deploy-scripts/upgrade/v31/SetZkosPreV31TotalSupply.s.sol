// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {Utils} from "../../utils/Utils.sol";
import {IL1Bridgehub, L2TransactionRequestDirect} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_VERSION_SPECIFIC_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {IL2V31Upgrade} from "contracts/upgrades/IL2V31Upgrade.sol";

/// @notice Script for chain admins to set the pre-V31 total supply on ZKOS chains.
/// @dev This should be run after the V31 upgrade. It sends an L1->L2 transaction that calls
/// @dev ComplexUpgrader.upgrade() -> L2V31Upgrade.setZkosPreV31TotalSupply() -> L2BaseTokenZKOS.setZkosPreV31TotalSupply().
/// @dev The L2V31Upgrade contract is already deployed at L2_VERSION_SPECIFIC_UPGRADER_ADDR during the V31 upgrade.
/// @dev Usage:
/// @dev   BRIDGEHUB=0x... CHAIN_ID=... PRE_V31_TOTAL_SUPPLY=... forge script SetZkosPreV31TotalSupplyScript --broadcast
contract SetZkosPreV31TotalSupplyScript is Script {
    function run() public {
        address bridgehubAddr = vm.envAddress("BRIDGEHUB");
        uint256 chainId = vm.envUint("CHAIN_ID");
        uint256 preV31TotalSupply = vm.envUint("PRE_V31_TOTAL_SUPPLY");
        uint256 l2GasLimit = vm.envOr("L2_GAS_LIMIT", uint256(1_000_000));

        console.log("Bridgehub:", bridgehubAddr);
        console.log("Chain ID:", chainId);
        console.log("Pre-V31 Total Supply:", preV31TotalSupply);
        console.log("L2 Gas Limit:", l2GasLimit);

        IL1Bridgehub bridgehub = IL1Bridgehub(bridgehubAddr);

        // Build the calldata: ComplexUpgrader.upgrade(L2V31Upgrade, setZkosPreV31TotalSupply(totalSupply))
        bytes memory setterCalldata = abi.encodeCall(IL2V31Upgrade.setZkosPreV31TotalSupply, (preV31TotalSupply));
        bytes memory complexUpgraderCalldata = abi.encodeCall(
            IComplexUpgrader.upgrade,
            (L2_VERSION_SPECIFIC_UPGRADER_ADDR, setterCalldata)
        );

        // Calculate L1->L2 tx cost
        uint256 gasPrice = Utils.bytesToUint256(vm.rpc("eth_gasPrice", "[]"));
        uint256 baseCost = bridgehub.l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);

        console.log("Gas Price:", gasPrice);
        console.log("Base Cost:", baseCost);

        L2TransactionRequestDirect memory l2TxRequest = L2TransactionRequestDirect({
            chainId: chainId,
            mintValue: baseCost,
            l2Contract: L2_COMPLEX_UPGRADER_ADDR,
            l2Value: 0,
            l2Calldata: complexUpgraderCalldata,
            l2GasLimit: l2GasLimit,
            l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            factoryDeps: new bytes[](0),
            refundRecipient: msg.sender
        });

        vm.broadcast();
        bridgehub.requestL2TransactionDirect{value: baseCost}(l2TxRequest);

        console.log("L1->L2 transaction sent to set ZKOS pre-V31 total supply");
    }
}
