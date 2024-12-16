// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/console.sol";

import {L1AssetRouterTest} from "./_L1SharedBridge_Shared.t.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {L1AssetRouter} from "contracts/bridge/L1AssetRouter.sol";
import {L1NativeTokenVault} from "contracts/bridge/L1NativeTokenVault.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2Message, TxStatus} from "contracts/common/Messaging.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {IL1NativeTokenVault} from "contracts/bridge/interfaces/IL1NativeTokenVault.sol";
import {L1NativeTokenVault} from "contracts/bridge/L1NativeTokenVault.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
<<<<<<< HEAD
import {StdStorage, stdStorage} from "forge-std/Test.sol";

/// We are testing all the specified revert and require cases.
contract L1AssetRouterFailTest is L1AssetRouterTest {
    using stdStorage for StdStorage;

    function test_initialize_WrongOwner() public {
        vm.expectRevert("L1AR: owner 0");
=======
import {L2BridgeNotSet, L2WithdrawalMessageWrongLength, InsufficientChainBalance, ZeroAddress, ValueMismatch, NonEmptyMsgValue, DepositExists, ValueMismatch, NonEmptyMsgValue, TokenNotSupported, EmptyDeposit, L2BridgeNotDeployed, DepositIncorrectAmount, InvalidProof, NoFundsTransferred, InsufficientFunds, DepositDoesNotExist, WithdrawalAlreadyFinalized, InsufficientFunds, MalformedMessage, InvalidSelector, TokensWithFeesNotSupported} from "contracts/common/L1ContractErrors.sol";

/// We are testing all the specified revert and require cases.
contract L1SharedBridgeFailTest is L1SharedBridgeTest {
    function test_initialize_wrongOwner() public {
        vm.expectRevert(ZeroAddress.selector);
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
        new TransparentUpgradeableProxy(
            address(sharedBridgeImpl),
            admin,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                L1AssetRouter.initialize.selector,
                address(0),
                eraPostUpgradeFirstBatch,
                eraPostUpgradeFirstBatch,
                1,
                0
            )
        );
    }

<<<<<<< HEAD
    function test_initialize_wrongOwnerNTV() public {
        vm.expectRevert("NTV owner 0");
        new TransparentUpgradeableProxy(
            address(nativeTokenVaultImpl),
            admin,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(L1NativeTokenVault.initialize.selector, address(0))
        );
    }

    function test_transferTokenToNTV_wrongCaller() public {
        vm.expectRevert("L1AR: not NTV");
        sharedBridge.transferTokenToNTV(address(token));
=======
    function test_bridgehubDepositBaseToken_EthwrongMsgValue() public {
        vm.deal(bridgehubAddress, amount);
        vm.prank(bridgehubAddress);
        vm.expectRevert(abi.encodeWithSelector(ValueMismatch.selector, amount, uint256(0)));
        sharedBridge.bridgehubDepositBaseToken(chainId, alice, ETH_TOKEN_ADDRESS, amount);
    }

    function test_bridgehubDepositBaseToken_ErcWrongMsgValue() public {
        vm.deal(bridgehubAddress, amount);
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), amount);
        vm.prank(bridgehubAddress);
        vm.expectRevert(NonEmptyMsgValue.selector);
        sharedBridge.bridgehubDepositBaseToken{value: amount}(chainId, alice, address(token), amount);
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
    }

    function test_nullifyChainBalanceByNTV_wrongCaller() public {
        vm.expectRevert("L1AR: not NTV");
        sharedBridge.nullifyChainBalanceByNTV(chainId, address(token));
    }

    function test_registerToken_noCode() public {
        vm.expectRevert("NTV: empty token");
        nativeTokenVault.registerToken(address(0));
    }

    function test_setL1Erc20Bridge_alreadySet() public {
        vm.prank(owner);
        vm.expectRevert("L1AR: legacy bridge already set");
        sharedBridge.setL1Erc20Bridge(address(0));
    }

    function test_setL1Erc20Bridge_emptyAddressProvided() public {
        stdstore.target(address(sharedBridge)).sig(sharedBridge.legacyBridge.selector).checked_write(address(0));
        vm.prank(owner);
        vm.expectRevert("L1AR: legacy bridge 0");
        sharedBridge.setL1Erc20Bridge(address(0));
    }

    function test_setNativeTokenVault_alreadySet() public {
        vm.prank(owner);
        vm.expectRevert("L1AR: native token vault already set");
        sharedBridge.setNativeTokenVault(IL1NativeTokenVault(address(0)));
    }

    function test_setNativeTokenVault_emptyAddressProvided() public {
        stdstore.target(address(sharedBridge)).sig(sharedBridge.nativeTokenVault.selector).checked_write(address(0));
        vm.prank(owner);
        vm.expectRevert("L1AR: native token vault 0");
        sharedBridge.setNativeTokenVault(IL1NativeTokenVault(address(0)));
    }

    function test_setAssetHandlerAddressOnCounterPart_notOwnerOrADT() public {
        uint256 l2TxGasLimit = 100000;
        uint256 l2TxGasPerPubdataByte = 100;
        address refundRecipient = address(0);

        vm.prank(alice);
        vm.expectRevert("L1AR: only ADT or owner");
        sharedBridge.setAssetHandlerAddressOnCounterPart(
            eraChainId,
            mintValue,
            l2TxGasLimit,
            l2TxGasPerPubdataByte,
            refundRecipient,
            tokenAssetId,
            address(token)
        );
    }

    // function test_transferFundsToSharedBridge_Eth_CallFailed() public {
    //     vm.mockCall(address(nativeTokenVault), "0x", abi.encode(""));
    //     vm.prank(address(nativeTokenVault));
    //     vm.expectRevert("L1AR: eth transfer failed");
    //     nativeTokenVault.transferFundsFromSharedBridge(ETH_TOKEN_ADDRESS);
    // }

    // function test_transferFundsToSharedBridge_Eth_CallFailed() public {
    //     vm.mockCall(address(nativeTokenVault), "0x", abi.encode(""));
    //     vm.prank(address(nativeTokenVault));
    //     vm.expectRevert("L1AR: eth transfer failed");
    //     nativeTokenVault.transferFundsFromSharedBridge(ETH_TOKEN_ADDRESS);
    // }

    function test_transferFundsToSharedBridge_Eth_0_AmountTransferred() public {
        vm.deal(address(sharedBridge), 0);
        vm.prank(address(nativeTokenVault));
        vm.expectRevert("NTV: 0 eth transferred");
        nativeTokenVault.transferFundsFromSharedBridge(ETH_TOKEN_ADDRESS);
    }

    function test_transferFundsToSharedBridge_Erc_0_AmountTransferred() public {
        vm.prank(address(sharedBridge));
        token.transfer(address(1), amount);
        vm.prank(address(nativeTokenVault));
        vm.expectRevert("NTV: 0 amount to transfer");
        nativeTokenVault.transferFundsFromSharedBridge(address(token));
    }

    function test_transferFundsToSharedBridge_Erc_WrongAmountTransferred() public {
        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.balanceOf.selector), abi.encode(10));
        vm.prank(address(nativeTokenVault));
        vm.expectRevert("NTV: wrong amount transferred");
        nativeTokenVault.transferFundsFromSharedBridge(address(token));
    }

    function test_bridgehubDepositBaseToken_Eth_Token_incorrectSender() public {
        vm.expectRevert("L1AR: msg.sender not equal to bridgehub or era chain");
        sharedBridge.bridgehubDepositBaseToken{value: amount}(chainId, ETH_TOKEN_ASSET_ID, alice, amount);
    }

    function test_bridgehubDepositBaseToken_ethwrongMsgValue() public {
        vm.prank(bridgehubAddress);
        vm.expectRevert("L1NTV: msg.value not equal to amount");
        sharedBridge.bridgehubDepositBaseToken(chainId, ETH_TOKEN_ASSET_ID, alice, amount);
    }

    function test_bridgehubDepositBaseToken_ercWrongMsgValue() public {
        vm.prank(bridgehubAddress);
        vm.expectRevert("NTV m.v > 0 b d.it");
        sharedBridge.bridgehubDepositBaseToken{value: amount}(chainId, tokenAssetId, alice, amount);
    }

    function test_bridgehubDepositBaseToken_ercWrongErcDepositAmount() public {
        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.balanceOf.selector), abi.encode(10));

