// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IGatewayUtils} from "contracts/script-interfaces/IGatewayUtils.sol";

import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {L2_INTEROP_CENTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {L1InteropHandler} from "contracts/interop/interop-handler/L1InteropHandler.sol";
import {UnsafeBytes} from "contracts/common/libraries/UnsafeBytes.sol";
import {MessageInclusionProof, L2Message} from "contracts/common/Messaging.sol";

/// @notice Finishes a chain's migration from the Gateway back to L1 by executing the CTM-asset withdrawal bundle
/// on L1.
contract GatewayUtils is Script, IGatewayUtils {
    function finishMigrateChainFromGateway(
        address bridgehubAddr,
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
        address l1InteropHandlerAddr = l1Nullifier.l1InteropHandler();

        vm.broadcast();
        L1InteropHandler(l1InteropHandlerAddr).executeBundle(
            UnsafeBytes.readRemainingBytes(message, 1),
            MessageInclusionProof({
                chainId: gatewayChainId,
                l1BatchNumber: l2BatchNumber,
                l2MessageIndex: l2MessageIndex,
                message: L2Message({txNumberInBatch: l2TxNumberInBatch, sender: L2_INTEROP_CENTER_ADDR, data: hex""}),
                proof: merkleProof
            })
        );
    }
}
