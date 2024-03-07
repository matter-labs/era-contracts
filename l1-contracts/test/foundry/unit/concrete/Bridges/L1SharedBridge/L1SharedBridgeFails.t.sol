// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {L1SharedBridge} from "solpp/bridge/L1SharedBridge.sol";
import {Bridgehub} from "solpp/bridgehub/Bridgehub.sol";
import {L1ERC20Bridge} from "solpp/bridge/L1ERC20Bridge.sol";
import {ETH_TOKEN_ADDRESS} from "solpp/common/Config.sol";
import {IBridgehub, L2TransactionRequestTwoBridgesInner} from "solpp/bridgehub/IBridgehub.sol";
import {L2Message, TxStatus} from "solpp/common/Messaging.sol";
import {IMailbox} from "solpp/state-transition/chain-interfaces/IMailbox.sol";
import {IL1ERC20Bridge} from "solpp/bridge/interfaces/IL1ERC20Bridge.sol";
import {IL1SharedBridge} from "solpp/bridge/interfaces/IL1SharedBridge.sol";
import {TestnetERC20Token} from "solpp/dev-contracts/TestnetERC20Token.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "solpp/common/L2ContractAddresses.sol";
import {ERA_CHAIN_ID, ERA_DIAMOND_PROXY} from "solpp/common/Config.sol";
import {IGetters} from "solpp/state-transition/chain-interfaces/IGetters.sol";

// import "forge-std/console.sol";

