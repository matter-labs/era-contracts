// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L1SharedBridgeTest} from "./_L1SharedBridge_Shared.t.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol"; 

import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2Message, TxStatus} from "contracts/common/Messaging.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {L2BridgeNotSet, L2WithdrawalMessageWrongLength, InsufficientChainBalance, ZeroAddress, ValueMismatch, NonEmptyMsgValue, DepositExists, ValueMismatch, NonEmptyMsgValue, TokenNotSupported, EmptyDeposit, L2BridgeNotDeployed, DepositIncorrectAmount, InvalidProof, NoFundsTransferred, SharedBridgeValueAlreadySet, SharedBridgeValueNotSet, Unauthorized, AddressAlreadyUsed, InsufficientFunds, DepositDoesNotExist, WithdrawalAlreadyFinalized, InsufficientFunds, MalformedMessage, InvalidSelector, TokensWithFeesNotSupported} from "contracts/common/L1ContractErrors.sol";

/// We are testing all the specified revert and require cases.
contract L1SharedBridgeFailTest is L1SharedBridgeTest {
    using stdStorage for StdStorage;

    function test_setL1Erc20Bridge_alreadySet(address anotherBridge) public {
        address bridge = makeAddr("bridge");
        L1SharedBridge sharedBridge = new L1SharedBridge({
            _l1WethAddress: l1WethAddress,
            _bridgehub: IBridgehub(bridgehubAddress),
            _eraChainId: eraChainId,
            _eraDiamondProxy: eraDiamondProxy
        });

        vm.prank(sharedBridge.owner());
        sharedBridge.transferOwnership(owner);
        vm.prank(owner);
        sharedBridge.acceptOwnership();

        vm.startPrank(owner);
        vm.expectRevert(ZeroAddress.selector);
        sharedBridge.setL1Erc20Bridge(address(0));

        sharedBridge.setL1Erc20Bridge(bridge);

        vm.expectRevert(abi.encodeWithSelector(AddressAlreadyUsed.selector, bridge));
        sharedBridge.setL1Erc20Bridge(anotherBridge);
        vm.stopPrank();
    }

    function test_bridgehubDepositBaseToken_callerNotBridgeHubOrEra(address caller, uint256 chainId) public {
        vm.assume(caller != bridgehubAddress);
        vm.assume(chainId != chainId || caller != eraDiamondProxy);

        vm.deal(caller, amount);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, caller));
        vm.prank(caller);
        sharedBridge.bridgehubDepositBaseToken{value: amount}(chainId, alice, ETH_TOKEN_ADDRESS, amount);
    }

    function test_receiveEth_notEra(uint256 amount, address caller) public {
        vm.assume(caller != eraDiamondProxy);
        vm.deal(caller, amount);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, caller));
        sharedBridge.receiveEth{value: amount}(eraChainId);
    }

    function test_setEraPostDiamondUpgradeFirstBatch_wrongValue(uint256 eraPostUpgradeFirstBatch) public {
        eraPostUpgradeFirstBatch = bound(eraPostUpgradeFirstBatch, 1, type(uint256).max);

        vm.prank(owner);
        sharedBridge.setEraPostDiamondUpgradeFirstBatch(eraPostUpgradeFirstBatch);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SharedBridgeValueAlreadySet.selector, 0));
        sharedBridge.setEraPostDiamondUpgradeFirstBatch(eraPostUpgradeFirstBatch);
    }

    function setEraPostLegacyBridgeUpgradeFirstBatch_wrongValue(uint256 eraPostLegacyBridgeUpgradeFirstBatch) public {
        eraPostUpgradeFirstBatch = bound(eraPostLegacyBridgeUpgradeFirstBatch, 1, type(uint256).max);

        vm.prank(owner);
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(eraPostLegacyBridgeUpgradeFirstBatch);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SharedBridgeValueAlreadySet.selector, 1));
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(eraPostLegacyBridgeUpgradeFirstBatch);
    }

    function test_setEraLegacyBridgeLastDepositTime_batchAlreadySet(
        uint256 eraLegacyBridgeLastDepositBatch,
        uint256 eraLegacyBridgeLastDepositTxNumber
    ) public {
        vm.startPrank(owner);
        sharedBridge.setEraLegacyBridgeLastDepositTime(0, 0);

        eraLegacyBridgeLastDepositBatch = bound(eraLegacyBridgeLastDepositTxNumber, 1, type(uint256).max);
        eraLegacyBridgeLastDepositTxNumber = 0;

        vm.startPrank(owner);
        sharedBridge.setEraLegacyBridgeLastDepositTime(
            eraLegacyBridgeLastDepositBatch,
            eraLegacyBridgeLastDepositTxNumber
        );

        vm.expectRevert(abi.encodeWithSelector(SharedBridgeValueAlreadySet.selector, 2));
        sharedBridge.setEraLegacyBridgeLastDepositTime(
            eraLegacyBridgeLastDepositBatch,
            eraLegacyBridgeLastDepositTxNumber
        );

        vm.stopPrank();
    }

    function test_setEraLegacyBridgeLastDepositTime_txnSet(
        uint256 eraLegacyBridgeLastDepositBatch,
        uint256 eraLegacyBridgeLastDepositTxNumber
    ) public {
        L1SharedBridge sharedBridgeImpl = new L1SharedBridge({
            _l1WethAddress: l1WethAddress,
            _bridgehub: IBridgehub(bridgehubAddress),
            _eraChainId: eraChainId,
            _eraDiamondProxy: eraDiamondProxy
        });
        TransparentUpgradeableProxy sharedBridgeProxy = new TransparentUpgradeableProxy(
            address(sharedBridgeImpl),
            admin,
            abi.encodeWithSelector(L1SharedBridge.initialize.selector, owner)
        );

        L1SharedBridge sharedBridge = L1SharedBridge(payable(sharedBridgeProxy));

        vm.startPrank(owner);
        sharedBridge.setEraLegacyBridgeLastDepositTime(0, 0);

        eraLegacyBridgeLastDepositBatch = 0;
        eraLegacyBridgeLastDepositTxNumber = bound(eraLegacyBridgeLastDepositTxNumber, 1, type(uint256).max);

        vm.startPrank(owner);
        sharedBridge.setEraLegacyBridgeLastDepositTime(
            eraLegacyBridgeLastDepositBatch,
            eraLegacyBridgeLastDepositTxNumber
        );

        vm.expectRevert(abi.encodeWithSelector(SharedBridgeValueAlreadySet.selector, 3));
        sharedBridge.setEraLegacyBridgeLastDepositTime(
            eraLegacyBridgeLastDepositBatch,
            eraLegacyBridgeLastDepositTxNumber
        );

        vm.stopPrank();
    }

    function test_initialize_wrongOwner() public {
        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(sharedBridgeImpl),
            proxyAdmin,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(L1SharedBridge.initialize.selector, address(0), eraPostUpgradeFirstBatch)
        );
    }

    function test_bridgehubDepositBaseToken_paused() public testPause {
        vm.prank(bridgehubAddress);
        sharedBridge.bridgehubDepositBaseToken(chainId, alice, address(token), amount);
    }

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
    }

    function test_bridgehubDepositBaseToken_ErcWrongErcDepositAmount() public {
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), amount);

        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.balanceOf.selector), abi.encode(10));

        vm.expectRevert(TokensWithFeesNotSupported.selector);
        vm.prank(bridgehubAddress);
        sharedBridge.bridgehubDepositBaseToken(chainId, alice, address(token), amount);
    }

    function test_bridgehubDeposit_Eth_l2BridgeNotDeployed() public {
        vm.prank(owner);
        sharedBridge.reinitializeChainGovernance(chainId, address(0));
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
    }

    function test_bridgehubDeposit_paused() public testPause {
        vm.prank(bridgehubAddress);
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(l1WethAddress, amount, bob));
    }

    function test_bridgehubDeposit_Erc_weth() public {
        vm.prank(bridgehubAddress);
        vm.expectRevert(abi.encodeWithSelector(TokenNotSupported.selector, l1WethAddress));
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(l1WethAddress, amount, bob));
    }

    function test_bridgehubDeposit_Eth_baseToken() public {
        vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
        vm.expectRevert(abi.encodeWithSelector(TokenNotSupported.selector, ETH_TOKEN_ADDRESS));
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(ETH_TOKEN_ADDRESS, 0, bob));
    }

    function test_bridgehubDeposit_Eth_wrongDepositAmount() public {
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), amount);
        vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(address(token))
        );
        vm.expectRevert(abi.encodeWithSelector(DepositIncorrectAmount.selector, 0, amount));
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(ETH_TOKEN_ADDRESS, amount, bob));
    }

    function test_bridgehubDeposit_Erc_msgValue() public {
        vm.deal(bridgehubAddress, amount);
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), amount);
        vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
        vm.expectRevert(NonEmptyMsgValue.selector);
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit{value: amount}(chainId, alice, 0, abi.encode(address(token), amount, bob));
    }

    function test_bridgehubDeposit_Erc_wrongDepositAmount() public {
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), amount);
        vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.balanceOf.selector), abi.encode(10));
        vm.expectRevert(abi.encodeWithSelector(DepositIncorrectAmount.selector, 0, amount));
        // solhint-disable-next-line func-named-parameters
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(address(token), amount, bob));
    }

    function test_bridgehubDeposit_Eth() public {
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

    function test_bridgehubConfirmL2Transaction_paused() public testPause {
        vm.prank(bridgehubAddress);
        sharedBridge.bridgehubConfirmL2Transaction(chainId, bytes32(0), bytes32(0));
    }

    function test_bridgehubConfirmL2Transaction_invalidCaller(address caller) public {
        vm.assume(caller != bridgehubAddress);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, caller));
        vm.prank(caller);
        sharedBridge.bridgehubConfirmL2Transaction(chainId, bytes32(0), bytes32(0));
    }

    function test_bridgehubConfirmL2Transaction_depositAlreadyHappened() public {
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        _setSharedBridgeDepositHappened(chainId, txHash, txDataHash);
        vm.prank(bridgehubAddress);
        vm.expectRevert(DepositExists.selector);
        sharedBridge.bridgehubConfirmL2Transaction(chainId, txDataHash, txHash);
    }

    function test_claimFialedDeposit_paused() public testPause {
        vm.prank(bridgehubAddress);
        sharedBridge.claimFailedDeposit({
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

    function test_claimFailedDeposit_proofInvalid() public {
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.proveL1ToL2TransactionStatus.selector),
            abi.encode(address(0))
        );
        vm.prank(bridgehubAddress);
        vm.expectRevert(InvalidProof.selector);
        sharedBridge.claimFailedDeposit({
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

        vm.expectRevert(NoFundsTransferred.selector);
        sharedBridge.claimFailedDeposit({
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

    function test_claimFailedDeposit_lastDepositTimeNotSet() public {
        vm.deal(address(sharedBridge), amount);

        // mock just to skip the require and progress to last deposit checks
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

        vm.expectRevert(abi.encodeWithSelector(SharedBridgeValueNotSet.selector, 2));
        sharedBridge.claimFailedDeposit({
            _chainId: eraChainId,
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
        sharedBridge.claimFailedDeposit({
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
        vm.deal(address(sharedBridge), amount);

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

        vm.expectRevert(InsufficientChainBalance.selector);
        sharedBridge.claimFailedDeposit({
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

    function test_finalizeWithdrawal_paused() public {
        vm.prank(owner);
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        vm.prank(owner);
        sharedBridge.pause();
        vm.expectRevert("Pausable: paused");
        sharedBridge.finalizeWithdrawal({
            _chainId: eraChainId,
            _l2BatchNumber: 0,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: new bytes(0),
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_EthOnEth_LegacyTxFinalizedInERC20Bridge() public {
        vm.prank(owner);
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(eraPostUpgradeFirstBatch);
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

    function test_finalizeWithdrawal_EthOnEth_LegacyTxFinalizedInSharedBridge() public {
        vm.prank(owner);
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(eraPostUpgradeFirstBatch);
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

    function test_finalizeWithdrawal_EthOnEth_UFBNotSet() public {
        vm.deal(address(sharedBridge), amount);
        uint256 legacyBatchNumber = 0;

        vm.mockCall(
            l1ERC20BridgeAddress,
            abi.encodeWithSelector(IL1ERC20Bridge.isWithdrawalFinalized.selector),
            abi.encode(false)
        );

        vm.mockCall(
            eraDiamondProxy,
            abi.encodeWithSelector(IGetters.isEthWithdrawalFinalized.selector),
            abi.encode(true)
        );

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );

        vm.expectRevert(abi.encodeWithSelector(SharedBridgeValueNotSet.selector, 1));
        sharedBridge.finalizeWithdrawal({
            _chainId: eraChainId,
            _l2BatchNumber: legacyBatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });

        vm.prank(owner);
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(eraPostUpgradeFirstBatch);

        vm.expectRevert(abi.encodeWithSelector(SharedBridgeValueNotSet.selector, 0));
        sharedBridge.finalizeWithdrawal({
            _chainId: eraChainId,
            _l2BatchNumber: legacyBatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawal_EthOnEth_LegacyTxFinalizedInDiamondProxy() public {
        vm.prank(owner);
        sharedBridge.setEraPostDiamondUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        vm.prank(owner);
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        vm.deal(address(sharedBridge), amount);
        uint256 legacyBatchNumber = 0;

        vm.mockCall(
            l1ERC20BridgeAddress,
            abi.encodeWithSelector(IL1ERC20Bridge.isWithdrawalFinalized.selector),
            abi.encode(false)
        );

        vm.mockCall(
            eraDiamondProxy,
            abi.encodeWithSelector(IGetters.isEthWithdrawalFinalized.selector),
            abi.encode(true)
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

    function test_finalizeWithdrawal_chainBalance() public {
        vm.deal(address(sharedBridge), amount);

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

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
        vm.deal(address(sharedBridge), amount);

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

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

    function test_parseL2WithdrawalMessage_WrongMsgLength() public {
        vm.deal(address(sharedBridge), amount);

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

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
        vm.prank(owner);
        sharedBridge.setEraPostDiamondUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        vm.prank(owner);
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(eraPostUpgradeFirstBatch);
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
            _chainId: eraChainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
    }

    function test_parseL2WithdrawalMessage_WrongSelector() public {
        vm.prank(owner);
        sharedBridge.setEraPostDiamondUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        vm.prank(owner);
        sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(eraPostUpgradeFirstBatch);
        vm.deal(address(sharedBridge), amount);

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

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

    function test_finalizeWithdrawalLegacyErc20Bridge_badCaller(address caller) public {
        vm.assume(caller != l1ERC20BridgeAddress);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, caller));
        vm.prank(caller);
        sharedBridge.finalizeWithdrawalLegacyErc20Bridge({
            _l2BatchNumber: 0,
            _l2MessageIndex: 0,
            _l2TxNumberInBatch: 0,
            _message: new bytes(0),
            _merkleProof: new bytes32[](0)
        });
    }

    function test_claimFailedDepositLegacyErc20Bridge_badCaller(address caller) public {
        vm.assume(caller != l1ERC20BridgeAddress);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, caller));
        vm.prank(caller);
        sharedBridge.claimFailedDepositLegacyErc20Bridge({
            _depositSender: address(0),
            _l1Token: address(0),
            _amount: 0,
            _l2TxHash: bytes32(0),
            _l2BatchNumber: 0,
            _l2MessageIndex: 0,
            _l2TxNumberInBatch: 0,
            _merkleProof: new bytes32[](0)
        });
    }

    function test_depositLegacyERC20Bridge_paused() public testPause {
        vm.prank(l1ERC20BridgeAddress);
        sharedBridge.depositLegacyErc20Bridge({
            _prevMsgSender: alice,
            _l2Receiver: bob,
            _l1Token: address(token),
            _amount: amount,
            _l2TxGasLimit: 100,
            _l2TxGasPerPubdataByte: 100000,
            _refundRecipient: address(0)
        });
    }

    function test_depositLegacyERC20Bridge_badCaller(address caller) public {
        vm.assume(caller != l1ERC20BridgeAddress);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, caller));
        vm.prank(caller);
        sharedBridge.depositLegacyErc20Bridge({
            _prevMsgSender: alice,
            _l2Receiver: bob,
            _l1Token: address(token),
            _amount: amount,
            _l2TxGasLimit: 100,
            _l2TxGasPerPubdataByte: 100000,
            _refundRecipient: address(0)
        });
    }

    function test_depositLegacyERC20Bridge_l2BridgeNotDeployed() public {
        uint256 l2TxGasLimit = 100000;
        uint256 l2TxGasPerPubdataByte = 100;
        address refundRecipient = address(0);

        vm.prank(owner);
        sharedBridge.reinitializeChainGovernance(eraChainId, address(0));

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

    function test_depositLegacyERC20Bridge_weth() public {
        uint256 l2TxGasLimit = 100000;
        uint256 l2TxGasPerPubdataByte = 100;
        address refundRecipient = address(0);

        vm.expectRevert(abi.encodeWithSelector(TokenNotSupported.selector, l1WethAddress));
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
