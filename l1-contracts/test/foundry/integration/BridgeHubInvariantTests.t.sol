// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {IMailbox} from "contracts//state-transition/chain-interfaces/IMailbox.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {HyperchainDeployer} from "./_SharedHyperchainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {Test} from "forge-std/Test.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {L2Message, TxStatus} from "contracts/common/Messaging.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {Vm} from "forge-std/Vm.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {IL2Bridge} from "contracts/bridge/interfaces/IL2Bridge.sol";
import {UnsafeBytes} from "contracts/common/libraries/UnsafeBytes.sol";

contract BridgeHubInvariantTests is L1ContractDeployer, HyperchainDeployer, TokenDeployer, L2TxMocker {
    uint constant TEST_USERS_COUNT = 10;

    bytes32 constant NEW_PRIORITY_REQUEST_HASH =
        keccak256(
            "NewPriorityRequest(uint256,bytes32,uint64,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes),bytes[])"
        );

    struct NewPriorityRequest {
        uint256 txId;
        bytes32 txHash;
        uint64 expirationTimestamp;
        L2CanonicalTransaction transaction;
        bytes[] factoryDeps;
    }

    address[] users;
    address public currentUser;
    uint256 public currentChainId;
    address public currentChainAddress;
    address public currentTokenAddress = ETH_TOKEN_ADDRESS;
    TestnetERC20Token currentToken;

    mapping(address user => mapping(address token => uint256 deposited)) public depositsUsers;
    mapping(address chain => mapping(address token => uint256 deposited)) public depositsBridge;
    mapping(address token => uint256 deposited) public tokenSumDeposit;
    mapping(address token => uint256 deposited) public l2ValuesSum;
    mapping(address l2contract => mapping(address token => uint256 balance)) public contractDeposits;
    mapping(address token => uint256 deposited) public contractDepositsSum;

    // helper modifier to get some random user
    modifier useUser(uint256 userIndexSeed) {
        currentUser = users[bound(userIndexSeed, 0, users.length - 1)];
        vm.startPrank(currentUser);
        _;
        vm.stopPrank();
    }

    // helper modifier to use given hyperchain
    modifier useHyperchain(uint256 chainIndexSeed) {
        currentChainId = hyperchainIds[bound(chainIndexSeed, 0, hyperchainIds.length - 1)];
        currentChainAddress = getHyperchainAddress(currentChainId);
        _;
    }

    modifier useGivenToken(address tokenAddress) {
        currentToken = TestnetERC20Token(tokenAddress);
        currentTokenAddress = tokenAddress;
        _;
    }

    modifier useRandomToken(uint256 tokenIndexSeed) {
        currentTokenAddress = tokens[bound(tokenIndexSeed, 0, tokens.length - 1)];
        currentToken = TestnetERC20Token(currentTokenAddress);
        _;
    }

    // helper modifier to use given token
    modifier useBaseToken() {
        currentToken = TestnetERC20Token(getHyperchainBaseToken(currentChainId));
        currentTokenAddress = address(currentToken);
        _;
    }

    modifier useERC20Token(uint256 tokenIndexSeed) {
        currentTokenAddress = tokens[bound(tokenIndexSeed, 0, tokens.length - 1)];

        while (currentTokenAddress == ETH_TOKEN_ADDRESS) {
            tokenIndexSeed += 1;
            currentTokenAddress = tokens[bound(tokenIndexSeed, 0, tokens.length - 1)];
        }

        currentToken = TestnetERC20Token(currentTokenAddress);

        _;
    }

    // generate MAX_USERS addresses and append it to testing adr
    function generateUserAddresses() internal {
        require(users.length == 0, "Addresses already generated");

        for (uint i = 0; i < TEST_USERS_COUNT; i++) {
            address newAddress = makeAddr(string(abi.encode("account", i)));
            users.push(newAddress);
        }
    }

    function getMinRequiredGasPriceForChain(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) public view returns (uint256) {
        MailboxFacet chainMailBox = MailboxFacet(getHyperchainAddress(_chainId));

        return chainMailBox.l2TransactionBaseCost(_gasPrice, _l2GasLimit, _l2GasPerPubdataByteLimit);
    }

    function getDecodedDepositL2Calldata(
        bytes memory callData
    ) internal view returns (address l1Sender, address l2Receiver, address l1Token, uint256 amount, bytes memory b) {
        // UnsafeBytes approach doesn't work, because abi is not deterministic in this approach i guess
        bytes memory slicedData = new bytes(callData.length - 4);

        for (uint i = 4; i < callData.length; i++) {
            slicedData[i - 4] = callData[i];
        }

        (l1Sender, l2Receiver, l1Token, amount, b) = abi.decode(
            slicedData,
            (address, address, address, uint256, bytes)
        );
    }

    function handleRequestByMockL2Contract(NewPriorityRequest memory request) internal {
        address payable contractAddress = payable(address(uint160(uint256(request.transaction.to))));
        address someMockAddress = makeAddr("mocked");
        // uint256 toSend; // = request.transaction.value; //ETH CASE

        address tokenAddress;
        address receiver;
        uint256 toSend;
        address l1Sender;

        uint256 requestLength = request.transaction.data.length;
        bytes memory temp;

        if (requestLength == 612) {
            (l1Sender, receiver, tokenAddress, toSend, temp) = getDecodedDepositL2Calldata(request.transaction.data);
        } else {
            (tokenAddress, toSend, receiver) = abi.decode(request.transaction.data, (address, uint256, address));
        }

        assertEq(contractAddress, receiver);

        uint256 balanceAfter = 0;

        if (tokenAddress == ETH_TOKEN_ADDRESS) {
            vm.deal(someMockAddress, toSend);

            vm.startPrank(someMockAddress);
            bool sent = contractAddress.send(toSend);
            vm.stopPrank();
            assertEq(sent, true);

            balanceAfter = contractAddress.balance;
        } else {
            TestnetERC20Token token = TestnetERC20Token(tokenAddress);
            token.mint(someMockAddress, toSend);

            vm.startPrank(someMockAddress);
            token.approve(someMockAddress, toSend);
            bool sent = token.transferFrom(someMockAddress, contractAddress, toSend);
            vm.stopPrank();
            assertEq(sent, true);

            balanceAfter = token.balanceOf(contractAddress);
        }

        emit log_string("received");
        emit log_uint(toSend);

        contractDeposits[contractAddress][tokenAddress] += toSend;
        contractDepositsSum[tokenAddress] += toSend;
        assertEq(balanceAfter, contractDeposits[contractAddress][tokenAddress]);
    }

    function getNewPriorityQueueFromLogs(Vm.Log[] memory logs) internal returns (NewPriorityRequest memory request) {
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];

            if (log.topics[0] == NEW_PRIORITY_REQUEST_HASH) {
                (
                    request.txId,
                    request.txHash,
                    request.expirationTimestamp,
                    request.transaction,
                    request.factoryDeps
                ) = abi.decode(log.data, (uint256, bytes32, uint64, L2CanonicalTransaction, bytes[]));
            }
        }
    }

    function depositNonEthToEthChain(uint256 l2Value, address tokenAddress) private useGivenToken(tokenAddress) {
        uint256 gasPrice = 0.01 ether;
        vm.txGasPrice(gasPrice);

        uint256 l2GasLimit = 70000000; // reverts with 8
        uint256 minRequiredGas = getMinRequiredGasPriceForChain(
            currentChainId,
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );

        uint256 mintValue = minRequiredGas;
        vm.deal(currentUser, mintValue);

        currentToken.mint(currentUser, l2Value);
        assertEq(currentToken.balanceOf(currentUser), l2Value);
        currentToken.approve(address(sharedBridge), l2Value);

        bytes memory secondBridgeCallData = abi.encode(currentTokenAddress, l2Value, chainContracts[currentChainId]);
        L2TransactionRequestTwoBridgesOuter memory requestTx = createMockL2TransactionRequestTwoBridgesSecond(
            currentChainId,
            mintValue,
            0,
            address(sharedBridge),
            0, // L2 VALUE WHICH IS ALWAYS 0
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            secondBridgeCallData
        );

        vm.recordLogs();
        bytes32 resultantHash = bridgeHub.requestL2TransactionTwoBridges{value: mintValue}(requestTx);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        NewPriorityRequest memory request = getNewPriorityQueueFromLogs(logs);
        assertNotEq(request.txHash, 0);

        emit log_string("sent");
        emit log_uint(l2Value);

        handleRequestByMockL2Contract(request);
        depositsUsers[currentUser][ETH_TOKEN_ADDRESS] += mintValue;
        depositsBridge[currentChainAddress][ETH_TOKEN_ADDRESS] += mintValue;
        tokenSumDeposit[ETH_TOKEN_ADDRESS] += mintValue;

        depositsUsers[currentUser][currentTokenAddress] += l2Value;
        depositsBridge[currentChainAddress][currentTokenAddress] += l2Value;
        tokenSumDeposit[currentTokenAddress] += l2Value;
        l2ValuesSum[currentTokenAddress] += l2Value;
    }

    function depositEthToEthChain(uint256 l2Value) private {
        uint256 gasPrice = 0.01 ether;
        vm.txGasPrice(gasPrice);

        uint256 l2GasLimit = 70000000; // reverts with 8
        uint256 minRequiredGas = getMinRequiredGasPriceForChain(
            currentChainId,
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );

        uint256 mintValue = l2Value + minRequiredGas;
        vm.deal(currentUser, mintValue);

        bytes memory callData = abi.encode(currentTokenAddress, l2Value, chainContracts[currentChainId]);
        L2TransactionRequestDirect memory txRequest = createL2TransitionRequestDirectSecond(
            currentChainId,
            mintValue,
            l2Value,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            ETH_TOKEN_ADDRESS,
            callData
        );

        vm.recordLogs();
        bytes32 resultantHash = bridgeHub.requestL2TransactionDirect{value: mintValue}(txRequest);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        NewPriorityRequest memory request = getNewPriorityQueueFromLogs(logs);
        assertNotEq(request.txHash, 0);

        handleRequestByMockL2Contract(request);

        depositsUsers[currentUser][ETH_TOKEN_ADDRESS] += mintValue;
        depositsBridge[currentChainAddress][ETH_TOKEN_ADDRESS] += mintValue;
        tokenSumDeposit[ETH_TOKEN_ADDRESS] += mintValue;
        l2ValuesSum[ETH_TOKEN_ADDRESS] += l2Value;
    }

    // deposits base ERC20 token to the bridge
    // uses token provided as a input
    function depositERC20Base(uint256 l2Value) private useBaseToken {
        uint256 gasPrice = 0.01 ether;
        vm.txGasPrice(gasPrice);
        vm.deal(currentUser, gasPrice);

        uint256 l2GasLimit = 70000000; // reverts with 8
        uint256 minRequiredGas = getMinRequiredGasPriceForChain(
            currentChainId,
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );

        uint256 mintValue = l2Value + minRequiredGas;
        currentToken.mint(currentUser, mintValue);
        assertEq(currentToken.balanceOf(currentUser), mintValue);
        currentToken.approve(address(sharedBridge), mintValue);

        bytes memory callData = abi.encode(currentTokenAddress, l2Value, chainContracts[currentChainId]);
        L2TransactionRequestDirect memory txRequest = createL2TransitionRequestDirectSecond(
            currentChainId,
            mintValue,
            l2Value,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            currentTokenAddress,
            callData
        );

        vm.recordLogs();
        bytes32 resultantHash = bridgeHub.requestL2TransactionDirect(txRequest);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        NewPriorityRequest memory request = getNewPriorityQueueFromLogs(logs);
        assertNotEq(request.txHash, 0);

        handleRequestByMockL2Contract(request);

        depositsUsers[currentUser][currentTokenAddress] += mintValue;
        depositsBridge[currentChainAddress][currentTokenAddress] += mintValue;
        tokenSumDeposit[currentTokenAddress] += mintValue;
        l2ValuesSum[currentTokenAddress] += l2Value;
    }

    function depositEthToEthBridgeSuccess(
        uint256 userIndexSeed,
        uint256 chainIndexSeed,
        uint256 l2Value
    ) public virtual useUser(userIndexSeed) useHyperchain(chainIndexSeed) {
        if (getHyperchainBaseToken(currentChainId) == ETH_TOKEN_ADDRESS) {
            depositEthToEthChain(l2Value);
        } else {
            // idk
            //depositEthToNonEthChain(mintValue, l2Value);
        }
    }

    function depositEthToEthBridgeFails(
        uint256 userIndexSeed,
        uint256 chainIndexSeed,
        uint256 l2Value
    ) public virtual useUser(userIndexSeed) useHyperchain(chainIndexSeed) {
        if (getHyperchainBaseToken(currentChainId) == ETH_TOKEN_ADDRESS) {
            // idk
            //vm.expectRevert("Bridgehub: msg.value mismatch 1");
            //depositEthToNonEthChain(mintValue, l2Value);
        } else {
            vm.expectRevert("Bridgehub: non-eth bridge with msg.value");
            depositEthToEthChain(l2Value);
        }
    }

    function depositERC20TokenToBridgeSuccess(
        uint256 userIndexSeed,
        uint256 chainIndexSeed,
        uint256 tokenIndexSeed,
        uint256 l2Value
    ) public virtual useUser(userIndexSeed) useHyperchain(chainIndexSeed) useERC20Token(tokenIndexSeed) {
        address chainBaseToken = getHyperchainBaseToken(currentChainId);

        if (chainBaseToken == ETH_TOKEN_ADDRESS) {
            depositNonEthToEthChain(l2Value, currentTokenAddress);
        } else {
            if (currentTokenAddress == chainBaseToken) {
                depositERC20Base(l2Value);
            } else {
                // depositNonEthToNonEthChain(l2Value, currentTokenAddress);
            }
        }
    }

    function prepare() public {
        generateUserAddresses();

        deployL1Contracts();
        deployTokens();
        registerNewTokens(tokens);

        addNewHyperchainToDeploy("hyperchain1", ETH_TOKEN_ADDRESS);
        addNewHyperchainToDeploy("hyperchain2", ETH_TOKEN_ADDRESS);
        addNewHyperchainToDeploy("hyperchain3", tokens[0]);
        addNewHyperchainToDeploy("hyperchain4", tokens[0]);
        deployHyperchains();

        for (uint256 i = 0; i < hyperchainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            addL2ChainContract(hyperchainIds[i], contractAddress);

            registerL2SharedBridge(hyperchainIds[i], contractAddress);
        }
    }

    function test_hyperchainFinalizeWithdrawal() public {
        uint256 amountToWithdraw = 1 ether;
        _setSharedBridgeChainBalance(10, ETH_TOKEN_ADDRESS, amountToWithdraw);

        uint256 l2BatchNumber = uint256(uint160(makeAddr("l2BatchNumber")));
        uint256 l2MessageIndex = uint256(uint160(makeAddr("l2MessageIndex")));
        uint16 l2TxNumberInBatch = uint16(uint160(makeAddr("l2TxNumberInBatch")));
        bytes32[] memory merkleProof = new bytes32[](1);
        uint256 chainId = 10;

        vm.deal(address(sharedBridge), amountToWithdraw);

        bytes memory message = abi.encodePacked(IMailbox.finalizeEthWithdrawal.selector, alice, amountToWithdraw);
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            data: message
        });

        vm.mockCall(
            bridgehubProxyAddress,
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

        sharedBridge.finalizeWithdrawal({
            _chainId: chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });

        assertEq(alice.balance, amountToWithdraw);
        assertEq(address(sharedBridge).balance, 0);
    }
}

