// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
import {IGatewayUtils} from "contracts/script-interfaces/IGatewayUtils.sol";

// It's required to disable lints to force the compiler to compile the contracts
// solhint-disable no-unused-import

import {BridgehubBurnCTMAssetData} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Utils} from "../utils/Utils.sol";

import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {FinalizeL1DepositParams, IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {TxStatus, ConfirmTransferResultData} from "contracts/common/Messaging.sol";

/// @notice Scripts that is responsible for preparing the chain to become a gateway
contract GatewayUtils is Script, IGatewayUtils {
    struct FinishMigrateChainToGatewayParams {
        address bridgehubAddr;
        bytes gatewayDiamondCutData;
        uint256 migratingChainId;
        uint256 gatewayChainId;
        bytes32 l2TxHash;
        uint256 l2BatchNumber;
        uint256 l2MessageIndex;
        uint16 l2TxNumberInBatch;
        bytes32[] merkleProof;
        TxStatus txStatus;
    }

    function finishMigrateChainToGateway(
        address bridgehubAddr,
        bytes memory gatewayDiamondCutData,
        uint256 migratingChainId,
        uint256 gatewayChainId,
        bytes32 l2TxHash,
        uint256 l2BatchNumber,
        uint256 l2MessageIndex,
        uint16 l2TxNumberInBatch,
        bytes32[] calldata merkleProof,
        TxStatus txStatus
    ) public {
        _finishMigrateChainToGatewayInner(
            FinishMigrateChainToGatewayParams({
                bridgehubAddr: bridgehubAddr,
                gatewayDiamondCutData: gatewayDiamondCutData,
                migratingChainId: migratingChainId,
                gatewayChainId: gatewayChainId,
                l2TxHash: l2TxHash,
                l2BatchNumber: l2BatchNumber,
                l2MessageIndex: l2MessageIndex,
                l2TxNumberInBatch: l2TxNumberInBatch,
                merkleProof: merkleProof,
                txStatus: txStatus
            })
        );
    }

    // Using struct for input to avoid stack too deep errors
    // The outer function does not expect it as input rightaway for easier encoding in zkstack Rust.
    function _finishMigrateChainToGatewayInner(FinishMigrateChainToGatewayParams memory data) private {
        IL1Bridgehub bridgehub = IL1Bridgehub(data.bridgehubAddr);
        address assetRouter = address(bridgehub.assetRouter());
        IL1Nullifier l1Nullifier = L1AssetRouter(assetRouter).L1_NULLIFIER();

        bytes32 assetId = bridgehub.ctmAssetIdFromChainId(data.migratingChainId);
        address chainAdmin = IZKChain(bridgehub.getZKChain(data.migratingChainId)).getAdmin();

        bytes memory transferData = abi.encode(
            BridgehubBurnCTMAssetData({
                chainId: data.migratingChainId,
                ctmData: abi.encode(AddressAliasHelper.applyL1ToL2Alias(chainAdmin), data.gatewayDiamondCutData),
                chainData: abi.encode(IZKChain(bridgehub.getZKChain(data.migratingChainId)).getProtocolVersion())
            })
        );

        vm.broadcast();
        l1Nullifier.bridgeConfirmTransferResult(
            ConfirmTransferResultData({
                _chainId: data.gatewayChainId,
                _depositSender: chainAdmin,
                _assetId: assetId,
                _assetData: transferData,
                _l2TxHash: data.l2TxHash,
                _l2BatchNumber: data.l2BatchNumber,
                _l2MessageIndex: data.l2MessageIndex,
                _l2TxNumberInBatch: data.l2TxNumberInBatch,
                _merkleProof: data.merkleProof,
                _txStatus: data.txStatus
            })
        );
    }

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
