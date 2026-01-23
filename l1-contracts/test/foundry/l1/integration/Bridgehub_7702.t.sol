// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/console2.sol";

import {IL1Bridgehub, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {SimpleExecutor} from "contracts/dev-contracts/SimpleExecutor.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK, ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2CanonicalTransaction, L2Message} from "contracts/common/Messaging.sol";

import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";

import {AddressesAlreadyGenerated} from "test/foundry/L1TestsErrors.sol";
import {BridgehubInvariantTests} from "test/foundry/l1/integration/BridgehubTests.t.sol";

contract Bridgehub_7702 is BridgehubInvariantTests {
    function setUp() public {
        prepare();
    }

    function prepare() public override {
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

    function test_DepositEthBase7702() external {
        uint256 randomCallerPk = uint256(keccak256("RANDOM_CALLER"));
        address payable randomCaller = payable(vm.addr(randomCallerPk));
        currentUser = randomCaller;
        uint256 l2Value = 100;
        uint256 currentChainId = 10;
        uint256 gasPrice = 10000000;
        vm.txGasPrice(gasPrice);

        simpleExecutor = new SimpleExecutor();

        uint256 l2GasLimit = 1000000; // reverts with 8
        uint256 minRequiredGas = _getMinRequiredGasPriceForChain(
            currentChainId,
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );

        uint256 mintValue = l2Value + minRequiredGas;
        vm.deal(currentUser, mintValue);

        bytes memory callData = abi.encode(currentTokenAddress, l2Value, chainContracts[currentChainId]);
        L2TransactionRequestDirect memory txRequest = _createL2TransactionRequestDirect({
            _chainId: currentChainId,
            _mintValue: mintValue,
            _l2Value: l2Value,
            _l2GasLimit: l2GasLimit,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _l2CallData: callData
        });

        bytes memory calldataForExecutor = abi.encodeWithSelector(
            IL1Bridgehub.requestL2TransactionDirect.selector,
            txRequest
        );

        vm.signAndAttachDelegation(address(simpleExecutor), randomCallerPk);
        vm.recordLogs();
        vm.prank(randomCaller);
        SimpleExecutor(randomCaller).execute(address(addresses.bridgehub), mintValue, calldataForExecutor);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify logs were emitted
        assertTrue(logs.length > 0, "Deposit should emit at least one log event");

        NewPriorityRequest memory request = _getNewPriorityQueueFromLogs(logs);

        // Verify the transaction was created correctly
        assertEq(
            currentUser,
            address(uint160(request.transaction.from)),
            "Transaction sender should be the current user"
        );
        assertNotEq(request.txHash, bytes32(0), "Transaction hash should not be zero");
        assertTrue(request.transaction.to != 0, "Transaction recipient should not be zero");
        assertEq(request.transaction.value, l2Value, "Transaction value should match l2Value");

        _handleRequestByMockL2Contract(request, RequestType.DIRECT);

        // Update tracking variables and verify they were updated
        depositsUsers[currentUser][ETH_TOKEN_ADDRESS] += mintValue;
        depositsBridge[currentChainAddress][ETH_TOKEN_ADDRESS] += mintValue;
        tokenSumDeposit[ETH_TOKEN_ADDRESS] += mintValue;
        l2ValuesSum[ETH_TOKEN_ADDRESS] += l2Value;

        // Verify tracking variables are consistent
        assertTrue(
            depositsUsers[currentUser][ETH_TOKEN_ADDRESS] >= mintValue,
            "User deposit tracking should be updated"
        );
        assertTrue(tokenSumDeposit[ETH_TOKEN_ADDRESS] >= mintValue, "Token sum deposit should be updated");
    }

    function depositEthSuccess(uint256 userIndexSeed, uint256 chainIndexSeed, uint256 l2Value) public {
        uint64 MAX = 2 ** 64 - 1;
        uint256 l2Value = bound(l2Value, 0.1 ether, MAX);

        emit log_string("DEPOSIT ETH");
        super.depositEthToBridgeSuccess(userIndexSeed, chainIndexSeed, l2Value);
    }

    function depositERC20Success(
        uint256 userIndexSeed,
        uint256 chainIndexSeed,
        uint256 tokenIndexSeed,
        uint256 l2Value
    ) public {
        uint64 MAX = 2 ** 64 - 1;
        uint256 l2Value = bound(l2Value, 0.1 ether, MAX);

        emit log_string("DEPOSIT ERC20");
        super.depositERC20ToBridgeSuccess(userIndexSeed, chainIndexSeed, tokenIndexSeed, l2Value);
    }

    function withdrawERC20Success(uint256 userIndexSeed, uint256 chainIndexSeed, uint256 amountToWithdraw) public {
        uint64 MAX = (2 ** 32 - 1) + 0.1 ether;
        uint256 amountToWithdraw = bound(amountToWithdraw, 0.1 ether, MAX);

        emit log_string("WITHDRAW ERC20");
        super.withdrawSuccess(userIndexSeed, chainIndexSeed, amountToWithdraw);
    }

    // add this to be excluded from coverage report
    function testBoundedBridgehubInvariant() internal {}
}