<<<<<<< HEAD
        bytes memory message = bytes("5T");
        vm.expectRevert(message);
        vm.prank(bridgehubAddress);
        sharedBridge.bridgehubDepositBaseToken(chainId, tokenAssetId, alice, amount);
=======
        vm.expectRevert(TokensWithFeesNotSupported.selector);
        vm.prank(bridgehubAddress);
        sharedBridge.bridgehubDepositBaseToken(chainId, alice, address(token), amount);
    }

    function test_bridgehubDeposit_Eth_l2BridgeNotDeployed() public {
        vm.prank(owner);
        sharedBridge.initializeChainGovernance(chainId, address(0));
        vm.deal(bridgehubAddress, amount);
        vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(address(token))
        );
        vm.expectRevert(abi.encodeWithSelector(L2BridgeNotSet.selector, chainId));
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit{value: amount}(chainId, alice, 0, abi.encode(ETH_TOKEN_ADDRESS, 0, bob));
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
    }

    function test_bridgehubDeposit_Erc_weth() public {
        vm.prank(bridgehubAddress);
<<<<<<< HEAD
        // note we have a catch, so there is no data
        vm.expectRevert();
=======
        vm.expectRevert(abi.encodeWithSelector(TokenNotSupported.selector, l1WethAddress));
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(l1WethAddress, amount, bob));
    }

    function test_bridgehubDeposit_Eth_baseToken() public {
        vm.prank(bridgehubAddress);
<<<<<<< HEAD
        vm.expectRevert("L1AR: baseToken deposit not supported");
=======
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
        vm.expectRevert(abi.encodeWithSelector(TokenNotSupported.selector, ETH_TOKEN_ADDRESS));
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(ETH_TOKEN_ADDRESS, 0, bob));
    }

    function test_bridgehubDeposit_Eth_wrongDepositAmount() public {
        _setBaseTokenAssetId(tokenAssetId);
        vm.prank(bridgehubAddress);
<<<<<<< HEAD

        vm.expectRevert("L1NTV: msg.value not equal to amount");
=======
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(address(token))
        );
        vm.expectRevert(abi.encodeWithSelector(DepositIncorrectAmount.selector, 0, amount));
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(ETH_TOKEN_ADDRESS, amount, bob));
    }

    function test_bridgehubDeposit_Erc_msgValue() public {
        vm.prank(bridgehubAddress);
<<<<<<< HEAD
        vm.expectRevert("NTV m.v > 0 b d.it");
=======
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
        vm.expectRevert(NonEmptyMsgValue.selector);
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit{value: amount}(chainId, alice, 0, abi.encode(address(token), amount, bob));
    }

    function test_bridgehubDeposit_Erc_wrongDepositAmount() public {
        vm.prank(bridgehubAddress);
        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.balanceOf.selector), abi.encode(10));
        vm.expectRevert(abi.encodeWithSelector(DepositIncorrectAmount.selector, 0, amount));
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(address(token), amount, bob));
    }

    function test_bridgehubDeposit_Eth() public {
        _setBaseTokenAssetId(tokenAssetId);
        vm.prank(bridgehubAddress);
<<<<<<< HEAD

        bytes memory message = bytes("6T");
        vm.expectRevert(message);
=======
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(address(token))
        );
        vm.expectRevert(EmptyDeposit.selector);
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(ETH_TOKEN_ADDRESS, 0, bob));
    }

    function test_bridgehubConfirmL2Transaction_depositAlreadyHappened() public {
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        vm.prank(bridgehubAddress);
<<<<<<< HEAD
        vm.expectRevert("L1AR: tx hap");
=======
        vm.expectRevert(DepositExists.selector);
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
        sharedBridge.bridgehubConfirmL2Transaction(chainId, txDataHash, txHash);
    }

    function test_finalizeWithdrawal_EthOnEth_withdrawalFailed() public {
        vm.deal(address(nativeTokenVault), 0);
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
<<<<<<< HEAD

        vm.expectRevert("NTV: withdrawal failed, no funds or cannot transfer to receiver");
        sharedBridge.finalizeWithdrawal({
=======
        vm.prank(bridgehubAddress);
        vm.expectRevert(InvalidProof.selector);
        sharedBridge.claimFailedDeposit({
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_bridgeRecoverFailedTransfer_Eth_claimFailedDepositFailed() public {
        vm.deal(address(nativeTokenVault), 0);
        bytes memory transferData = abi.encode(amount, alice);
        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        require(sharedBridge.depositHappened(chainId, txHash) == txDataHash, "Deposit not set");

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

<<<<<<< HEAD
        vm.expectRevert("NTV: claimFailedDeposit failed, no funds or cannot transfer to receiver");
        sharedBridge.bridgeRecoverFailedTransfer({
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

    function test_bridgeRecoverFailedTransfer_invalidChainID() public {
        vm.store(address(sharedBridge), bytes32(isWithdrawalFinalizedStorageLocation - 5), bytes32(uint256(0)));

        bytes memory transferData = abi.encode(amount, alice);
        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        require(sharedBridge.depositHappened(chainId, txHash) == txDataHash, "Deposit not set");

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL1ToL2TransactionStatus.selector,
                eraChainId,
                txHash,
                l2BatchNumber,
                l2MessageIndex,
                l2TxNumberInBatch,
                merkleProof,
                TxStatus.Failure
            ),
            abi.encode(true)
        );

        vm.expectRevert("L1AR: last deposit time not set for Era");
        sharedBridge.bridgeRecoverFailedTransfer({
            _chainId: eraChainId,
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

    function test_bridgeRecoverFailedTransfer_eraLegacyDeposit() public {
        vm.store(address(sharedBridge), bytes32(isWithdrawalFinalizedStorageLocation - 5), bytes32(uint256(2)));

        uint256 l2BatchNumber = 1;
        bytes memory transferData = abi.encode(amount, alice);
        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        require(sharedBridge.depositHappened(chainId, txHash) == txDataHash, "Deposit not set");

        vm.mockCall(
            bridgehubAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehub.proveL1ToL2TransactionStatus.selector,
                eraChainId,
                txHash,
                l2BatchNumber,
                l2MessageIndex,
                l2TxNumberInBatch,
                merkleProof,
                TxStatus.Failure
            ),
            abi.encode(true)
        );

        vm.expectRevert("L1AR: legacy cFD");
        sharedBridge.bridgeRecoverFailedTransfer({
            _chainId: eraChainId,
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

    function test_claimFailedDeposit_proofInvalid() public {
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.proveL1ToL2TransactionStatus.selector),
            abi.encode(address(0))
        );
        vm.prank(bridgehubAddress);
        bytes memory message = bytes("yn");
        vm.expectRevert(message);
=======
        vm.expectRevert(NoFundsTransferred.selector);
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
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

    function test_claimFailedDeposit_amountZero() public {
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

        bytes memory message = bytes("y1");
        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, 0));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        vm.expectRevert(message);
        sharedBridge.claimFailedDeposit({
            _chainId: chainId,
            _depositSender: alice,
            _l1Asset: ETH_TOKEN_ADDRESS,
            _amount: 0,
            _l2TxHash: txHash,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _merkleProof: merkleProof
        });
    }

    function test_claimFailedDeposit_depositDidNotHappen() public {
        vm.deal(address(sharedBridge), amount);

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

<<<<<<< HEAD
        vm.expectRevert("L1AR: d.it not hap");
=======
        vm.expectRevert(DepositDoesNotExist.selector);
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
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

    function test_claimFailedDeposit_chainBalanceLow() public {
        _setNativeTokenVaultChainBalance(chainId, ETH_TOKEN_ADDRESS, 0);

        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        require(sharedBridge.depositHappened(chainId, txHash) == txDataHash, "Deposit not set");

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

<<<<<<< HEAD
        vm.expectRevert("NTV: not enough funds 2");
=======
        vm.expectRevert(InsufficientChainBalance.selector);
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
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

    function test_finalizeWithdrawal_EthOnEth_legacyTxFinalizedInERC20Bridge() public {
        vm.deal(address(sharedBridge), amount);
        uint256 legacyBatchNumber = 0;

        vm.mockCall(
            l1ERC20BridgeAddress,
            abi.encodeWithSelector(IL1ERC20Bridge.isWithdrawalFinalized.selector),
            abi.encode(true)
        );

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );

<<<<<<< HEAD
        vm.expectRevert("L1AR: legacy eth withdrawal");
=======
        vm.expectRevert(WithdrawalAlreadyFinalized.selector);
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
        sharedBridge.finalizeWithdrawal({
            _chainId: eraChainId,
            _l2BatchNumber: legacyBatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_EthOnEth_legacyTxFinalizedInSharedBridge() public {
        vm.deal(address(sharedBridge), amount);
        uint256 legacyBatchNumber = 0;

        vm.mockCall(
            l1ERC20BridgeAddress,
            abi.encodeWithSelector(IL1ERC20Bridge.isWithdrawalFinalized.selector),
            abi.encode(false)
        );

        vm.store(
            address(sharedBridge),
            keccak256(
                abi.encode(
                    l2MessageIndex,
                    keccak256(
                        abi.encode(
                            legacyBatchNumber,
                            keccak256(abi.encode(eraChainId, isWithdrawalFinalizedStorageLocation))
                        )
                    )
                )
            ),
            bytes32(uint256(1))
        );

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );

<<<<<<< HEAD
        vm.expectRevert("L1AR: Withdrawal is already finalized");
=======
        vm.expectRevert(WithdrawalAlreadyFinalized.selector);
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
        sharedBridge.finalizeWithdrawal({
            _chainId: eraChainId,
            _l2BatchNumber: legacyBatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_EthOnEth_legacyTxFinalizedInDiamondProxy() public {
        vm.deal(address(sharedBridge), amount);
        uint256 legacyBatchNumber = 0;

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );
<<<<<<< HEAD
        vm.expectRevert("L1AR: legacy eth withdrawal");
=======
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe

        vm.expectRevert(WithdrawalAlreadyFinalized.selector);
        sharedBridge.finalizeWithdrawal({
            _chainId: eraChainId,
            _l2BatchNumber: legacyBatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_EthOnEth_diamondUpgradeFirstBatchNotSet() public {
        vm.store(address(sharedBridge), bytes32(isWithdrawalFinalizedStorageLocation - 7), bytes32(uint256(0)));
        vm.deal(address(sharedBridge), amount);

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );
        vm.expectRevert("L1AR: diamondUFB not set for Era");

        sharedBridge.finalizeWithdrawal({
            _chainId: eraChainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_TokenOnEth_legacyTokenWithdrawal() public {
        vm.store(address(sharedBridge), bytes32(isWithdrawalFinalizedStorageLocation - 6), bytes32(uint256(5)));
        vm.deal(address(sharedBridge), amount);

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );
        vm.expectRevert("L1AR: legacy token withdrawal");

        sharedBridge.finalizeWithdrawal({
            _chainId: eraChainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_TokenOnEth_legacyUpgradeFirstBatchNotSet() public {
        vm.store(address(sharedBridge), bytes32(isWithdrawalFinalizedStorageLocation - 6), bytes32(uint256(0)));
        vm.deal(address(sharedBridge), amount);

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );
        vm.expectRevert("L1AR: LegacyUFB not set for Era");

        sharedBridge.finalizeWithdrawal({
            _chainId: eraChainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_chainBalance() public {
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
        _setNativeTokenVaultChainBalance(chainId, ETH_TOKEN_ADDRESS, 0);

<<<<<<< HEAD
        vm.expectRevert("NTV: not enough funds");

=======
        vm.expectRevert(InsufficientChainBalance.selector);
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_checkWithdrawal_wrongProof() public {
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
            abi.encode(false)
        );

<<<<<<< HEAD
        vm.expectRevert("L1AR: withd w proof");

=======
        vm.expectRevert(InvalidProof.selector);
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_parseL2WithdrawalMessage_wrongMsgLength() public {
        bytes memory message = abi.encodePacked(IMailbox.finalizeEthWithdrawal.selector);

<<<<<<< HEAD
        vm.expectRevert("L1AR: wrong msg len");
=======
        vm.expectRevert(abi.encodeWithSelector(L2WithdrawalMessageWrongLength.selector, message.length));
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

<<<<<<< HEAD
    function test_parseL2WithdrawalMessage_wrongMsgLength2() public {
        bytes memory message = abi.encodePacked(IL1ERC20Bridge.finalizeWithdrawal.selector, abi.encode(amount, token));

        vm.expectRevert("L1AR: wrong msg len 2");
=======
    function test_parseL2WithdrawalMessage_WrongMsgLength2() public {
        vm.deal(address(sharedBridge), amount);

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector, alice, amount),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

        bytes memory message = abi.encodePacked(IL1ERC20Bridge.finalizeWithdrawal.selector, alice, amount);
        // should have more data here

        vm.expectRevert(abi.encodeWithSelector(L2WithdrawalMessageWrongLength.selector, message.length));
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_parseL2WithdrawalMessage_wrongSelector() public {
        // notice that the selector is wrong
        bytes memory message = abi.encodePacked(IMailbox.proveL2LogInclusion.selector, alice, amount);

<<<<<<< HEAD
        vm.expectRevert("L1AR: Incorrect message function selector");
=======
        vm.expectRevert(abi.encodeWithSelector(InvalidSelector.selector, IMailbox.proveL2LogInclusion.selector));
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
        sharedBridge.finalizeWithdrawal({
            _chainId: eraChainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

<<<<<<< HEAD
=======
    function test_depositLegacyERC20Bridge_l2BridgeNotDeployed() public {
        uint256 l2TxGasLimit = 100000;
        uint256 l2TxGasPerPubdataByte = 100;
        address refundRecipient = address(0);

        vm.prank(owner);
        sharedBridge.initializeChainGovernance(eraChainId, address(0));

        vm.expectRevert(abi.encodeWithSelector(L2BridgeNotSet.selector, eraChainId));
        vm.prank(l1ERC20BridgeAddress);
        sharedBridge.depositLegacyErc20Bridge({
            _prevMsgSender: alice,
            _l2Receiver: bob,
            _l1Token: address(token),
            _amount: amount,
            _l2TxGasLimit: l2TxGasLimit,
            _l2TxGasPerPubdataByte: l2TxGasPerPubdataByte,
            _refundRecipient: refundRecipient
        });
    }

>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
    function test_depositLegacyERC20Bridge_weth() public {
        uint256 l2TxGasLimit = 100000;
        uint256 l2TxGasPerPubdataByte = 100;
        address refundRecipient = address(0);

<<<<<<< HEAD
        vm.expectRevert("L1AR: WETH deposit not supported 2");
=======
        vm.expectRevert(abi.encodeWithSelector(TokenNotSupported.selector, l1WethAddress));
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
        vm.prank(l1ERC20BridgeAddress);
        sharedBridge.depositLegacyErc20Bridge({
            _prevMsgSender: alice,
            _l2Receiver: bob,
            _l1Token: l1WethAddress,
            _amount: amount,
            _l2TxGasLimit: l2TxGasLimit,
            _l2TxGasPerPubdataByte: l2TxGasPerPubdataByte,
            _refundRecipient: refundRecipient
        });
    }

    function test_depositLegacyERC20Bridge_refundRecipient() public {
        uint256 l2TxGasLimit = 100000;
        uint256 l2TxGasPerPubdataByte = 100;

        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(sharedBridge));

        emit LegacyDepositInitiated({
            chainId: eraChainId,
            l2DepositTxHash: txHash,
            from: alice,
            to: bob,
            l1Token: address(token),
            amount: amount
        });

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.requestL2TransactionDirect.selector),
            abi.encode(txHash)
        );

        vm.prank(l1ERC20BridgeAddress);
        sharedBridge.depositLegacyErc20Bridge({
            _prevMsgSender: alice,
            _l2Receiver: bob,
            _l1Token: address(token),
            _amount: amount,
            _l2TxGasLimit: l2TxGasLimit,
            _l2TxGasPerPubdataByte: l2TxGasPerPubdataByte,
            _refundRecipient: address(1)
        });
    }
}
