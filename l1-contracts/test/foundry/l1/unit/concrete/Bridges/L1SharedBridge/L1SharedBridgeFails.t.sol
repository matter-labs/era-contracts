// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/console.sol";

import {L1AssetRouterTest} from "./_L1SharedBridge_Shared.t.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2Message, TxStatus} from "contracts/common/Messaging.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {BurningNativeWETHNotSupported, AddressAlreadySet, WithdrawFailed, Unauthorized, AssetIdNotSupported, SharedBridgeKey, SharedBridgeValueNotSet, L2WithdrawalMessageWrongLength, InsufficientChainBalance, ZeroAddress, ValueMismatch, NonEmptyMsgValue, DepositExists, ValueMismatch, NonEmptyMsgValue, TokenNotSupported, EmptyDeposit, InvalidProof, NoFundsTransferred, DepositDoesNotExist, WithdrawalAlreadyFinalized, InvalidSelector, TokensWithFeesNotSupported} from "contracts/common/L1ContractErrors.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {DepositNotSet} from "test/foundry/L1TestsErrors.sol";
import {WrongCounterpart, EthTransferFailed, EmptyToken, NativeTokenVaultAlreadySet, ZeroAmountToTransfer, WrongAmountTransferred, ClaimFailedDepositFailed} from "contracts/bridge/L1BridgeContractErrors.sol";

