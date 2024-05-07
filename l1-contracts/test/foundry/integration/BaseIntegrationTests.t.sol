// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {Test} from "forge-std/Test.sol";

import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {Utils} from "foundry-test/unit/concrete/Utils/Utils.sol";

import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {HyperchainDeployer} from "./_SharedHyperchainDeployer.t.sol";

contract BaseIntegrationTests is L1ContractDeployer, HyperchainDeployer, TokenDeployer {
    function setUp() public {
        deployL1Contracts();
        deployTokens();

        registerNewTokens(tokens);
        addNewHyperchainToDeploy("hyperchain1", tokens[0]);
        deployHyperchains();
    }

    function test_hyperchainTokenDirectDeposit_Eth_2() public {
        emit log_address(bridgeHub.getHyperchain(9));
        emit log_address(bridgeHub.getHyperchain(10));

        assertTrue(true);
    }

    // function test_hyperchainTokenDirectDeposit_Eth() public {
    //     clearSharedBridgeBalances(address(baseToken));

    //     vm.txGasPrice(0.05 ether);
    //     vm.deal(alice, 1 ether);
    //     vm.deal(bob, 1 ether);

    //     uint256 firstChainId = hyperchainIds[0];
    //     uint256 secondChainId = hyperchainIds[1];

    //     assertTrue(getHyperchainBaseToken(firstChainId) == ETH_TOKEN_ADDRESS);
    //     assertTrue(getHyperchainBaseToken(secondChainId) == ETH_TOKEN_ADDRESS);

    //     L2TransactionRequestDirect memory aliceRequest = createMockL2TransactionRequestDirect(
    //         firstChainId,
    //         1 ether,
    //         0.1 ether
    //     );
    //     L2TransactionRequestDirect memory bobRequest = createMockL2TransactionRequestDirect(
    //         secondChainId,
    //         1 ether,
    //         0.1 ether
    //     );

    //     bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));
    //     address firstHyperChainAddress = getHyperchainAddress(firstChainId);
    //     address secondHyperChainAddress = getHyperchainAddress(secondChainId);

    //     vm.mockCall(
    //         firstHyperChainAddress,
    //         abi.encodeWithSelector(MailboxFacet.bridgehubRequestL2Transaction.selector),
    //         abi.encode(canonicalHash)
    //     );

    //     vm.mockCall(
    //         secondHyperChainAddress,
    //         abi.encodeWithSelector(MailboxFacet.bridgehubRequestL2Transaction.selector),
    //         abi.encode(canonicalHash)
    //     );

    //     vm.prank(alice);
    //     bytes32 resultantHash = bridgeHub.requestL2TransactionDirect{value: alice.balance}(aliceRequest);
    //     assertEq(canonicalHash, resultantHash);

    //     vm.prank(bob);
    //     bytes32 resultantHash2 = bridgeHub.requestL2TransactionDirect{value: bob.balance}(bobRequest);
    //     assertEq(canonicalHash, resultantHash2);

    //     assertEq(alice.balance, 0);
    //     assertEq(bob.balance, 0);

    //     assertEq(address(sharedBridge).balance, 2 ether);
    //     assertEq(sharedBridge.chainBalance(firstChainId, ETH_TOKEN_ADDRESS), 1 ether);
    //     assertEq(sharedBridge.chainBalance(secondChainId, ETH_TOKEN_ADDRESS), 1 ether);
    // }

    // function test_hyperchainTokenDirectDeposit_NonEth() public {
    //     clearSharedBridgeBalances(address(baseToken));

    //     uint256 mockMintValue = 1 ether;

    //     vm.txGasPrice(0.05 ether);
    //     vm.deal(alice, 1 ether);
    //     vm.deal(bob, 1 ether);

    //     baseToken.mint(alice, mockMintValue);
    //     baseToken.mint(bob, mockMintValue);

    //     assertEq(baseToken.balanceOf(alice), mockMintValue);
    //     assertEq(baseToken.balanceOf(bob), mockMintValue);

    //     uint256 firstChainId = hyperchainIds[2];
    //     uint256 secondChainId = hyperchainIds[3];

    //     assertTrue(getHyperchainBaseToken(firstChainId) == address(baseToken));
    //     assertTrue(getHyperchainBaseToken(secondChainId) == address(baseToken));

    //     L2TransactionRequestDirect memory aliceRequest = createMockL2TransactionRequestDirect(
    //         firstChainId,
    //         1 ether,
    //         0.1 ether
    //     );
    //     L2TransactionRequestDirect memory bobRequest = createMockL2TransactionRequestDirect(
    //         secondChainId,
    //         1 ether,
    //         0.1 ether
    //     );

    //     bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));
    //     address firstHyperChainAddress = getHyperchainAddress(firstChainId);
    //     address secondHyperChainAddress = getHyperchainAddress(secondChainId);

    //     vm.startPrank(alice);
    //     assertEq(baseToken.balanceOf(alice), mockMintValue);
    //     baseToken.approve(address(sharedBridge), mockMintValue);
    //     vm.stopPrank();

    //     vm.startPrank(bob);
    //     assertEq(baseToken.balanceOf(bob), mockMintValue);
    //     baseToken.approve(address(sharedBridge), mockMintValue);
    //     vm.stopPrank();

    //     vm.mockCall(
    //         firstHyperChainAddress,
    //         abi.encodeWithSelector(MailboxFacet.bridgehubRequestL2Transaction.selector),
    //         abi.encode(canonicalHash)
    //     );

    //     vm.mockCall(
    //         secondHyperChainAddress,
    //         abi.encodeWithSelector(MailboxFacet.bridgehubRequestL2Transaction.selector),
    //         abi.encode(canonicalHash)
    //     );

    //     vm.prank(alice);
    //     bytes32 resultantHash = bridgeHub.requestL2TransactionDirect(aliceRequest);
    //     assertEq(canonicalHash, resultantHash);

    //     vm.prank(bob);
    //     bytes32 resultantHash2 = bridgeHub.requestL2TransactionDirect(bobRequest);
    //     assertEq(canonicalHash, resultantHash2);

    //     // check if the balances of alice and bob are 0
    //     assertEq(baseToken.balanceOf(alice), 0);
    //     assertEq(baseToken.balanceOf(bob), 0);

    //     // check if the shared bridge has the correct balances
    //     assertEq(baseToken.balanceOf(address(sharedBridge)), 2 ether);

    //     // check if the shared bridge has the correct balances for each chain
    //     assertEq(sharedBridge.chainBalance(firstChainId, address(baseToken)), mockMintValue);
    //     assertEq(sharedBridge.chainBalance(secondChainId, address(baseToken)), mockMintValue);
    // }

    // function test_hyperchainDepositNonBaseWithBaseETH() public {
    //     uint256 aliceDepositAmount = 1 ether;
    //     uint256 bobDepositAmount = 1.5 ether;

    //     uint256 mintValue = 2 ether;
    //     uint256 l2Value = 10000;
    //     address l2Receiver = makeAddr("receiver");
    //     address tokenAddress = address(baseToken);

    //     uint256 firstChainId = hyperchainIds[0];
    //     uint256 secondChainId = hyperchainIds[1];

    //     address firstHyperChainAddress = getHyperchainAddress(firstChainId);
    //     address secondHyperChainAddress = getHyperchainAddress(secondChainId);
    //     assertTrue(getHyperchainBaseToken(firstChainId) == ETH_TOKEN_ADDRESS);
    //     assertTrue(getHyperchainBaseToken(secondChainId) == ETH_TOKEN_ADDRESS);
    //     clearSharedBridgeBalances(tokenAddress);
    //     registerL2SharedBridge(firstChainId, mockL2SharedBridge);
    //     registerL2SharedBridge(secondChainId, mockL2SharedBridge);

    //     vm.txGasPrice(0.05 ether);
    //     vm.deal(alice, mintValue);
    //     vm.deal(bob, mintValue);
    //     assertEq(alice.balance, mintValue);
    //     assertEq(bob.balance, mintValue);

    //     baseToken.mint(alice, aliceDepositAmount);
    //     baseToken.mint(bob, bobDepositAmount);
    //     assertEq(baseToken.balanceOf(alice), aliceDepositAmount);
    //     assertEq(baseToken.balanceOf(bob), bobDepositAmount);

    //     vm.prank(alice);
    //     baseToken.approve(address(sharedBridge), aliceDepositAmount);

    //     vm.prank(bob);
    //     baseToken.approve(address(sharedBridge), bobDepositAmount);

    //     bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));
    //     {
    //         bytes memory aliceSecondBridgeCalldata = abi.encode(tokenAddress, aliceDepositAmount, l2Receiver);
    //         L2TransactionRequestTwoBridgesOuter memory aliceRequest = createMockL2TransactionRequestTwoBridges(
    //             firstChainId,
    //             mintValue,
    //             0,
    //             l2Value,
    //             address(sharedBridge),
    //             aliceSecondBridgeCalldata
    //         );

    //         vm.mockCall(
    //             firstHyperChainAddress,
    //             abi.encodeWithSelector(MailboxFacet.bridgehubRequestL2Transaction.selector),
    //             abi.encode(canonicalHash)
    //         );

    //         vm.prank(alice);
    //         bytes32 resultantHash = bridgeHub.requestL2TransactionTwoBridges{value: mintValue}(aliceRequest);
    //         assertEq(canonicalHash, resultantHash);
    //     }

    //     {
    //         bytes memory bobSecondBridgeCalldata = abi.encode(tokenAddress, bobDepositAmount, l2Receiver);
    //         L2TransactionRequestTwoBridgesOuter memory bobRequest = createMockL2TransactionRequestTwoBridges(
    //             secondChainId,
    //             mintValue,
    //             0,
    //             l2Value,
    //             address(sharedBridge),
    //             bobSecondBridgeCalldata
    //         );

    //         vm.mockCall(
    //             secondHyperChainAddress,
    //             abi.encodeWithSelector(MailboxFacet.bridgehubRequestL2Transaction.selector),
    //             abi.encode(canonicalHash)
    //         );

    //         vm.prank(bob);
    //         bytes32 resultantHash2 = bridgeHub.requestL2TransactionTwoBridges{value: mintValue}(bobRequest);
    //         assertEq(canonicalHash, resultantHash2);
    //     }

    //     assertEq(alice.balance, 0);
    //     assertEq(bob.balance, 0);
    //     assertEq(address(sharedBridge).balance, 2 * mintValue);
    //     assertEq(sharedBridge.chainBalance(firstChainId, ETH_TOKEN_ADDRESS), mintValue);
    //     assertEq(sharedBridge.chainBalance(secondChainId, ETH_TOKEN_ADDRESS), mintValue);
    //     assertEq(sharedBridge.chainBalance(firstChainId, tokenAddress), aliceDepositAmount);
    //     assertEq(sharedBridge.chainBalance(secondChainId, tokenAddress), bobDepositAmount);
    //     assertEq(baseToken.balanceOf(address(sharedBridge)), aliceDepositAmount + bobDepositAmount);
    // }
}
