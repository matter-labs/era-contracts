// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IGatewayUtils} from "contracts/script-interfaces/IGatewayUtils.sol";

// It's required to disable lints to force the compiler to compile the contracts
// solhint-disable no-unused-import

import {BridgehubBurnCTMAssetData, IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {L2_BRIDGEHUB_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Utils} from "../utils/Utils.sol";

import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {FinalizeL1DepositParams, IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {ConfirmTransferResultData, TxStatus} from "contracts/common/Messaging.sol";
import {GetDiamondCutData} from "../utils/GetDiamondCutData.sol";

/// @notice Scripts that is responsible for preparing the chain to become a gateway
contract GatewayUtils is Script, IGatewayUtils {
    struct FinishMigrateChainToGatewayParams {
        address bridgehubAddr;
        uint256 migratingChainId;
        uint256 gatewayChainId;
        // Gateway L2 RPC URL — the inner resolves the diamond cut data by
        // fork-switching into gateway L2 (the gateway-side CTM only exists
        // there). Resolving inside the inner keeps the public entrypoint's
        // local variable count low (avoids stack-too-deep).
        string gatewayRpcUrl;
        bytes32 l2TxHash;
        uint256 l2BatchNumber;
        uint256 l2MessageIndex;
        uint16 l2TxNumberInBatch;
        bytes32[] merkleProof;
        TxStatus txStatus;
    }

    function finishMigrateChainToGateway(
        address bridgehubAddr,
        uint256 migratingChainId,
        uint256 gatewayChainId,
        string calldata gatewayRpcUrl,
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
                migratingChainId: migratingChainId,
                gatewayChainId: gatewayChainId,
                gatewayRpcUrl: gatewayRpcUrl,
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
        bytes memory gatewayDiamondCutData = GetDiamondCutData.readFromGateway(data.gatewayRpcUrl, assetId);
        bytes memory transferData = abi.encode(
            BridgehubBurnCTMAssetData({
                chainId: data.migratingChainId,
                ctmData: abi.encode(AddressAliasHelper.applyL1ToL2Alias(chainAdmin), gatewayDiamondCutData),
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

    /// @notice Writes CTM `forceDeploymentsData` (from `NewChainCreationParams` logs) to a TOML fragment
    /// used to build the `gateway-vote-preparation` input. Set env `FORCE_DEPLOYMENTS_DUMP_TOML_REL_PATH`
    /// to a path relative to project root (e.g. `/script-out/force-deployments-dump.toml`).
    function dumpForceDeployments(address _ctm) external {
        (, bytes memory forceDeploymentsData) = GetDiamondCutData.getDiamondCutAndForceDeployment(_ctm, false);

        string memory root = vm.projectRoot();
        string memory rel = vm.envString("FORCE_DEPLOYMENTS_DUMP_TOML_REL_PATH");
        string memory path = string.concat(root, rel);

        string memory toml = vm.serializeBytes("root", "force_deployments_data", forceDeploymentsData);
        vm.writeToml(toml, path);
    }
}
