// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {L1AssetRouterTest} from "./_L1SharedBridge_Shared.t.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IBridgehub, L2TransactionRequestTwoBridgesInner} from "contracts/bridgehub/IBridgehub.sol";
import {L2Message, TxStatus} from "contracts/common/Messaging.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase, LEGACY_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IL1AssetHandler} from "contracts/bridge/interfaces/IL1AssetHandler.sol";
import {IL1BaseTokenAssetHandler} from "contracts/bridge/interfaces/IL1BaseTokenAssetHandler.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_ASSET_ROUTER_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {DepositNotSet} from "test/foundry/L1TestsErrors.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

contract L1AssetRouterTestBase is L1AssetRouterTest {
    using stdStorage for StdStorage;

    function test_bridgehubPause() public {
        vm.prank(owner);
        sharedBridge.pause();
        assertEq(sharedBridge.paused(), true, "Shared Bridge Not Paused");
    }

    function test_bridgehubUnpause() public {
        vm.prank(owner);
        sharedBridge.pause();
        assertEq(sharedBridge.paused(), true, "Shared Bridge Not Paused");
        vm.prank(owner);
        sharedBridge.unpause();
        assertEq(sharedBridge.paused(), false, "Shared Bridge Remains Paused");
    }

    function test_bridgehubDepositBaseToken_Eth() public {
        vm.prank(bridgehubAddress);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit BridgehubDepositBaseTokenInitiated(chainId, alice, ETH_TOKEN_ASSET_ID, amount);
        sharedBridge.bridgehubDepositBaseToken{value: amount}(chainId, ETH_TOKEN_ASSET_ID, alice, amount);
    }

    function test_bridgehubDepositBaseToken_Erc() public {
        vm.prank(bridgehubAddress);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit BridgehubDepositBaseTokenInitiated(chainId, alice, tokenAssetId, amount);
        sharedBridge.bridgehubDepositBaseToken(chainId, tokenAssetId, alice, amount);
    }

    function test_bridgehubDepositBaseToken_Erc_NoApproval() public {
        vm.prank(alice);
        token.approve(address(nativeTokenVault), 0);
        vm.prank(bridgehubAddress);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit BridgehubDepositBaseTokenInitiated(chainId, alice, tokenAssetId, amount);
        sharedBridge.bridgehubDepositBaseToken(chainId, tokenAssetId, alice, amount);
    }

    function test_bridgehubDeposit_Eth() public {
        _setBaseTokenAssetId(tokenAssetId);

        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        bytes memory mintCalldata = abi.encode(
            alice,
            bob,
            address(ETH_TOKEN_ADDRESS),
            amount,
            nativeTokenVault.getERC20Getters(address(ETH_TOKEN_ADDRESS), chainId)
        );
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, false, address(sharedBridge));
        vm.prank(bridgehubAddress);
        emit BridgehubDepositInitiated({
            chainId: chainId,
            txDataHash: txDataHash,
            from: alice,
            assetId: ETH_TOKEN_ASSET_ID,
            bridgeMintCalldata: mintCalldata
        });
        sharedBridge.bridgehubDeposit{value: amount}(chainId, alice, 0, abi.encode(ETH_TOKEN_ADDRESS, amount, bob));
    }

    function test_bridgehubDeposit_Erc() public {
        vm.prank(bridgehubAddress);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, false, address(sharedBridge));
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        emit BridgehubDepositInitiated({
            chainId: chainId,
            txDataHash: txDataHash,
            from: alice,
            assetId: tokenAssetId,
            bridgeMintCalldata: abi.encode(amount, bob)
        });
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(address(token), amount, bob));
    }

    function test_bridgehubDeposit_Erc_CustomAssetHandler() public {
        // ToDo: remove the mock call and register custom asset handler?
        vm.mockCall(
            address(nativeTokenVault),
            abi.encodeWithSelector(IL1BaseTokenAssetHandler.tokenAddress.selector, tokenAssetId),
            abi.encode(address(token))
        );
        vm.prank(bridgehubAddress);
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(address(token), amount, bob));
    }

    function test_bridgehubConfirmL2Transaction() public {
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, false, address(l1Nullifier));
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        emit BridgehubDepositFinalized(chainId, txDataHash, txHash);
        vm.prank(bridgehubAddress);
        sharedBridge.bridgehubConfirmL2Transaction(chainId, txDataHash, txHash);
    }

    function test_claimFailedDeposit_Erc() public {
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        require(l1Nullifier.depositHappened(chainId, txHash) == txDataHash, "Deposit not set");

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL1ToL2TransactionStatus.selector,
                chainId,
                txHash,
                l2BatchNumber,
                l2MessageIndex,
                l2TxNumberInBatch,
                merkleProof,
                TxStatus.Failure
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, false, address(sharedBridge));
        emit ClaimedFailedDepositAssetRouter({
            chainId: chainId,
            assetId: tokenAssetId,
            assetData: abi.encode(bytes32(0))
        });
        l1Nullifier.claimFailedDeposit({
            _chainId: chainId,
            _depositSender: alice,
            _l1Token: address(token),
            _amount: amount,
            _l2TxHash: txHash,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _merkleProof: merkleProof
        });
    }

    function test_claimFailedDeposit_Eth() public {
        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        require(l1Nullifier.depositHappened(chainId, txHash) == txDataHash, "Deposit not set");

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL1ToL2TransactionStatus.selector,
                chainId,
                txHash,
                l2BatchNumber,
                l2MessageIndex,
                l2TxNumberInBatch,
                merkleProof,
                TxStatus.Failure
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, false, address(sharedBridge));
        emit ClaimedFailedDepositAssetRouter({
            chainId: chainId,
            assetId: ETH_TOKEN_ASSET_ID,
            assetData: abi.encode(bytes32(0))
        });
        l1Nullifier.claimFailedDeposit({
            _chainId: chainId,
            _depositSender: alice,
            _l1Token: ETH_TOKEN_ADDRESS,
            _amount: amount,
            _l2TxHash: txHash,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _merkleProof: merkleProof
        });
    }

    function test_bridgeRecoverFailedTransfer_Eth() public {
        bytes memory transferData = abi.encode(amount, alice, ETH_TOKEN_ADDRESS);
        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        require(l1Nullifier.depositHappened(chainId, txHash) == txDataHash, "Deposit not set");

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL1ToL2TransactionStatus.selector,
                chainId,
                txHash,
                l2BatchNumber,
                l2MessageIndex,
                l2TxNumberInBatch,
                merkleProof,
                TxStatus.Failure
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, false, address(sharedBridge));
        emit ClaimedFailedDepositAssetRouter({
            chainId: chainId,
            assetId: ETH_TOKEN_ASSET_ID,
            assetData: abi.encode(bytes32(0))
        });
        l1Nullifier.bridgeRecoverFailedTransfer({
            _chainId: chainId,
            _depositSender: alice,
            _assetId: ETH_TOKEN_ASSET_ID,
            _assetData: transferData,
            _l2TxHash: txHash,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_EthOnEth() public {
        bytes memory message = abi.encodePacked(IMailbox.finalizeEthWithdrawal.selector, alice, amount);
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                chainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, false, address(sharedBridge));
        emit DepositFinalizedAssetRouter(chainId, ETH_TOKEN_ASSET_ID, message);
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_ErcOnEth() public {
        _setNativeTokenVaultChainBalance(chainId, address(token), amount);
        bytes memory message = abi.encodePacked(
            IAssetRouterBase.finalizeDeposit.selector,
            chainId,
            tokenAssetId,
            abi.encode(0, alice, 0, amount, new bytes(0))
        );
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: l2LegacySharedBridgeAddr,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeCall(
                IBridgehub.proveL2MessageInclusion,
                (chainId, l2BatchNumber, l2MessageIndex, l2ToL1Message, merkleProof)
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, false, address(sharedBridge));
        emit DepositFinalizedAssetRouter(chainId, tokenAssetId, message);
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_EthOnErc() public {
        // vm.deal(address(sharedBridge), amount);

        // _setNativeTokenVaultChainBalance(chainId, ETH_TOKEN_ADDRESS, amount);
        _setBaseTokenAssetId(tokenAssetId);
        vm.prank(bridgehubAddress);

        bytes memory message = abi.encodePacked(
            IAssetRouterBase.finalizeDeposit.selector,
            chainId,
            ETH_TOKEN_ASSET_ID,
            abi.encode(0, alice, 0, amount, new bytes(0))
        );
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: l2LegacySharedBridgeAddr,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                chainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, false, address(sharedBridge));
        emit DepositFinalizedAssetRouter(chainId, ETH_TOKEN_ASSET_ID, message);
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_BaseErcOnErc() public {
        _setBaseTokenAssetId(tokenAssetId);
        vm.prank(bridgehubAddress);

        bytes memory message = abi.encodePacked(
            IAssetRouterBase.finalizeDeposit.selector,
            chainId,
            tokenAssetId,
            abi.encode(0, alice, 0, amount, new bytes(0))
        );
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                chainId
                // l2BatchNumber,
                // l2MessageIndex,
                // l2ToL1Message,
                // merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, false, address(sharedBridge));
        emit DepositFinalizedAssetRouter(chainId, tokenAssetId, abi.encode(amount, alice));
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_NonBaseErcOnErc() public {
        bytes memory message = abi.encodePacked(
            IAssetRouterBase.finalizeDeposit.selector,
            chainId,
            tokenAssetId,
            abi.encode(0, alice, 0, amount, new bytes(0))
        );
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseTokenAssetId.selector),
            abi.encode(bytes32(uint256(2)))
        );
        //alt base token
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: l2LegacySharedBridgeAddr,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                chainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, false, address(sharedBridge));
        emit DepositFinalizedAssetRouter(chainId, tokenAssetId, message);
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_safeTransferFundsFromSharedBridge_Erc() public {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        uint256 startBalanceNtv = nativeTokenVault.chainBalance(chainId, assetId);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(l1Nullifier), address(nativeTokenVault), amount);
        nativeTokenVault.transferFundsFromSharedBridge(address(token));
        nativeTokenVault.updateChainBalancesFromSharedBridge(address(token), chainId);
        uint256 endBalanceNtv = nativeTokenVault.chainBalance(chainId, assetId);
        assertEq(endBalanceNtv - startBalanceNtv, amount);
    }

    function test_safeTransferFundsFromSharedBridge_Eth() public {
        uint256 startEthBalanceNtv = address(nativeTokenVault).balance;
        uint256 startBalanceNtv = nativeTokenVault.chainBalance(chainId, ETH_TOKEN_ASSET_ID);
        nativeTokenVault.transferFundsFromSharedBridge(ETH_TOKEN_ADDRESS);
        nativeTokenVault.updateChainBalancesFromSharedBridge(ETH_TOKEN_ADDRESS, chainId);
        uint256 endBalanceNtv = nativeTokenVault.chainBalance(chainId, ETH_TOKEN_ASSET_ID);
        uint256 endEthBalanceNtv = address(nativeTokenVault).balance;
        assertEq(endBalanceNtv - startBalanceNtv, amount);
        assertEq(endEthBalanceNtv - startEthBalanceNtv, amount);
    }

    function test_bridgehubDeposit_Eth_storesCorrectTxHash() public {
        _setBaseTokenAssetId(tokenAssetId);
        vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseTokenAssetId.selector),
            abi.encode(tokenAssetId)
        );
        // solhint-disable-next-line func-named-parameters
        L2TransactionRequestTwoBridgesInner memory request = sharedBridge.bridgehubDeposit{value: amount}(
            chainId,
            alice,
            0,
            abi.encode(ETH_TOKEN_ADDRESS, 0, bob)
        );

        bytes32 expectedTxHash = DataEncoding.encodeTxDataHash({
            _nativeTokenVault: address(nativeTokenVault),
            _encodingVersion: LEGACY_ENCODING_VERSION,
            _originalCaller: alice,
            _assetId: nativeTokenVault.BASE_TOKEN_ASSET_ID(),
            _transferData: abi.encode(amount, bob, ETH_TOKEN_ADDRESS)
        });

        assertEq(request.txDataHash, expectedTxHash);
    }
}
