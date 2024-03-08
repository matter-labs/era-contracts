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
import {ERA_CHAIN_ID} from "solpp/common/Config.sol";

contract L1SharedBridgeLegacyTest is Test {
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
    address l2SharedBridge;
    TestnetERC20Token token;

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

    function setUp() public {
        owner = makeAddr("owner");
        admin = makeAddr("admin");
        // zkSync = makeAddr("zkSync");
        bridgehubAddress = makeAddr("bridgehub");
        alice = makeAddr("alice");
        // bob = makeAddr("bob");
        address l1WethAddress = makeAddr("weth");
        l1ERC20BridgeAddress = makeAddr("l1ERC20Bridge");
        l2SharedBridge = makeAddr("l2SharedBridge");

        txHash = bytes32(uint256(uint160(makeAddr("txHash"))));
        l2BatchNumber = uint256(uint160(makeAddr("l2BatchNumber")));
        l2MessageIndex = uint256(uint160(makeAddr("l2MessageIndex")));
        l2TxNumberInBatch = uint16(uint160(makeAddr("l2TxNumberInBatch")));
        merkleProof = new bytes32[](1);

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
            abi.encodeWithSelector(L1SharedBridge.initialize.selector, owner, 0)
        );
        sharedBridge = L1SharedBridge(payable(sharedBridgeProxy));
        vm.prank(owner);
        sharedBridge.initializeChainGovernance(chainId, l2SharedBridge);
        vm.prank(owner);
        sharedBridge.initializeChainGovernance(ERA_CHAIN_ID, l2SharedBridge);
    }

    function test_depositLegacyERC20Bridge() public {
        uint256 l2TxGasLimit = 100000;
        uint256 l2TxGasPerPubdataByte = 100;
        address refundRecipient = address(0);

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
            refundRecipient
        );
    }

    function test_finalizeWithdrawalLegacyErc20Bridge_EthOnEth() public {
        vm.deal(address(sharedBridge), amount);

        /// storing chainBalance
        uint256 chainBalanceLocationInStorage = uint256(6 - 1 + 1 + 1);
        vm.store(
            address(sharedBridge),
            keccak256(
                abi.encode(
                    uint256(uint160(ETH_TOKEN_ADDRESS)),
                    keccak256(abi.encode(ERA_CHAIN_ID, chainBalanceLocationInStorage))
                )
            ),
            bytes32(amount)
        );
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
                ERA_CHAIN_ID,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(ERA_CHAIN_ID, alice, ETH_TOKEN_ADDRESS, amount);
        vm.prank(l1ERC20BridgeAddress);
        sharedBridge.finalizeWithdrawalLegacyErc20Bridge(
            l2BatchNumber,
            l2MessageIndex,
            l2TxNumberInBatch,
            message,
            merkleProof
        );
    }

    function test_finalizeWithdrawalLegacyErc20Bridge_ErcOnEth() public {
        token.mint(address(sharedBridge), amount);

        /// storing chainBalance
        uint256 chainBalanceLocationInStorage = uint256(6 - 1 + 1 + 1);
        vm.store(
            address(sharedBridge),
            keccak256(
                abi.encode(
                    uint256(uint160(address(token))),
                    keccak256(abi.encode(ERA_CHAIN_ID, chainBalanceLocationInStorage))
                )
            ),
            bytes32(amount)
        );
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            alice,
            address(token),
            amount
        );
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: l2SharedBridge,
            data: message
        });

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                ERA_CHAIN_ID,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit WithdrawalFinalizedSharedBridge(ERA_CHAIN_ID, alice, address(token), amount);
        vm.prank(l1ERC20BridgeAddress);
        sharedBridge.finalizeWithdrawalLegacyErc20Bridge(
            l2BatchNumber,
            l2MessageIndex,
            l2TxNumberInBatch,
            message,
            merkleProof
        );
    }

    function test_claimFailedDepositLegacyErc20Bridge_Erc() public {
        token.mint(address(sharedBridge), amount);

        // storing depoistHappend[chainId][l2TxHash] = txDataHash. DepositHappened is 3rd so 3 -1 + dependency storage slots
        uint256 depositLocationInStorage = uint256(3 - 1 + 1 + 1);
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        vm.store(
            address(sharedBridge),
            keccak256(abi.encode(txHash, keccak256(abi.encode(ERA_CHAIN_ID, depositLocationInStorage)))),
            txDataHash
        );
        require(sharedBridge.depositHappened(ERA_CHAIN_ID, txHash) == txDataHash, "Deposit not set");

        uint256 chainBalanceLocationInStorage = uint256(6 - 1 + 1 + 1);
        vm.store(
            address(sharedBridge),
            keccak256(
                abi.encode(
                    uint256(uint160(address(token))),
                    keccak256(abi.encode(ERA_CHAIN_ID, chainBalanceLocationInStorage))
                )
            ),
            bytes32(amount)
        );

        // Bridgehub bridgehub = new Bridgehub();
        // vm.store(address(bridgehub),  bytes32(uint256(5 +2)), bytes32(uint256(31337)));
        // require(address(bridgehub.deployer()) == address(31337), "Bridgehub: deployer wrong");

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(
                IBridgehub.proveL1ToL2TransactionStatus.selector,
                ERA_CHAIN_ID,
                txHash,
                l2BatchNumber,
                l2MessageIndex,
                l2TxNumberInBatch,
                merkleProof,
                TxStatus.Failure
            ),
            abi.encode(true)
        );

        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit ClaimedFailedDepositSharedBridge(ERA_CHAIN_ID, alice, address(token), amount);
        vm.prank(l1ERC20BridgeAddress);
        sharedBridge.claimFailedDepositLegacyErc20Bridge(
            alice,
            address(token),
            amount,
            txHash,
            l2BatchNumber,
            l2MessageIndex,
            l2TxNumberInBatch,
            merkleProof
        );
    }
}
