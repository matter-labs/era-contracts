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

import "forge-std/console.sol";

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
        sharedBridge = L1SharedBridge(address(sharedBridgeProxy));
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

    function test_bridgehubDeposit_Eth_bridgeNotInitialized() public {
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
        L2TransactionRequestTwoBridgesInner memory output = sharedBridge.bridgehubDeposit{value: amount}(
            chainId,
            alice,
            0,
            abi.encode(ETH_TOKEN_ADDRESS, 0, bob)
        );
    }

    function test_bridgehubDeposit_Erc_weth() public {
        vm.prank(bridgehubAddress);
        vm.expectRevert("ShB: WETH deposit not supported");
        L2TransactionRequestTwoBridgesInner memory output = sharedBridge.bridgehubDeposit(
            chainId,
            alice,
            0,
            abi.encode(l1WethAddress, amount, bob)
        );
    }

    function test_bridgehubDeposit_Eth_baseToken() public {
        vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
        vm.expectRevert("ShB: baseToken deposit not supported");
        L2TransactionRequestTwoBridgesInner memory output = sharedBridge.bridgehubDeposit(
            chainId,
            alice,
            0,
            abi.encode(ETH_TOKEN_ADDRESS, 0, bob)
        );
    }

    function test_bridgehubDeposit_Erc_wrongDepositAmount() public {
        vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
        vm.expectRevert("ShB wrong withdraw amount");
        L2TransactionRequestTwoBridgesInner memory output = sharedBridge.bridgehubDeposit(
            chainId,
            alice,
            0,
            abi.encode(address(token), amount, bob)
        );
    }

    function test_finalizeWithdrawal_WrongSelector() public {
        vm.deal(address(sharedBridge), amount);

        /// storing chainBalance
        uint256 chainBalanceLocationInStorage = uint256(6 - 1 + 1 + 1);
        vm.store(
            address(sharedBridge),
            keccak256(
                abi.encode(
                    uint256(uint160(ETH_TOKEN_ADDRESS)),
                    keccak256(abi.encode(chainId, chainBalanceLocationInStorage))
                )
            ),
            bytes32(amount)
        );
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseToken.selector),
            abi.encode(ETH_TOKEN_ADDRESS)
        );

        // notice that the selector is wrong
        bytes memory message = abi.encodePacked(IMailbox.proveL2LogInclusion.selector, alice, amount);
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
}
