// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L1AssetRouterTest} from "./_L1SharedBridge_Shared.t.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2Message, TxStatus} from "contracts/common/Messaging.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IL1AssetRouter} from "contracts/bridge/interfaces/IL1AssetRouter.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_ASSET_ROUTER_ADDR} from "contracts/common/L2ContractAddresses.sol";

// note, this should be the same as where hyper is disabled
contract L1AssetRouterHyperEnabledTest is L1AssetRouterTest {
    function test_bridgehubDepositBaseToken_Eth() public {
        vm.deal(bridgehubAddress, amount);
        vm.prank(bridgehubAddress);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit BridgehubDepositBaseTokenInitiated(chainId, alice, ETH_TOKEN_ASSET_ID, amount);
        sharedBridge.bridgehubDepositBaseToken{value: amount}({
            _chainId: chainId,
            _assetId: ETH_TOKEN_ASSET_ID,
            _prevMsgSender: alice,
            _amount: amount
        });
    }

    function test_bridgehubDepositBaseToken_Erc() public {
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), amount);
        vm.prank(bridgehubAddress);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit BridgehubDepositBaseTokenInitiated(chainId, alice, tokenAssetId, amount);
        sharedBridge.bridgehubDepositBaseToken({
            _chainId: chainId,
            _assetId: tokenAssetId,
            _prevMsgSender: alice,
            _amount: amount
        });
    }

    function test_bridgehubDeposit_Eth() public {
        // vm.prank(bridgehubAddress);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, false, address(sharedBridge));
        _setBaseTokenAssetId(tokenAssetId);
        vm.prank(bridgehubAddress);
        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        emit BridgehubDepositInitiated({
            chainId: chainId,
            txDataHash: txDataHash,
            from: alice,
            assetId: ETH_TOKEN_ASSET_ID,
            bridgeMintCalldata: abi.encode(0, bob)
        });
        sharedBridge.bridgehubDeposit{value: amount}({
            _chainId: chainId,
            _prevMsgSender: alice,
            _l2Value: 0,
            _data: abi.encode(ETH_TOKEN_ADDRESS, amount, bob)
        });
    }

    function test_bridgehubDeposit_Erc() public {
        vm.prank(bridgehubAddress);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, false, address(sharedBridge));
        _setBaseTokenAssetId(ETH_TOKEN_ASSET_ID);

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

    function test_bridgehubConfirmL2Transaction() public {
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        emit BridgehubDepositFinalized(chainId, txDataHash, txHash);
        vm.prank(bridgehubAddress);
        sharedBridge.bridgehubConfirmL2Transaction(chainId, txDataHash, txHash);
    }

    function test_claimFailedDeposit_Erc() public {
        token.mint(address(sharedBridge), 10 * amount);

        // storing depositHappened[chainId][l2TxHash] = txDataHash.
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        require(sharedBridge.depositHappened(chainId, txHash) == txDataHash, "Deposit not set");

        _setNativeTokenVaultChainBalance(chainId, address(token), amount);

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
        emit ClaimedFailedDepositSharedBridge(chainId, alice, tokenAssetId, abi.encode(bytes32(0)));
        vm.prank(bridgehubAddress);
        sharedBridge.claimFailedDeposit({
            _chainId: chainId,
            _depositSender: alice,
            _l1Asset: address(token),
            _amount: amount,
            _l2TxHash: txHash,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _merkleProof: merkleProof
        });
    }

    function test_claimFailedDeposit_Eth() public {
        // storing depositHappened[chainId][l2TxHash] = txDataHash.
        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        require(sharedBridge.depositHappened(chainId, txHash) == txDataHash, "Deposit not set");

        // Bridgehub bridgehub = new Bridgehub();
        // vm.store(address(bridgehub),  bytes32(uint256(5 +2)), bytes32(uint256(31337)));
        // require(address(bridgehub.deployer()) == address(31337), "BH: deployer wrong");

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
        emit ClaimedFailedDepositSharedBridge(chainId, alice, ETH_TOKEN_ASSET_ID, abi.encode(bytes32(0)));
        vm.prank(bridgehubAddress);
        sharedBridge.claimFailedDeposit({
            _chainId: chainId,
            _depositSender: alice,
            _l1Asset: ETH_TOKEN_ADDRESS,
            _amount: amount,
            _l2TxHash: txHash,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_EthOnEth() public {
        _setBaseTokenAssetId(ETH_TOKEN_ASSET_ID);

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
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(chainId, alice, ETH_TOKEN_ASSET_ID, amount);
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
        _setBaseTokenAssetId(ETH_TOKEN_ASSET_ID);

        bytes memory message = abi.encodePacked(
            IL1AssetRouter.finalizeWithdrawal.selector,
            tokenAssetId,
            abi.encode(amount, alice)
        );
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: L2_ASSET_ROUTER_ADDR,
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
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(chainId, alice, tokenAssetId, amount);
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
        _setBaseTokenAssetId(tokenAssetId);

        bytes memory message = abi.encodePacked(
            IL1AssetRouter.finalizeWithdrawal.selector,
            ETH_TOKEN_ASSET_ID,
            abi.encode(amount, alice)
        );
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: L2_ASSET_ROUTER_ADDR,
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
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(chainId, alice, ETH_TOKEN_ASSET_ID, amount);
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

        bytes memory message = abi.encodePacked(
            IL1AssetRouter.finalizeWithdrawal.selector,
            tokenAssetId,
            abi.encode(amount, alice)
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
        emit WithdrawalFinalizedSharedBridge(chainId, alice, tokenAssetId, amount);
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_NonBaseErcOnErc2() public {
        bytes memory message = abi.encodePacked(
            IL1AssetRouter.finalizeWithdrawal.selector,
            tokenAssetId,
            abi.encode(amount, alice)
        );
        _setBaseTokenAssetId(bytes32(uint256(2))); //alt base token
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: L2_ASSET_ROUTER_ADDR,
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
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(chainId, alice, tokenAssetId, amount);
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }
}
