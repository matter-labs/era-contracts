// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {L1InteropHandler} from "./L1InteropHandler.sol";
import {IL1Nullifier} from "../bridge/interfaces/IL1Nullifier.sol";
import {L2InteropCenter, ShadowAccountOp} from "./L2InteropCenter.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_ASSET_ROUTER} from "../common/l2-helpers/L2ContractAddresses.sol";
import {FinalizeL1DepositParams} from "../bridge/interfaces/IL1Nullifier.sol";
import {IWrappedTokenGatewayV3} from "./IWrappedTokenGatewayV3.sol";
import {IL1Bridgehub} from "../bridgehub/IL1Bridgehub.sol";
import {L2TransactionRequestTwoBridgesOuter} from "../bridgehub/IBridgehubBase.sol";

import {ZKSProvider} from "../../deploy-scripts/provider/ZKSProvider.s.sol";
import {IPool} from "./IPool.sol";

contract DeployContracts is Script, ZKSProvider {
    using stdToml for string;

    // address sepoliaCreate2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    IL1Nullifier l1Nullifier = IL1Nullifier(0x9e24E2c23933d30eF2DEB70A0D977Fb1Ca20AbEa);
    address bridgehubAddress = 0xc4FD2580C3487bba18D63f50301020132342fdbD;

    address aaveWeth = 0x387d311e47e80b498169e6fb51d3193167d89F7D;
    address aavePool = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;

    address ghoTokenAddress = 0xc4bF5CbDaBE595361438F8c6a187bDc330539c60;

    address deployedL1InteropHandler = 0xafb9035F05efFbaC744e68145339483F2234D7bc;
    address deployedL2InteropCenter = 0x3b1b27ec7A37406892B129a25642edb0339b86B1;

    bytes32 baseTokenAssetId = 0x6337a96bd2cd359fa0bae3bbedfca736753213c95037ae158c5fa7c048ae2112;

    address sender = 0x5d71d5f805e35DB4F870c64e3C655ed2222d5E39;

    function run(string memory l1RpcUrl, string memory l2RpcUrl) public {
        console.log("Deploying contracts");

        vm.createSelectFork(l1RpcUrl);
        vm.broadcast();
        L1InteropHandler l1InteropHandler = new L1InteropHandler(bridgehubAddress);
        // l1InteropHandler.setL2InteropCenterAddress(address(l2InteropCenter));
        console.log("L1InteropHandler deployed to", address(l1InteropHandler));

        vm.createSelectFork(l2RpcUrl);
        vm.broadcast();
        L2InteropCenter l2InteropCenter = new L2InteropCenter(address(l1InteropHandler));
        // l2InteropCenter.setL1InteropHandlerAddress(address(l1InteropHandler));
        console.log("L2InteropCenter deployed to", address(l2InteropCenter));
    }

    function withdrawTokenAndSendBundleToL1(string memory , string memory l2RpcUrl) public {
        bytes32 assetId = baseTokenAssetId;
        uint256 amount = 100000000000000;
        uint256 ghoAmount = 1000;

        address shadowAccount = L2InteropCenter(deployedL2InteropCenter).l1ShadowAccount(sender);
        
        vm.broadcast();
        /// low level call as there is an issue with zksync os
        (bool success, bytes memory data) = address(L2_BASE_TOKEN_SYSTEM_CONTRACT).call{value: amount}(abi.encodeWithSelector(L2_BASE_TOKEN_SYSTEM_CONTRACT.withdraw.selector, shadowAccount));
        require(success, "Withdraw failed");

        ShadowAccountOp[] memory shadowAccountOps = new ShadowAccountOp[](2);
        shadowAccountOps[0] = ShadowAccountOp({
            target: address(aaveWeth),
            value: amount,
            data: abi.encodeCall(IWrappedTokenGatewayV3.depositETH, (aavePool, shadowAccount, 0))
        });
        shadowAccountOps[1] = ShadowAccountOp({
            target: address(aavePool),
            value: 0,
            data: abi.encodeCall(IPool.borrow, (ghoTokenAddress, ghoAmount, 2, 0, shadowAccount))
        });
        // shadowAccountOps[2] = ShadowAccountOp({
        //     target: address(bridgehubAddress),
        //     value: 0,
        //     data: abi.encodeCall(IL1Bridgehub.requestL2TransactionTwoBridges, L2TransactionRequestTwoBridgesOuter({chainId: chainId, mintValue: 0, l2Value: 0, l2GasLimit: 0, l2GasPerPubdataByteLimit: 0, refundRecipient: address(0), secondBridgeAddress: address(0), secondBridgeValue: 0, secondBridgeCalldata: abi.encodeCall(IPool.borrow, (ghoTokenAddress, ghoAmount, 2, 0, shadowAccount))}))
        // });
        vm.broadcast();
        L2InteropCenter(deployedL2InteropCenter).sendBundleToL1(shadowAccountOps);
    }

    function finalizeTokenWithdrawals(string memory l1RpcUrl, string memory l2RpcUrl, bytes32 withdrawMsgHash, bytes32 bundleMsgHash) public {
        uint256 chainId = 8022833;
        vm.createSelectFork(l1RpcUrl);

        FinalizeL1DepositParams memory withdrawFinalizeL1DepositParams = getFinalizeWithdrawalParams(
            chainId,
            l2RpcUrl,
            withdrawMsgHash,
            0
        );
        vm.broadcast();
        l1Nullifier.finalizeDeposit(withdrawFinalizeL1DepositParams);
    }

    function finalizeBundleWithdrawals(string memory l1RpcUrl, string memory l2RpcUrl, bytes32 withdrawMsgHash, bytes32 bundleMsgHash) public {
        uint256 chainId = 8022833;
        vm.createSelectFork(l1RpcUrl);
        FinalizeL1DepositParams memory bundleFinalizeL1DepositParams = getFinalizeWithdrawalParams(
            chainId,
            l2RpcUrl,
            bundleMsgHash,
            0
        );
        vm.broadcast();
        L1InteropHandler(deployedL1InteropHandler).deployShadowAccount(sender);

        vm.broadcast();
        L1InteropHandler(deployedL1InteropHandler).receiveInteropFromL2(bundleFinalizeL1DepositParams);
    }

    function finalizeBothWithdrawals(string memory l1RpcUrl, string memory l2RpcUrl, bytes32 withdrawMsgHash, bytes32 bundleMsgHash, bool onlySecond) public {
        if (!onlySecond) {
            finalizeTokenWithdrawals(l1RpcUrl, l2RpcUrl, withdrawMsgHash, bundleMsgHash);
        } else {
            finalizeBundleWithdrawals(l1RpcUrl, l2RpcUrl, withdrawMsgHash, bundleMsgHash);
        }
    }
}