/// We are testing all the specifici revert and require cases.
contract L1SharedBridgeFailTest is Test {
    event BridgehubDepositBaseTokenInitiated(
        uint256 indexed chainId,
        address indexed from,
        address l1Token,
        uint256 amount
    );

    event BridgehubDepositInitiated(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        address indexed from,
        address to,
        address l1Token,
        uint256 amount
    );

    event BridgehubDepositFinalized(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        bytes32 indexed l2DepositTxHash
    );

    event WithdrawalFinalizedSharedBridge(
        uint256 indexed chainId,
        address indexed to,
        address indexed l1Token,
        uint256 amount
    );

    event ClaimedFailedDepositSharedBridge(
        uint256 indexed chainId,
        address indexed to,
        address indexed l1Token,
        uint256 amount
    );

    event LegacyDepositInitiated(
        uint256 indexed chainId,
        bytes32 indexed l2DepositTxHash,
        address indexed from,
        address to,
        address l1Token,
        uint256 amount
    );

    L1SharedBridge sharedBridgeImpl;
    L1SharedBridge sharedBridge;
    address bridgehubAddress;
    address l1ERC20BridgeAddress;
    address l1WethAddress;
    address l2SharedBridge;
    TestnetERC20Token token;
    uint256 eraFirstPostUpgradeBatch;

    address owner;
    address admin;
    address zkSync;
    address alice;
    address bob;
    uint256 chainId;
    uint256 amount = 100;
    bytes32 txHash;

    uint256 l2BatchNumber;
    uint256 l2MessageIndex;
    uint16 l2TxNumberInBatch;
    bytes32[] merkleProof;

    // storing depoistHappend[chainId][l2TxHash] = txDataHash. DepositHappened is 3rd so 3 -1 + dependency storage slots
    uint256 depositLocationInStorage = uint256(3 - 1 + 1 + 1);
    uint256 chainBalanceLocationInStorage = uint256(6 - 1 + 1 + 1);
    uint256 isWithdrawalFinalizedStorageLocation = uint256(4 - 1 + 1 + 1);

    function setUp() public {
        owner = makeAddr("owner");
        admin = makeAddr("admin");
        // zkSync = makeAddr("zkSync");
        bridgehubAddress = makeAddr("bridgehub");
        alice = makeAddr("alice");
        // bob = makeAddr("bob");
        l1WethAddress = makeAddr("weth");
        l1ERC20BridgeAddress = makeAddr("l1ERC20Bridge");
        l2SharedBridge = makeAddr("l2SharedBridge");

        txHash = bytes32(uint256(uint160(makeAddr("txHash"))));
        l2BatchNumber = uint256(uint160(makeAddr("l2BatchNumber")));
        l2MessageIndex = uint256(uint160(makeAddr("l2MessageIndex")));
        l2TxNumberInBatch = uint16(uint160(makeAddr("l2TxNumberInBatch")));
        merkleProof = new bytes32[](1);
        eraFirstPostUpgradeBatch = 1;

        chainId = 1;

        token = new TestnetERC20Token("TestnetERC20Token", "TET", 18);
        sharedBridgeImpl = new L1SharedBridge(
            l1WethAddress,
            IBridgehub(bridgehubAddress),
            IL1ERC20Bridge(l1ERC20BridgeAddress)
        );
        TransparentUpgradeableProxy sharedBridgeProxy = new TransparentUpgradeableProxy(
            address(sharedBridgeImpl),
            admin,
            abi.encodeWithSelector(L1SharedBridge.initialize.selector, owner, eraFirstPostUpgradeBatch)
        );
        sharedBridge = L1SharedBridge(payable(sharedBridgeProxy));
        vm.prank(owner);
        sharedBridge.initializeChainGovernance(chainId, l2SharedBridge);
        vm.prank(owner);
        sharedBridge.initializeChainGovernance(ERA_CHAIN_ID, l2SharedBridge);
    }

    function test_initialize_wrongOwner() public {
        vm.expectRevert("ShB owner 0");
        new TransparentUpgradeableProxy(
            address(sharedBridgeImpl),
            admin,
            abi.encodeWithSelector(L1SharedBridge.initialize.selector, address(0), eraFirstPostUpgradeBatch)
        );
    }

    function test_bridgehubDepositBaseToken_EthwrongMsgValue() public {
        vm.deal(bridgehubAddress, amount);
        vm.prank(bridgehubAddress);
        vm.expectRevert("L1SharedBridge: msg.value not equal to amount");
        sharedBridge.bridgehubDepositBaseToken(chainId, alice, ETH_TOKEN_ADDRESS, amount);
    }

    function test_bridgehubDepositBaseToken_ErcWrongMsgValue() public {
        vm.deal(bridgehubAddress, amount);
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), amount);
        vm.prank(bridgehubAddress);
        vm.expectRevert("ShB m.v > 0 b d.it");
        sharedBridge.bridgehubDepositBaseToken{value: amount}(chainId, alice, address(token), amount);
    }

    function test_bridgehubDepositBaseToken_ErcWrongErcDepositAmount() public {
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), amount);

        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.balanceOf.selector), abi.encode(10));

        bytes memory message = bytes("3T");
        vm.expectRevert(message);
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
        vm.expectRevert("ShB l2 bridge not deployed");
        sharedBridge.bridgehubDeposit{value: amount}(chainId, alice, 0, abi.encode(ETH_TOKEN_ADDRESS, 0, bob));
    }

    function test_bridgehubDeposit_Erc_weth() public {
        vm.prank(bridgehubAddress);
        vm.expectRevert("ShB: WETH deposit not supported");
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(l1WethAddress, amount, bob));
    }

    function test_bridgehubDeposit_Eth_baseToken() public {
        vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
        vm.expectRevert("ShB: baseToken deposit not supported");
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
        vm.expectRevert("ShB wrong withdraw amount");
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
        vm.expectRevert("ShB m.v > 0 for BH d.it 2");
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
        bytes memory message = bytes("5T");
        vm.expectRevert(message);
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(address(token), amount, bob));
    }

    function test_bridgehubDeposit_Eth() public {
        vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(address(token))
        );
        bytes memory message = bytes("6T");
        vm.expectRevert(message);
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(ETH_TOKEN_ADDRESS, 0, bob));
    }

    function test_bridgehubConfirmL2Transaction_depositAlreadyHappened() public {
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        vm.store(
            address(sharedBridge),
            keccak256(abi.encode(txHash, keccak256(abi.encode(chainId, depositLocationInStorage)))),
            txDataHash
        );
        vm.prank(bridgehubAddress);
        vm.expectRevert("ShB tx hap");
        sharedBridge.bridgehubConfirmL2Transaction(chainId, txDataHash, txHash);
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
        sharedBridge.claimFailedDeposit(
            chainId,
            alice,
            ETH_TOKEN_ADDRESS,
            amount,
            txHash,
            l2BatchNumber,
            l2MessageIndex,
            l2TxNumberInBatch,
            merkleProof
        );
    }

    function test_claimFailedDeposit_amountZero() public {
        vm.deal(address(sharedBridge), amount);

        vm.mockCall(
            bridgehubAddress,
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
        vm.expectRevert(message);
        sharedBridge.claimFailedDeposit(
            chainId,
            alice,
            ETH_TOKEN_ADDRESS,
            0,
            txHash,
            l2BatchNumber,
            l2MessageIndex,
            l2TxNumberInBatch,
            merkleProof
        );
    }

    function test_claimFailedDeposit_depositDidNotHappen() public {
        vm.deal(address(sharedBridge), amount);

        vm.mockCall(
            bridgehubAddress,
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

        vm.expectRevert("ShB: d.it not hap");
        sharedBridge.claimFailedDeposit(
            chainId,
            alice,
            ETH_TOKEN_ADDRESS,
            amount,
            txHash,
            l2BatchNumber,
            l2MessageIndex,
            l2TxNumberInBatch,
            merkleProof
        );
    }

    function test_claimFailedDeposit_chainBalanceLow() public {
        vm.deal(address(sharedBridge), amount);

        bytes32 txDataHash = keccak256(abi.encode(alice, ETH_TOKEN_ADDRESS, amount));
        vm.store(
            address(sharedBridge),
            keccak256(abi.encode(txHash, keccak256(abi.encode(chainId, depositLocationInStorage)))),
            txDataHash
        );
        require(sharedBridge.depositHappened(chainId, txHash) == txDataHash, "Deposit not set");

        vm.mockCall(
            bridgehubAddress,
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

        vm.expectRevert("ShB n funds");
        sharedBridge.claimFailedDeposit(
            chainId,
            alice,
            ETH_TOKEN_ADDRESS,
            amount,
            txHash,
            l2BatchNumber,
            l2MessageIndex,
            l2TxNumberInBatch,
            merkleProof
        );
    }

    function test_finalizeWithdrawal_EthOnEth_LegacyTxFinalizedInERC20Bridge() public {
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

        vm.expectRevert("ShB: legacy withdrawal");
        sharedBridge.finalizeWithdrawal(
            ERA_CHAIN_ID,
            legacyBatchNumber,
            l2MessageIndex,
            l2TxNumberInBatch,
            message,
            merkleProof
        );
    }

    function test_finalizeWithdrawal_EthOnEth_LegacyTxFinalizedInSharedBridge() public {
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
                            keccak256(abi.encode(ERA_CHAIN_ID, isWithdrawalFinalizedStorageLocation))
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

        vm.expectRevert("Withdrawal is already finalized");
        sharedBridge.finalizeWithdrawal(
            ERA_CHAIN_ID,
            legacyBatchNumber,
            l2MessageIndex,
            l2TxNumberInBatch,
            message,
            merkleProof
        );
    }

    function test_finalizeWithdrawal_EthOnEth_LegacyTxFinalizedInDiamondProxy() public {
        vm.deal(address(sharedBridge), amount);
        uint256 legacyBatchNumber = 0;

        vm.mockCall(
            l1ERC20BridgeAddress,
            abi.encodeWithSelector(IL1ERC20Bridge.isWithdrawalFinalized.selector),
            abi.encode(false)
        );

        vm.mockCall(
            ERA_DIAMOND_PROXY,
            abi.encodeWithSelector(IGetters.isEthWithdrawalFinalized.selector),
            abi.encode(true)
        );

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );
        vm.expectRevert("Withdrawal is already finalized 2");

        sharedBridge.finalizeWithdrawal(
            ERA_CHAIN_ID,
            legacyBatchNumber,
            l2MessageIndex,
            l2TxNumberInBatch,
            message,
            merkleProof
        );
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

        vm.expectRevert("ShB not enough funds 2");

        sharedBridge.finalizeWithdrawal(
            chainId,
            l2BatchNumber,
            l2MessageIndex,
            l2TxNumberInBatch,
            message,
            merkleProof
        );
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

        vm.expectRevert("ShB withd w proof");

        sharedBridge.finalizeWithdrawal(
            chainId,
            l2BatchNumber,
            l2MessageIndex,
            l2TxNumberInBatch,
            message,
            merkleProof
        );
    }

    function test_parseL2WithdrawalMessage_WrongMsgLength() public {
        vm.deal(address(sharedBridge), amount);

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

        bytes memory message = abi.encodePacked(IMailbox.finalizeEthWithdrawal.selector);

        vm.expectRevert("ShB wrong msg len");
        sharedBridge.finalizeWithdrawal(
            chainId,
            l2BatchNumber,
            l2MessageIndex,
            l2TxNumberInBatch,
            message,
            merkleProof
        );
    }

    function test_parseL2WithdrawalMessage_WrongMsgLength2() public {
        vm.deal(address(sharedBridge), amount);

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector, alice, amount),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

        bytes memory message = abi.encodePacked(IL1ERC20Bridge.finalizeWithdrawal.selector, alice, amount); /// should have more data here

        vm.expectRevert("ShB wrong msg len 2");
        sharedBridge.finalizeWithdrawal(
            chainId,
            l2BatchNumber,
            l2MessageIndex,
            l2TxNumberInBatch,
            message,
            merkleProof
        );
    }

    function test_parseL2WithdrawalMessage_WrongSelector() public {
        vm.deal(address(sharedBridge), amount);

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

        // notice that the selector is wrong
        bytes memory message = abi.encodePacked(IMailbox.proveL2LogInclusion.selector, alice, amount);

        vm.expectRevert("ShB Incorrect message function selector");
        sharedBridge.finalizeWithdrawal(
            chainId,
            l2BatchNumber,
            l2MessageIndex,
            l2TxNumberInBatch,
            message,
            merkleProof
        );
    }

    function test_depositLegacyERC20Bridge_l2BridgeNotDeployed() public {
        uint256 l2TxGasLimit = 100000;
        uint256 l2TxGasPerPubdataByte = 100;
        address refundRecipient = address(0);

        vm.prank(owner);
        sharedBridge.initializeChainGovernance(ERA_CHAIN_ID, address(0));

        vm.expectRevert("ShB b. n dep");
        vm.prank(l1ERC20BridgeAddress);
        sharedBridge.depositLegacyErc20Bridge(
            alice,
            bob,
            address(token),
            amount,
            l2TxGasLimit,
            l2TxGasPerPubdataByte,
            refundRecipient
        );
    }

    function test_depositLegacyERC20Bridge_weth() public {
        uint256 l2TxGasLimit = 100000;
        uint256 l2TxGasPerPubdataByte = 100;
        address refundRecipient = address(0);

        vm.expectRevert("ShB: WETH deposit not supported 2");
        vm.prank(l1ERC20BridgeAddress);
        sharedBridge.depositLegacyErc20Bridge(
            alice,
            bob,
            l1WethAddress,
            amount,
            l2TxGasLimit,
            l2TxGasPerPubdataByte,
            refundRecipient
        );
    }

    function test_depositLegacyERC20Bridge_refundRecipient() public {
        uint256 l2TxGasLimit = 100000;
        uint256 l2TxGasPerPubdataByte = 100;

        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit LegacyDepositInitiated(ERA_CHAIN_ID, txHash, alice, bob, address(token), amount);

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.requestL2TransactionDirect.selector),
            abi.encode(txHash)
        );

        vm.prank(l1ERC20BridgeAddress);
        sharedBridge.depositLegacyErc20Bridge(
            alice,
            bob,
            address(token),
            amount,
            l2TxGasLimit,
            l2TxGasPerPubdataByte,
            address(1)
        );
    }
}
