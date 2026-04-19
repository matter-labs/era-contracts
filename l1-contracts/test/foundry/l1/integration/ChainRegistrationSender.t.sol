// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, Test, stdStorage, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

import {L2TransactionRequestTwoBridgesOuter} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {
    CHAIN_REGISTRATION_SENDER_ENCODING_VERSION,
    ChainRegistrationSender
} from "contracts/core/chain-registration/ChainRegistrationSender.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";

import {AddressesAlreadyGenerated} from "test/foundry/L1TestsErrors.sol";

import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {
    ChainsSettlementLayerMismatch,
    ChainsSettlingOnL1,
    ChainAlreadyRegistered
} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

import {LogFinder} from "test-utils/LogFinder.sol";

import {NEW_PRIORITY_REQUEST_SIGNATURE} from "test/foundry/TestsConstants.sol";

contract ChainRegistrationSenderTests is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    using stdStorage for StdStorage;
    using LogFinder for Vm.Log[];

    uint256 constant TEST_USERS_COUNT = 10;
    uint256 constant GATEWAY_CHAIN_ID = 506;
    address[] public users;
    address[] public l2ContractAddresses;

    // generate MAX_USERS addresses and append it to users array
    function _generateUserAddresses() internal {
        if (users.length != 0) {
            revert AddressesAlreadyGenerated();
        }

        for (uint256 i = 0; i < TEST_USERS_COUNT; i++) {
            address newAddress = makeAddr(string(abi.encode("account", i)));
            users.push(newAddress);
        }
    }

    function prepare() public {
        _generateUserAddresses();

        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);

        _deployEra();
        _deployZKChain(ETH_TOKEN_ADDRESS);

        for (uint256 i = 0; i < zkChainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            l2ContractAddresses.push(contractAddress);

            _addL2ChainContract(zkChainIds[i], contractAddress);
        }
    }

    function setUp() public {
        prepare();

        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.messageRoot),
            abi.encodeWithSelector(IL1MessageRoot.v31UpgradeChainBatchNumber.selector),
            abi.encode(10)
        );

        // Simulate gateway mode for integration tests.
        for (uint256 i = 0; i < zkChainIds.length; i++) {
            stdstore
                .target(address(addresses.bridgehub))
                .sig("settlementLayer(uint256)")
                .with_key(zkChainIds[i])
                .checked_write(GATEWAY_CHAIN_ID);
        }
    }

    function test_chainRegistrationSender() public {
        // Verify chain is not registered in fresh deployment
        assertFalse(
            addresses.chainRegistrationSender.chainRegisteredOnChain(zkChainIds[0], zkChainIds[1]),
            "Chain should not be registered before calling registerChain"
        );

         //@check This was unnecessarily being called by the owner. Test error or implementation error?
        vm.recordLogs();
        addresses.chainRegistrationSender.registerChain(zkChainIds[0], zkChainIds[1]);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Storage: chainRegisteredOnChain flag set to true
        assertTrue(
            addresses.chainRegistrationSender.chainRegisteredOnChain(zkChainIds[0], zkChainIds[1]),
            "Chain should be registered after calling registerChain"
        );

        // Event: NewPriorityRequest from the mailbox (service transaction was queued)
        logs.requireOne(NEW_PRIORITY_REQUEST_SIGNATURE);
    }

    function test_chainRegistrationSender_revertWhen_alreadyRegistered() public {
        addresses.chainRegistrationSender.registerChain(zkChainIds[0], zkChainIds[1]);

        vm.expectRevert(ChainAlreadyRegistered.selector);
        addresses.chainRegistrationSender.registerChain(zkChainIds[0], zkChainIds[1]);
    }

    /// This function use requestL2TransactionTwoBridges function through ChainRegistrationSender.
    /// No ERC20 tokens are involved — only ETH for base token gas.
    function _chainRegistrationSenderDeposit() private returns (bytes32, Vm.Log[] memory) {
        uint256 currentChainId = zkChainIds[0];
        address currentUser = users[0];

        uint256 gasPrice = 10000000;
        vm.txGasPrice(gasPrice);

        uint256 l2GasLimit = 1000000;
        MailboxFacet chainMailBox = MailboxFacet(getZKChainAddress(currentChainId));

        uint256 minRequiredGas = chainMailBox.l2TransactionBaseCost(
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );

        uint256 mintValue = minRequiredGas;
        vm.deal(currentUser, mintValue);

        uint256 userEthBefore = currentUser.balance;

        bytes memory secondBridgeCallData = bytes.concat(
            CHAIN_REGISTRATION_SENDER_ENCODING_VERSION,
            abi.encode(currentChainId)
        );
        L2TransactionRequestTwoBridgesOuter memory requestTx = _createL2TransactionRequestTwoBridges({
            _chainId: currentChainId,
            _mintValue: mintValue,
            _secondBridgeValue: 0,
            _secondBridgeAddress: address(addresses.chainRegistrationSender),
            _l2Value: 0,
            _l2GasLimit: l2GasLimit,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _secondBridgeCalldata: secondBridgeCallData
        });

        vm.recordLogs();
        vm.prank(currentUser);
        bytes32 resultantHash = addresses.bridgehub.requestL2TransactionTwoBridges{value: mintValue}(requestTx);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Balance assertion
        console2.log("balance before", userEthBefore);
        console2.log("mint value", mintValue);
        assertEq(currentUser.balance, userEthBefore - mintValue, "User ETH should decrease by mintValue");

        return (resultantHash, logs);
    }

    function test_chainRegistrationSenderDeposit() public {
        // Verify chain is not registered initially
        assertFalse(
            addresses.chainRegistrationSender.chainRegisteredOnChain(zkChainIds[0], zkChainIds[1]),
            "Chain should not be registered before deposit"
        );

        // Perform deposit and capture the transaction hash and emitted events
        (bytes32 txHash, Vm.Log[] memory logs) = _chainRegistrationSenderDeposit();

        // Verify the L2 transaction was submitted successfully
        // The txHash is the canonical transaction hash for the L2 transaction
        assertNotEq(txHash, bytes32(0), "Transaction hash should be non-zero after successful deposit");

        // Verify event: BridgehubDepositBaseTokenInitiated
        Vm.Log memory baseTokenLog = logs.requireOne(
            "BridgehubDepositBaseTokenInitiated(uint256,address,bytes32,uint256)"
        );
        assertEq(uint256(baseTokenLog.topics[1]), zkChainIds[0], "Base token deposit event chainId mismatch");

        // The TwoBridges path through ChainRegistrationSender does NOT update
        // chainRegisteredOnChain. Verify it remains unchanged.
        assertFalse(
            addresses.chainRegistrationSender.chainRegisteredOnChain(zkChainIds[0], zkChainIds[1]),
            "chainRegisteredOnChain should remain false after TwoBridges deposit"
        );
    }

    function test_chainRegistrationSender_revertWhen_chainsSettleOnL1() public {
        // Override settlement layers to L1 (block.chainid) to trigger the ChainsSettlingOnL1 guard
        stdstore
            .target(address(addresses.bridgehub))
            .sig("settlementLayer(uint256)")
            .with_key(zkChainIds[0])
            .checked_write(block.chainid);

        stdstore
            .target(address(addresses.bridgehub))
            .sig("settlementLayer(uint256)")
            .with_key(zkChainIds[1])
            .checked_write(block.chainid);

        vm.expectRevert(ChainsSettlingOnL1.selector);
        addresses.chainRegistrationSender.registerChain(zkChainIds[0], zkChainIds[1]);
    }

    function test_chainRegistrationSender_revertWhen_settlementLayersMismatch() public {
        uint256 firstSettlementLayer = GATEWAY_CHAIN_ID;
        uint256 secondSettlementLayer = GATEWAY_CHAIN_ID + 1;

        // Override settlement layers to different values to trigger the mismatch guard
        stdstore
            .target(address(addresses.bridgehub))
            .sig("settlementLayer(uint256)")
            .with_key(zkChainIds[0])
            .checked_write(firstSettlementLayer);

        stdstore
            .target(address(addresses.bridgehub))
            .sig("settlementLayer(uint256)")
            .with_key(zkChainIds[1])
            .checked_write(secondSettlementLayer);

        vm.expectRevert(
            abi.encodeWithSelector(ChainsSettlementLayerMismatch.selector, firstSettlementLayer, secondSettlementLayer)
        );
        addresses.chainRegistrationSender.registerChain(zkChainIds[0], zkChainIds[1]);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
