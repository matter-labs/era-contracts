// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";

// It's required to disable lints to force the compiler to compile the contracts
// solhint-disable no-unused-import

import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";

import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Utils} from "../utils/Utils.sol";

import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";

import {FinalizeL1DepositParams, IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";

/// @notice Scripts that is responsible for preparing the chain to become a gateway
contract GatewayUtils is Script {
    function finishMigrateChainFromGateway(
        address bridgehubAddr,
        uint256 migratingChainId,
        uint256 gatewayChainId,
        uint256 l2BatchNumber,
        uint256 l2MessageIndex,
        uint16 l2TxNumberInBatch,
        bytes memory message,
        bytes32[] memory merkleProof
    ) public {
        IL1Bridgehub bridgehub = IL1Bridgehub(bridgehubAddr);

        address assetRouter = address(bridgehub.assetRouter());
        IL1Nullifier l1Nullifier = L1AssetRouter(assetRouter).L1_NULLIFIER();

        vm.broadcast();
        l1Nullifier.finalizeDeposit(
            FinalizeL1DepositParams({
                chainId: gatewayChainId,
                l2BatchNumber: l2BatchNumber,
                l2MessageIndex: l2MessageIndex,
                l2Sender: L2_ASSET_ROUTER_ADDR,
                l2TxNumberInBatch: l2TxNumberInBatch,
                message: message,
                merkleProof: merkleProof
            })
        );
    }
}
