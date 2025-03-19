// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_BRIDGEHUB_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "contracts/common/Config.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {BridgehubMintCTMAssetData, BridgehubBurnCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {SystemContractsArgs} from "./Utils.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {ZKChainCommitment} from "contracts/common/Config.sol";

abstract contract L2GatewayTestAbstract is Test, SharedL2ContractDeployer {
    function test_gatewayShouldFinalizeDeposit() public {
        finalizeDeposit();
        require(l2Bridgehub.ctmAssetIdFromAddress(address(chainTypeManager)) == ctmAssetId, "ctmAssetId mismatch");
        require(l2Bridgehub.ctmAssetIdFromChainId(mintChainId) == ctmAssetId, "ctmAssetIdFromChainId mismatch");

        address diamondProxy = l2Bridgehub.getZKChain(mintChainId);
        require(!GettersFacet(diamondProxy).isPriorityQueueActive(), "Priority queue must not be active");
    }

    function test_gatewayNonEmptyPriorityQueueMigration() public {
        ZKChainCommitment memory commitment = abi.decode(exampleChainCommitment, (ZKChainCommitment));

        // Some non-zero value which would be the case if a chain existed before the
        // priority tree was added
        commitment.priorityTree.startIndex = 101;
        commitment.priorityTree.nextLeafIndex = 102;

        finalizeDepositWithCustomCommitment(abi.encode(commitment));

        address diamondProxy = l2Bridgehub.getZKChain(mintChainId);
        require(!GettersFacet(diamondProxy).isPriorityQueueActive(), "Priority queue must not be active");
    }

    function test_forwardToL3OnGateway() public {
        // todo fix this test
        finalizeDeposit();
        vm.prank(SETTLEMENT_LAYER_RELAY_SENDER);
        l2Bridgehub.forwardTransactionOnGateway(mintChainId, bytes32(0), 0);
    }

    function test_withdrawFromGateway() public {
        // todo fix this test
        finalizeDeposit();
        address newAdmin = address(0x1);
        bytes memory newDiamondCut = abi.encode();
        BridgehubBurnCTMAssetData memory data = BridgehubBurnCTMAssetData({
            chainId: mintChainId,
            ctmData: abi.encode(newAdmin, config.contracts.diamondCutData),
            chainData: abi.encode(chainTypeManager.protocolVersion())
        });
        vm.prank(ownerWallet);
        vm.mockCall(
            address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR.sendToL1.selector),
            abi.encode(bytes(""))
        );
        l2AssetRouter.withdraw(ctmAssetId, abi.encode(data));
    }

    function finalizeDeposit() public {
        finalizeDepositWithCustomCommitment(exampleChainCommitment);
    }

    function finalizeDepositWithCustomCommitment(bytes memory chainCommitment) public {
        bytes memory chainData = chainCommitment;
        bytes memory ctmData = abi.encode(
            baseTokenAssetId,
            ownerWallet,
            chainTypeManager.protocolVersion(),
            config.contracts.diamondCutData
        );
        BridgehubMintCTMAssetData memory data = BridgehubMintCTMAssetData({
            chainId: mintChainId,
            baseTokenAssetId: baseTokenAssetId,
            ctmData: ctmData,
            chainData: chainData
        });
        vm.prank(aliasedL1AssetRouter);
        l2AssetRouter.finalizeDeposit(L1_CHAIN_ID, ctmAssetId, abi.encode(data));
    }
}