contract BoundedBridgeHubInvariantTests is BridgeHubInvariantTests {
    function depositEthSuccess(uint256 userIndexSeed, uint256 chainIndexSeed, uint256 l2Value) public {
        uint64 MAX = 2 ** 64 - 1;
        uint256 l2Value = bound(l2Value, 0.1 ether, MAX);

        super.depositEthToEthBridgeSuccess(userIndexSeed, chainIndexSeed, l2Value);
    }

    function depositEthFail(uint256 userIndexSeed, uint256 chainIndexSeed, uint256 l2Value) public {
        uint64 MAX = 2 ** 64 - 1;
        uint256 l2Value = bound(l2Value, 0.1 ether, MAX);

        super.depositEthToEthBridgeFails(userIndexSeed, chainIndexSeed, l2Value);
    }

    function depositERC20Success(
        uint256 userIndexSeed,
        uint256 chainIndexSeed,
        uint256 tokenIndexSeed,
        uint256 l2Value
    ) public {
        uint64 MAX = 2 ** 64 - 1;
        uint256 l2Value = bound(l2Value, 0.1 ether, MAX);

        super.depositERC20TokenToBridgeSuccess(userIndexSeed, chainIndexSeed, tokenIndexSeed, l2Value);
    }
}

contract InvariantTester is Test {
    BoundedBridgeHubInvariantTests tests;

    function setUp() public {
        tests = new BoundedBridgeHubInvariantTests();
        tests.prepare();

        FuzzSelector memory selector = FuzzSelector({addr: address(tests), selectors: new bytes4[](2)});

        selector.selectors[0] = BoundedBridgeHubInvariantTests.depositERC20Success.selector;
        selector.selectors[1] = BoundedBridgeHubInvariantTests.depositEthSuccess.selector;
        // selector.selectors[1] = BoundedBridgeHubInvariantTests.depositERC20Success.selector;

        targetContract(address(tests));
        targetSelector(selector);
    }

    // check wether eth sum of deposits shadowed between tests and updated on each deposit
    // equals balance of L1Shared bridge
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_ETHSumEqualsBalance() public {
        assertEq(tests.tokenSumDeposit(ETH_TOKEN_ADDRESS), tests.sharedBridgeProxyAddress().balance);
    }

    // check wether current token sum of deposits shadowed between tests and updated on each deposit
    // equals balance of L1Shared bridge
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_currentTokenSumEqualsBalance() public {
        address currentTokenAddress = tests.currentTokenAddress();
        if (currentTokenAddress != ETH_TOKEN_ADDRESS) {
            TestnetERC20Token token = TestnetERC20Token(currentTokenAddress);
            assertEq(
                tests.tokenSumDeposit(tests.currentTokenAddress()),
                token.balanceOf(tests.sharedBridgeProxyAddress())
            );
        }
    }

    // check if sum of ETH part which is send to L2 contract, registered by this test suite
    // is equals actual sum of balances of l2 contracts (which are mocked, but read events from logs)
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_ETHbalaceOnContractsDeposited() public {
        uint256 sum = 0;

        for (uint256 i = 0; i < 5; i++) {
            address l2Contract = tests.chainContracts(tests.hyperchainIds(i));
            uint256 balance = l2Contract.balance;

            assertEq(tests.contractDeposits(l2Contract, ETH_TOKEN_ADDRESS), balance);
            sum += balance;
        }

        assertEq(tests.l2ValuesSum(ETH_TOKEN_ADDRESS), sum);
        assertEq(tests.contractDepositsSum(ETH_TOKEN_ADDRESS), sum);
        assertEq(tests.l2ValuesSum(ETH_TOKEN_ADDRESS), tests.contractDepositsSum(ETH_TOKEN_ADDRESS));
    }

    // check if sum of currentToken part which is send to L2 contract, registered by this test suite
    // is equals actual sum of balances of l2 contracts (which are mocked, but read events from logs)
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_currentTokenBalaceOnContractsEqualsDeposited() public {
        address currentTokenAddress = tests.currentTokenAddress();
        uint256 sum = 0;

        if (currentTokenAddress == ETH_TOKEN_ADDRESS) {
            return;
        }

        for (uint256 i = 0; i < 5; i++) {
            TestnetERC20Token token = TestnetERC20Token(currentTokenAddress);
            address l2Contract = tests.chainContracts(tests.hyperchainIds(i));
            uint256 balance = token.balanceOf(l2Contract);
            assertEq(tests.contractDeposits(l2Contract, ETH_TOKEN_ADDRESS), balance);
            sum += balance;
        }

        assertEq(tests.l2ValuesSum(currentTokenAddress), sum);
        assertEq(tests.contractDepositsSum(currentTokenAddress), sum);
        assertEq(tests.l2ValuesSum(currentTokenAddress), tests.contractDepositsSum(currentTokenAddress));
    }
}