/// We are testing all the specified revert and require cases.
contract L1AssetRouterFailTest is L1AssetRouterTest {
    using stdStorage for StdStorage;

    function test_initialize_wrongOwner() public {
        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(sharedBridgeImpl),
            proxyAdmin,
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

    function test_initialize_wrongOwnerNTV() public {
        vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector));
        new TransparentUpgradeableProxy(
            address(nativeTokenVaultImpl),
            admin,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(L1NativeTokenVault.initialize.selector, address(0), address(0))
        );
    }

    function test_transferTokenToNTV_wrongCaller() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        l1Nullifier.transferTokenToNTV(address(token));
    }

    function test_nullifyChainBalanceByNTV_wrongCaller() public {
        vm.expectRevert();
        l1Nullifier.nullifyChainBalanceByNTV(chainId, address(token));
    }

    function test_registerToken_noCode() public {
        vm.expectRevert(abi.encodeWithSelector(EmptyToken.selector));
        nativeTokenVault.registerToken(address(0));
    }

    function test_setL1Erc20Bridge_alreadySet() public {
        address currentBridge = address(sharedBridge.legacyBridge());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AddressAlreadySet.selector, currentBridge));
        sharedBridge.setL1Erc20Bridge(IL1ERC20Bridge(address(0)));
    }

    function test_setL1Erc20Bridge_emptyAddressProvided() public {
        stdstore.target(address(sharedBridge)).sig(sharedBridge.legacyBridge.selector).checked_write(address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector));
        sharedBridge.setL1Erc20Bridge(IL1ERC20Bridge(address(0)));
    }

    function test_setNativeTokenVault_alreadySet() public {
        vm.prank(owner);
        vm.expectRevert(NativeTokenVaultAlreadySet.selector);
        sharedBridge.setNativeTokenVault(INativeTokenVault(address(0)));
    }

    function test_setNativeTokenVault_emptyAddressProvided() public {
        stdstore.target(address(sharedBridge)).sig(sharedBridge.nativeTokenVault.selector).checked_write(address(0));
        vm.prank(owner);
        vm.expectRevert(ZeroAddress.selector);
        sharedBridge.setNativeTokenVault(INativeTokenVault(address(0)));
    }

    function test_setAssetHandlerAddressOnCounterpart_wrongCounterPartAddress() public {
        bytes memory data = bytes.concat(
            SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION,
            abi.encode(tokenAssetId, address(token))
        );

        vm.prank(bridgehubAddress);
        vm.expectRevert(abi.encodeWithSelector(WrongCounterpart.selector));
        sharedBridge.bridgehubDeposit(eraChainId, owner, 0, data);
    }

    function test_transferFundsToSharedBridge_Eth_CallFailed() public {
        vm.mockCallRevert(address(nativeTokenVault), abi.encode(), "eth transfer failed");
        vm.prank(address(nativeTokenVault));
        vm.expectRevert(abi.encodeWithSelector(EthTransferFailed.selector));
        l1Nullifier.transferTokenToNTV(ETH_TOKEN_ADDRESS);
    }

    function test_transferFundsToSharedBridge_Eth_0_AmountTransferred() public {
        vm.deal(address(l1Nullifier), 0);
        vm.prank(address(nativeTokenVault));
        vm.expectRevert(abi.encodeWithSelector(NoFundsTransferred.selector));
        nativeTokenVault.transferFundsFromSharedBridge(ETH_TOKEN_ADDRESS);
    }

    function test_transferFundsToSharedBridge_Erc_0_AmountTransferred() public {
        vm.prank(address(l1Nullifier));
        token.transfer(address(1), amount);
        vm.prank(address(nativeTokenVault));
        vm.expectRevert(ZeroAmountToTransfer.selector);
        nativeTokenVault.transferFundsFromSharedBridge(address(token));
    }

    function test_transferFundsToSharedBridge_Erc_WrongAmountTransferred() public {
        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.balanceOf.selector), abi.encode(10));
        vm.prank(address(nativeTokenVault));
        vm.expectRevert(abi.encodeWithSelector(WrongAmountTransferred.selector, 0, 10));
        nativeTokenVault.transferFundsFromSharedBridge(address(token));
    }

    function test_bridgehubDepositBaseToken_Eth_Token_incorrectSender() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        sharedBridge.bridgehubDepositBaseToken{value: amount}(chainId, ETH_TOKEN_ASSET_ID, alice, amount);
    }

    function test_bridgehubDepositBaseToken_EthwrongMsgValue() public {
        vm.deal(bridgehubAddress, amount);
        vm.prank(bridgehubAddress);
        vm.expectRevert(abi.encodeWithSelector(ValueMismatch.selector, amount, uint256(1)));
        sharedBridge.bridgehubDepositBaseToken{value: 1}(chainId, ETH_TOKEN_ASSET_ID, alice, amount);
    }

    function test_bridgehubDepositBaseToken_ErcWrongMsgValue() public {
        vm.deal(bridgehubAddress, amount);
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), amount);
        vm.prank(bridgehubAddress);
        vm.expectRevert(NonEmptyMsgValue.selector);
        sharedBridge.bridgehubDepositBaseToken{value: amount}(chainId, tokenAssetId, alice, amount);
    }

    function test_bridgehubDepositBaseToken_ercWrongErcDepositAmount() public {
        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.balanceOf.selector), abi.encode(10));

        vm.prank(bridgehubAddress);
        vm.expectRevert(TokensWithFeesNotSupported.selector);
        sharedBridge.bridgehubDepositBaseToken(chainId, tokenAssetId, alice, amount);
    }

    function test_bridgehubDeposit_Erc_weth() public {
        vm.prank(bridgehubAddress);
        vm.expectRevert(BurningNativeWETHNotSupported.selector);
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(l1WethAddress, amount, bob));
    }

    function test_bridgehubDeposit_Eth_baseToken() public {
        vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseTokenAssetId.selector),
            abi.encode(ETH_TOKEN_ASSET_ID)
        );
        vm.expectRevert(abi.encodeWithSelector(AssetIdNotSupported.selector, ETH_TOKEN_ASSET_ID));
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(ETH_TOKEN_ADDRESS, 0, bob));
    }

    function test_bridgehubDeposit_Eth_wrongDepositAmount() public {
        _setBaseTokenAssetId(tokenAssetId);
        vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseTokenAssetId.selector),
            abi.encode(tokenAssetId)
        );
        vm.expectRevert(abi.encodeWithSelector(ValueMismatch.selector, amount, 0));
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(ETH_TOKEN_ADDRESS, amount, bob));
    }

    function test_bridgehubDeposit_Erc_msgValue() public {
        vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseTokenAssetId.selector),
            abi.encode(ETH_TOKEN_ASSET_ID)
        );
        vm.expectRevert(NonEmptyMsgValue.selector);
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit{value: amount}(chainId, alice, 0, abi.encode(address(token), amount, bob));
    }

    function test_bridgehubDeposit_Erc_wrongDepositAmount() public {
        vm.prank(bridgehubAddress);
        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.balanceOf.selector), abi.encode(10));
        vm.expectRevert(abi.encodeWithSelector(TokensWithFeesNotSupported.selector));
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(address(token), amount, bob));
    }

    function test_bridgehubDeposit_Eth() public {
        _setBaseTokenAssetId(tokenAssetId);
        vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(address(token))
        );
        vm.expectRevert(EmptyDeposit.selector);
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(ETH_TOKEN_ADDRESS, 0, bob));
    }

    function test_bridgehubConfirmL2Transaction_depositAlreadyHappened() public {
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        vm.prank(bridgehubAddress);
        vm.expectRevert(DepositExists.selector);
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

        vm.expectRevert(abi.encodeWithSelector(WithdrawFailed.selector));
        sharedBridge.finalizeWithdrawal({
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

        vm.expectRevert(ClaimFailedDepositFailed.selector);
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

    function test_bridgeRecoverFailedTransfer_invalidChainID() public {
        vm.store(address(l1Nullifier), bytes32(isWithdrawalFinalizedStorageLocation - 5), bytes32(uint256(0)));

        bytes memory transferData = abi.encode(amount, alice);
        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        require(l1Nullifier.depositHappened(chainId, txHash) == txDataHash, "Deposit not set");

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

        vm.expectRevert(
            abi.encodeWithSelector(SharedBridgeValueNotSet.selector, SharedBridgeKey.LegacyBridgeLastDepositBatch)
        );
        l1Nullifier.bridgeRecoverFailedTransfer({
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
        vm.store(address(l1Nullifier), bytes32(isWithdrawalFinalizedStorageLocation - 5), bytes32(uint256(2)));

        uint256 l2BatchNumber = 0;
        bytes memory transferData = abi.encode(amount, alice, ETH_TOKEN_ADDRESS);
        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        _setSharedBridgeDepositHappened(eraChainId, txHash, txDataHash);
        require(l1Nullifier.depositHappened(eraChainId, txHash) == txDataHash, "Deposit not set");
        console.log("txDataHash", uint256(txDataHash));

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

        vm.expectRevert(InsufficientChainBalance.selector);
        vm.mockCall(
            address(bridgehubAddress),
            abi.encodeWithSelector(IBridgehub.proveL1ToL2TransactionStatus.selector),
            abi.encode(true)
        );
        l1Nullifier.bridgeRecoverFailedTransfer({
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
        vm.expectRevert(abi.encodeWithSelector(InvalidProof.selector));
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

        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, 0));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        vm.expectRevert(abi.encodeWithSelector((NoFundsTransferred.selector)));
        l1Nullifier.claimFailedDeposit({
            _chainId: chainId,
            _depositSender: alice,
            _l1Token: ETH_TOKEN_ADDRESS,
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

        vm.expectRevert(DepositDoesNotExist.selector);
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

    function test_claimFailedDeposit_chainBalanceLow() public {
        _setNativeTokenVaultChainBalance(chainId, ETH_TOKEN_ADDRESS, 0);

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

        vm.expectRevert(InsufficientChainBalance.selector);
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

    function test_finalizeWithdrawal_EthOnEth_legacyTxFinalizedInSharedBridge() public {
        vm.deal(address(sharedBridge), amount);
        vm.deal(address(nativeTokenVault), amount);
        uint256 legacyBatchNumber = 0;

        vm.mockCall(
            l1ERC20BridgeAddress,
            abi.encodeWithSelector(IL1ERC20Bridge.isWithdrawalFinalized.selector),
            abi.encode(false)
        );

        vm.store(
            address(l1Nullifier),
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
        vm.store(address(l1Nullifier), bytes32(isWithdrawalFinalizedStorageLocation - 7), bytes32(uint256(0)));
        vm.deal(address(l1Nullifier), amount);
        vm.deal(address(nativeTokenVault), amount);

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );
        vm.expectRevert();

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
        vm.store(address(l1Nullifier), bytes32(isWithdrawalFinalizedStorageLocation - 6), bytes32(uint256(5)));
        vm.deal(address(nativeTokenVault), amount);

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );
        vm.expectRevert();

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
        vm.store(address(l1Nullifier), bytes32(isWithdrawalFinalizedStorageLocation - 7), bytes32(uint256(0)));
        vm.deal(address(nativeTokenVault), amount);

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );

        vm.mockCall(bridgehubAddress, abi.encode(IBridgehub.proveL2MessageInclusion.selector), abi.encode(true));

        vm.expectRevert(
            abi.encodeWithSelector(SharedBridgeValueNotSet.selector, SharedBridgeKey.PostUpgradeFirstBatch)
        );
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
        _setNativeTokenVaultChainBalance(chainId, ETH_TOKEN_ADDRESS, 1);

        vm.expectRevert(InsufficientChainBalance.selector);
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

        vm.expectRevert(InvalidProof.selector);
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

        vm.expectRevert(abi.encodeWithSelector(L2WithdrawalMessageWrongLength.selector, message.length));
        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

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

        vm.expectRevert(abi.encodeWithSelector(InvalidSelector.selector, IMailbox.proveL2LogInclusion.selector));
        sharedBridge.finalizeWithdrawal({
            _chainId: eraChainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_depositLegacyERC20Bridge_weth() public {
        uint256 l2TxGasLimit = 100000;
        uint256 l2TxGasPerPubdataByte = 100;
        address refundRecipient = address(0);

        vm.expectRevert(abi.encodeWithSelector(TokenNotSupported.selector, l1WethAddress));
        vm.prank(l1ERC20BridgeAddress);
        sharedBridge.depositLegacyErc20Bridge({
            _originalCaller: alice,
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
            _originalCaller: alice,
            _l2Receiver: bob,
            _l1Token: address(token),
            _amount: amount,
            _l2TxGasLimit: l2TxGasLimit,
            _l2TxGasPerPubdataByte: l2TxGasPerPubdataByte,
            _refundRecipient: address(1)
        });
    }
}
