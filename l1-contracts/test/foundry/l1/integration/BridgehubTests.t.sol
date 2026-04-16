// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/console2.sol";

import {
    IL1Bridgehub,
    L2TransactionRequestDirect,
    L2TransactionRequestTwoBridgesOuter
} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {SimpleExecutor} from "contracts/dev-contracts/SimpleExecutor.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {IMailboxLegacy} from "contracts/state-transition/chain-interfaces/IMailboxLegacy.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {
    DEFAULT_L2_LOGS_TREE_ROOT_HASH,
    EMPTY_STRING_KECCAK,
    ETH_TOKEN_ADDRESS,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA
} from "contracts/common/Config.sol";
import {L2CanonicalTransaction, L2Message} from "contracts/common/Messaging.sol";

import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";

import {AddressesAlreadyGenerated} from "test/foundry/L1TestsErrors.sol";

import {LogFinder} from "test-utils/LogFinder.sol";

import {NEW_PRIORITY_REQUEST_SIGNATURE} from "test/foundry/TestsConstants.sol";

contract BridgehubInvariantTests is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    using LogFinder for Vm.Log[];

    uint256 constant TEST_USERS_COUNT = 10;

    enum RequestType {
        DIRECT,
        TWO_BRIDGES
    }

    struct NewPriorityRequest {
        uint256 txId;
        bytes32 txHash;
        uint64 expirationTimestamp;
        L2CanonicalTransaction transaction;
        bytes[] factoryDeps;
    }

    address[] public users;
    address[] public l2ContractAddresses;
    address[] public addressesToExclude;
    address public currentUser;
    uint256 public currentChainId;
    address public currentChainAddress;
    address public currentTokenAddress = ETH_TOKEN_ADDRESS;
    TestnetERC20Token currentToken;
    SimpleExecutor simpleExecutor;

    // Amounts deposited by each user, mapped by user address and token address
    mapping(address user => mapping(address token => uint256 deposited)) public depositsUsers;
    // Amounts deposited into the bridge, mapped by ZK chain address and token address
    mapping(address chain => mapping(address token => uint256 deposited)) public depositsBridge;
    // Total sum of deposits into the bridge, mapped by token address
    mapping(address token => uint256 deposited) public tokenSumDeposit;
    // Total sum of withdrawn tokens, mapped by token address
    mapping(address token => uint256 deposited) public tokenSumWithdrawal;
    // Total sum of L2 values transferred to mock contracts, mapped by token address
    mapping(address token => uint256 deposited) public l2ValuesSum;
    // Deposits into the ZK chains contract, mapped by L2 contract address and token address
    mapping(address l2contract => mapping(address token => uint256 balance)) public contractDeposits;
    // Total sum of deposits into all L2 contracts, mapped by token address
    mapping(address token => uint256 deposited) public contractDepositsSum;

    // gets random user from users array, set contract variables
    modifier useUser(uint256 userIndexSeed) {
        currentUser = users[bound(userIndexSeed, 0, users.length - 1)];
        vm.startPrank(currentUser);
        _;
        vm.stopPrank();
    }

    // gets random ZK chain from ZK chain ids, set contract variables
    modifier useZKChain(uint256 chainIndexSeed) {
        currentChainId = zkChainIds[bound(chainIndexSeed, 0, zkChainIds.length - 1)];
        currentChainAddress = getZKChainAddress(currentChainId);
        _;
    }

    // use token specified by address, set contract variables
    modifier useGivenToken(address tokenAddress) {
        currentToken = TestnetERC20Token(tokenAddress);
        currentTokenAddress = tokenAddress;
        _;
    }

    // use random token from tokens array, set contract variables
    modifier useRandomToken(uint256 tokenIndexSeed) {
        currentTokenAddress = tokens[bound(tokenIndexSeed, 0, tokens.length - 1)];
        currentToken = TestnetERC20Token(currentTokenAddress);
        _;
    }

    // use base token as main token
    // watch out, do not use with ETH
    modifier useBaseToken() {
        currentToken = TestnetERC20Token(getZKChainBaseToken(currentChainId));
        currentTokenAddress = address(currentToken);
        _;
    }

    // use ERC token by getting randomly token
    // it keeps iterating while the token is ETH
    modifier useERC20Token(uint256 tokenIndexSeed) {
        currentTokenAddress = tokens[bound(tokenIndexSeed, 0, tokens.length - 1)];

        while (currentTokenAddress == ETH_TOKEN_ADDRESS) {
            tokenIndexSeed += 1;
            currentTokenAddress = tokens[bound(tokenIndexSeed, 0, tokens.length - 1)];
        }

        currentToken = TestnetERC20Token(currentTokenAddress);

        _;
    }

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

    // TODO: consider what should be actually committed, do we need to simulate operator:
    // blocks -> batches -> commits or just mock it.
    function _commitBatchInfo(uint256 _chainId) internal {
        //vm.warp(COMMIT_TIMESTAMP_NOT_OLDER + 1 + 1);

        GettersFacet zkChainGetters = GettersFacet(getZKChainAddress(_chainId));

        IExecutor.StoredBatchInfo memory batchZero;

        batchZero.batchNumber = 0;
        batchZero.timestamp = 0;
        batchZero.numberOfLayer1Txs = 0;
        batchZero.priorityOperationsHash = EMPTY_STRING_KECCAK;
        batchZero.l2LogsTreeRoot = DEFAULT_L2_LOGS_TREE_ROOT_HASH;
        batchZero.batchHash = vm.parseBytes32("0x0000000000000000000000000000000000000000000000000000000000000000"); //genesis root hash
        batchZero.indexRepeatedStorageChanges = uint64(0);
        batchZero.commitment = vm.parseBytes32("0x0000000000000000000000000000000000000000000000000000000000000000");

        bytes32 hashedZeroBatch = keccak256(abi.encode(batchZero));
        assertEq(zkChainGetters.storedBatchHash(0), hashedZeroBatch);
    }

    // use mailbox interface to return exact amount to use as a gas on l2 side,
    // prevents from failing if mintValue < l2Value + required gas
    function _getMinRequiredGasPriceForChain(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) public view returns (uint256) {
        MailboxFacet chainMailBox = MailboxFacet(getZKChainAddress(_chainId));

        return chainMailBox.l2TransactionBaseCost(_gasPrice, _l2GasLimit, _l2GasPerPubdataByteLimit);
    }

    // decodes data encoded with encodeCall, this is just to decode information received from logs
    // to deposit into mock l2 contract
    function _getDecodedDepositL2Calldata(
        bytes memory callData
    ) internal view returns (address l1Sender, address l2Receiver, address l1Token, uint256 amount, bytes memory b) {
        // UnsafeBytes approach doesn't work, because abi is not deterministic
        bytes memory slicedData = new bytes(callData.length - 4);

        for (uint256 i = 4; i < callData.length; i++) {
            slicedData[i - 4] = callData[i];
        }

        (l1Sender, l2Receiver, l1Token, amount, b) = abi.decode(
            slicedData,
            (address, address, address, uint256, bytes)
        );
    }

    // handle event emitted from logs, just to ensure proper decoding to set mock contract balance
    function _handleRequestByMockL2Contract(NewPriorityRequest memory request, RequestType requestType) internal {
        address contractAddress = address(uint160(uint256(request.transaction.to)));

        address tokenAddress;
        address receiver;
        uint256 toSend;
        address l1Sender;
        uint256 balanceAfter;
        bytes memory temp;

        if (requestType == RequestType.TWO_BRIDGES) {
            (l1Sender, receiver, tokenAddress, toSend, temp) = _getDecodedDepositL2Calldata(request.transaction.data);
        } else {
            (tokenAddress, toSend, receiver) = abi.decode(request.transaction.data, (address, uint256, address));
        }

        assertEq(contractAddress, receiver);

        if (tokenAddress == ETH_TOKEN_ADDRESS) {
            uint256 balanceBefore = contractAddress.balance;
            vm.deal(contractAddress, toSend + balanceBefore);

            balanceAfter = contractAddress.balance;
        } else {
            TestnetERC20Token token = TestnetERC20Token(tokenAddress);
            token.mint(contractAddress, toSend);

            balanceAfter = token.balanceOf(contractAddress);
        }

        contractDeposits[contractAddress][tokenAddress] += toSend;
        contractDepositsSum[tokenAddress] += toSend;
        assertEq(balanceAfter, contractDeposits[contractAddress][tokenAddress]);
    }

    // gets event from logs
    function _getNewPriorityQueueFromLogs(
        Vm.Log[] memory logs
    ) internal pure returns (NewPriorityRequest memory request) {
        Vm.Log memory log = logs.requireOne(NEW_PRIORITY_REQUEST_SIGNATURE);

        (request.txId, request.txHash, request.expirationTimestamp, request.transaction, request.factoryDeps) = abi
            .decode(log.data, (uint256, bytes32, uint64, L2CanonicalTransaction, bytes[]));
    }

    /// @notice Deposits an ERC20 token to a ZK chain that uses ETH as its base token,
    /// using the TwoBridges path.
    /// @dev ETH is sent as `msg.value` to cover the base token gas cost (`mintValue`).
    /// The ERC20 token is transferred via the second bridge by approving the shared bridge
    /// and encoding the token address and amount in `secondBridgeCalldata`.
    /// Updates per-user, per-chain, and global deposit tracking for both ETH and the ERC20.
    function depositERC20ToEthChain(uint256 l2Value, address tokenAddress) private useGivenToken(tokenAddress) {
        uint256 gasPrice = 10000000;
        vm.txGasPrice(gasPrice);

        uint256 l2GasLimit = 1000000;
        uint256 minRequiredGas = _getMinRequiredGasPriceForChain(
            currentChainId,
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );

        uint256 mintValue = minRequiredGas;
        vm.deal(currentUser, mintValue);

        currentToken.mint(currentUser, l2Value);
        currentToken.approve(address(addresses.sharedBridge), l2Value);

        uint256 userEthBefore = currentUser.balance;
        uint256 userTokenBefore = currentToken.balanceOf(currentUser);

        bytes memory secondBridgeCallData = abi.encode(currentTokenAddress, l2Value, chainContracts[currentChainId]);
        L2TransactionRequestTwoBridgesOuter memory requestTx = _createL2TransactionRequestTwoBridges({
            _chainId: currentChainId,
            _mintValue: mintValue,
            _secondBridgeValue: 0,
            _secondBridgeAddress: address(addresses.sharedBridge),
            _l2Value: 0,
            _l2GasLimit: l2GasLimit,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _secondBridgeCalldata: secondBridgeCallData
        });

        vm.recordLogs();
        bytes32 resultantHash = addresses.bridgehub.requestL2TransactionTwoBridges{value: mintValue}(requestTx);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        NewPriorityRequest memory request = _getNewPriorityQueueFromLogs(logs);

        // --- Return value and tx hash ---
        assertNotEq(resultantHash, bytes32(0), "Resultant hash should not be zero");
        assertNotEq(request.txHash, bytes32(0), "Priority tx hash should not be zero");

        // --- Balance assertions ---
        // ETH consumed for base token gas
        assertEq(currentUser.balance, userEthBefore - mintValue, "User ETH should decrease by mintValue");
        // ERC20 consumed for the second bridge deposit
        assertEq(
            currentToken.balanceOf(currentUser),
            userTokenBefore - l2Value,
            "User ERC20 should decrease by l2Value"
        );

        // --- Tx field validation ---
        assertEq(request.transaction.reserved[0], mintValue, "Mint value should match");

        // --- Event: BridgehubDepositBaseTokenInitiated (ETH base token) ---
        Vm.Log memory baseTokenLog = logs.requireOne(
            "BridgehubDepositBaseTokenInitiated(uint256,address,bytes32,uint256)"
        );
        assertEq(uint256(baseTokenLog.topics[1]), currentChainId, "Base token deposit event chainId mismatch");

        // --- Event: BridgehubDepositInitiated (ERC20 second bridge) ---
        Vm.Log memory depositInitiatedLog = logs.requireOne(
            "BridgehubDepositInitiated(uint256,bytes32,address,bytes32,bytes)"
        );
        assertEq(uint256(depositInitiatedLog.topics[1]), currentChainId, "Deposit initiated event chainId mismatch");

        _handleRequestByMockL2Contract(request, RequestType.TWO_BRIDGES);

        depositsUsers[currentUser][ETH_TOKEN_ADDRESS] += mintValue;
        depositsBridge[currentChainAddress][ETH_TOKEN_ADDRESS] += mintValue;
        tokenSumDeposit[ETH_TOKEN_ADDRESS] += mintValue;

        depositsUsers[currentUser][currentTokenAddress] += l2Value;
        depositsBridge[currentChainAddress][currentTokenAddress] += l2Value;
        tokenSumDeposit[currentTokenAddress] += l2Value;
        l2ValuesSum[currentTokenAddress] += l2Value;
    }

    /// @notice Deposits ETH to a ZK chain that uses an ERC20 as its base token,
    /// using the TwoBridges path.
    /// @dev The ERC20 base token is minted and approved for `mintValue` (gas costs).
    /// ETH is sent as `secondBridgeValue` via `msg.value`. This is a dual-token flow:
    /// ERC20 pays for L2 gas, ETH is the actual deposit value.
    function depositEthToERC20Chain(uint256 l2Value) private useBaseToken {
        uint256 gasPrice = 10000000;
        vm.txGasPrice(gasPrice);

        uint256 l2GasLimit = 1000000;
        uint256 minRequiredGas = _getMinRequiredGasPriceForChain(
            currentChainId,
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );

        vm.deal(currentUser, l2Value);
        uint256 mintValue = minRequiredGas;
        currentToken.mint(currentUser, mintValue);
        currentToken.approve(address(addresses.sharedBridge), mintValue);

        uint256 userEthBefore = currentUser.balance;
        uint256 userTokenBefore = currentToken.balanceOf(currentUser);

        bytes memory secondBridgeCallData = abi.encode(ETH_TOKEN_ADDRESS, uint256(0), chainContracts[currentChainId]);
        L2TransactionRequestTwoBridgesOuter memory requestTx = _createL2TransactionRequestTwoBridges({
            _chainId: currentChainId,
            _mintValue: mintValue,
            _secondBridgeValue: l2Value,
            _secondBridgeAddress: address(addresses.sharedBridge),
            _l2Value: 0,
            _l2GasLimit: l2GasLimit,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _secondBridgeCalldata: secondBridgeCallData
        });

        vm.recordLogs();
        bytes32 resultantHash = addresses.bridgehub.requestL2TransactionTwoBridges{value: l2Value}(requestTx);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        NewPriorityRequest memory request = _getNewPriorityQueueFromLogs(logs);

        // --- Return value and tx hash ---
        assertNotEq(resultantHash, bytes32(0), "Resultant hash should not be zero");
        assertNotEq(request.txHash, bytes32(0), "Priority tx hash should not be zero");

        // --- Balance assertions ---
        // ETH consumed via secondBridgeValue
        assertEq(currentUser.balance, userEthBefore - l2Value, "User ETH should decrease by l2Value");
        // ERC20 base token consumed for gas (mintValue)
        assertEq(
            currentToken.balanceOf(currentUser),
            userTokenBefore - mintValue,
            "User ERC20 base token should decrease by mintValue"
        );

        // --- Tx field validation ---
        assertEq(request.transaction.reserved[0], mintValue, "Mint value should match");

        // --- Event: BridgehubDepositBaseTokenInitiated (ERC20 base token) ---
        Vm.Log memory baseTokenLog = logs.requireOne(
            "BridgehubDepositBaseTokenInitiated(uint256,address,bytes32,uint256)"
        );
        assertEq(uint256(baseTokenLog.topics[1]), currentChainId, "Base token deposit event chainId mismatch");

        // --- Event: BridgehubDepositInitiated (ETH second bridge) ---
        Vm.Log memory depositInitiatedLog = logs.requireOne(
            "BridgehubDepositInitiated(uint256,bytes32,address,bytes32,bytes)"
        );
        assertEq(uint256(depositInitiatedLog.topics[1]), currentChainId, "Deposit initiated event chainId mismatch");

        _handleRequestByMockL2Contract(request, RequestType.TWO_BRIDGES);

        depositsUsers[currentUser][ETH_TOKEN_ADDRESS] += l2Value;
        depositsBridge[currentChainAddress][ETH_TOKEN_ADDRESS] += l2Value;
        tokenSumDeposit[ETH_TOKEN_ADDRESS] += l2Value;
        l2ValuesSum[ETH_TOKEN_ADDRESS] += l2Value;

        depositsUsers[currentUser][currentTokenAddress] += mintValue;
        depositsBridge[currentChainAddress][currentTokenAddress] += mintValue;
        tokenSumDeposit[currentTokenAddress] += mintValue;
    }

    /// @notice Deposits an ERC20 token to a ZK chain that also uses an ERC20 as its base token,
    /// using the TwoBridges path.
    /// @dev Two separate ERC20 tokens are involved: the base token (for gas via `mintValue`)
    /// and the deposit token (for the L2 value via `secondBridgeCalldata`). Both are minted
    /// and approved independently. No ETH is sent with the call.
    /// Caller is responsible for ensuring `currentToken` differs from `baseTokenAddress`.
    function depositERC20ToERC20Chain(uint256 l2Value, address baseTokenAddress) private {
        uint256 gasPrice = 10000000;
        vm.txGasPrice(gasPrice);

        uint256 l2GasLimit = 1000000;
        uint256 minRequiredGas = _getMinRequiredGasPriceForChain(
            currentChainId,
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );

        uint256 mintValue = minRequiredGas;

        TestnetERC20Token baseToken = TestnetERC20Token(baseTokenAddress);
        baseToken.mint(currentUser, mintValue);
        baseToken.approve(address(addresses.sharedBridge), mintValue);

        currentToken.mint(currentUser, l2Value);
        currentToken.approve(address(addresses.sharedBridge), l2Value);

        uint256 userBaseBefore = baseToken.balanceOf(currentUser);
        uint256 userTokenBefore = currentToken.balanceOf(currentUser);

        bytes memory secondBridgeCallData = abi.encode(currentTokenAddress, l2Value, chainContracts[currentChainId]);
        L2TransactionRequestTwoBridgesOuter memory requestTx = _createL2TransactionRequestTwoBridges({
            _chainId: currentChainId,
            _mintValue: mintValue,
            _secondBridgeValue: 0,
            _secondBridgeAddress: address(addresses.sharedBridge),
            _l2Value: 0,
            _l2GasLimit: l2GasLimit,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _secondBridgeCalldata: secondBridgeCallData
        });

        vm.recordLogs();
        bytes32 resultantHash = addresses.bridgehub.requestL2TransactionTwoBridges(requestTx);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        NewPriorityRequest memory request = _getNewPriorityQueueFromLogs(logs);

        // --- Return value and tx hash ---
        assertNotEq(resultantHash, bytes32(0), "Resultant hash should not be zero");
        assertNotEq(request.txHash, bytes32(0), "Priority tx hash should not be zero");

        // --- Balance assertions ---
        assertEq(
            baseToken.balanceOf(currentUser),
            userBaseBefore - mintValue,
            "User base token should decrease by mintValue"
        );
        assertEq(
            currentToken.balanceOf(currentUser),
            userTokenBefore - l2Value,
            "User deposit token should decrease by l2Value"
        );

        // --- Tx field validation ---
        assertEq(request.transaction.reserved[0], mintValue, "Mint value should match");

        {
            // Code block to avoid stack too deep
            // --- Event: BridgehubDepositBaseTokenInitiated (ERC20 base) ---
            Vm.Log memory baseTokenLog = logs.requireOne(
                "BridgehubDepositBaseTokenInitiated(uint256,address,bytes32,uint256)"
            );
            assertEq(uint256(baseTokenLog.topics[1]), currentChainId, "Base token deposit event chainId mismatch");

            // --- Event: BridgehubDepositInitiated (ERC20 second bridge) ---
            Vm.Log memory depositInitiatedLog = logs.requireOne(
                "BridgehubDepositInitiated(uint256,bytes32,address,bytes32,bytes)"
            );
            assertEq(
                uint256(depositInitiatedLog.topics[1]),
                currentChainId,
                "Deposit initiated event chainId mismatch"
            );
        }
        _handleRequestByMockL2Contract(request, RequestType.TWO_BRIDGES);

        depositsUsers[currentUser][baseTokenAddress] += mintValue;
        depositsBridge[currentChainAddress][baseTokenAddress] += mintValue;
        tokenSumDeposit[baseTokenAddress] += mintValue;

        depositsUsers[currentUser][currentTokenAddress] += l2Value;
        depositsBridge[currentChainAddress][currentTokenAddress] += l2Value;
        tokenSumDeposit[currentTokenAddress] += l2Value;
        l2ValuesSum[currentTokenAddress] += l2Value;
    }

    /// @notice Deposits ETH to a ZK chain that uses ETH as its base token, using the Direct path.
    /// @dev The full `mintValue` (l2Value + gas) is sent as `msg.value` via
    /// `requestL2TransactionDirect`. The user is dealt exactly `mintValue` in ETH beforehand.
    function depositEthBase(uint256 l2Value) private {
        uint256 gasPrice = 10000000;
        vm.txGasPrice(gasPrice);

        uint256 l2GasLimit = 1000000;
        uint256 minRequiredGas = _getMinRequiredGasPriceForChain(
            currentChainId,
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );

        uint256 mintValue = l2Value + minRequiredGas;
        vm.deal(currentUser, mintValue);

        uint256 userEthBefore = currentUser.balance;

        bytes memory callData = abi.encode(currentTokenAddress, l2Value, chainContracts[currentChainId]);
        L2TransactionRequestDirect memory txRequest = _createL2TransactionRequestDirect({
            _chainId: currentChainId,
            _mintValue: mintValue,
            _l2Value: l2Value,
            _l2GasLimit: l2GasLimit,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _l2CallData: callData
        });

        vm.recordLogs();
        bytes32 resultantHash = addresses.bridgehub.requestL2TransactionDirect{value: mintValue}(txRequest);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        NewPriorityRequest memory request = _getNewPriorityQueueFromLogs(logs);

        // --- Return value and tx hash ---
        assertNotEq(resultantHash, bytes32(0), "Resultant hash should not be zero");
        assertNotEq(request.txHash, bytes32(0), "Priority tx hash should not be zero");

        // --- Balance assertions ---
        assertEq(currentUser.balance, userEthBefore - mintValue, "User ETH should decrease by mintValue");

        // --- Tx field validation ---
        assertEq(
            address(uint160(request.transaction.to)),
            chainContracts[currentChainId],
            "L2 contract should match chain's registered contract"
        );
        assertEq(request.transaction.value, l2Value, "L2 value should match");
        assertEq(request.transaction.reserved[0], mintValue, "Mint value should match");

        // --- Event: BridgehubDepositBaseTokenInitiated ---
        Vm.Log memory depositLog = logs.requireOne(
            "BridgehubDepositBaseTokenInitiated(uint256,address,bytes32,uint256)"
        );
        assertEq(uint256(depositLog.topics[1]), currentChainId, "Deposit event chainId mismatch");

        _handleRequestByMockL2Contract(request, RequestType.DIRECT);

        depositsUsers[currentUser][ETH_TOKEN_ADDRESS] += mintValue;
        depositsBridge[currentChainAddress][ETH_TOKEN_ADDRESS] += mintValue;
        tokenSumDeposit[ETH_TOKEN_ADDRESS] += mintValue;
        l2ValuesSum[ETH_TOKEN_ADDRESS] += l2Value;
    }

    /// @notice Deposits an ERC20 base token to its own ZK chain using the Direct path.
    /// @dev The ERC20 base token is minted and approved for `mintValue` (l2Value + gas).
    /// No ETH is sent with the Direct call since the base token is ERC20. A small amount
    /// of ETH is dealt to the user for L1 gas only (`vm.deal(currentUser, gasPrice)`).
    function depositERC20Base(uint256 l2Value) private useBaseToken {
        uint256 gasPrice = 10000000;
        vm.txGasPrice(gasPrice);
        vm.deal(currentUser, gasPrice);

        uint256 l2GasLimit = 1000000;
        uint256 minRequiredGas = _getMinRequiredGasPriceForChain(
            currentChainId,
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );

        uint256 mintValue = l2Value + minRequiredGas;
        currentToken.mint(currentUser, mintValue);
        currentToken.approve(address(addresses.sharedBridge), mintValue);

        uint256 userTokenBefore = currentToken.balanceOf(currentUser);
        uint256 userEthBefore = currentUser.balance;

        bytes memory callData = abi.encode(currentTokenAddress, l2Value, chainContracts[currentChainId]);
        L2TransactionRequestDirect memory txRequest = _createL2TransactionRequestDirect({
            _chainId: currentChainId,
            _mintValue: mintValue,
            _l2Value: l2Value,
            _l2GasLimit: l2GasLimit,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _l2CallData: callData
        });

        vm.recordLogs();
        bytes32 resultantHash = addresses.bridgehub.requestL2TransactionDirect(txRequest);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        NewPriorityRequest memory request = _getNewPriorityQueueFromLogs(logs);

        // --- Return value and tx hash ---
        assertNotEq(resultantHash, bytes32(0), "Resultant hash should not be zero");
        assertNotEq(request.txHash, bytes32(0), "Priority tx hash should not be zero");

        // --- Balance assertions ---
        assertEq(
            currentToken.balanceOf(currentUser),
            userTokenBefore - mintValue,
            "User ERC20 balance should decrease by mintValue"
        );
        // No ETH should be consumed (ERC20 base token chain, no {value} sent)
        assertEq(currentUser.balance, userEthBefore, "User ETH balance should remain unchanged");

        // --- Tx field validation ---
        assertEq(
            address(uint160(request.transaction.to)),
            chainContracts[currentChainId],
            "L2 contract should match chain's registered contract"
        );
        assertEq(request.transaction.value, l2Value, "L2 value should match");
        assertEq(request.transaction.reserved[0], mintValue, "Mint value should match");

        // --- Event: BridgehubDepositBaseTokenInitiated ---
        Vm.Log memory depositLog = logs.requireOne(
            "BridgehubDepositBaseTokenInitiated(uint256,address,bytes32,uint256)"
        );
        assertEq(uint256(depositLog.topics[1]), currentChainId, "Deposit event chainId mismatch");

        _handleRequestByMockL2Contract(request, RequestType.DIRECT);

        depositsUsers[currentUser][currentTokenAddress] += mintValue;
        depositsBridge[currentChainAddress][currentTokenAddress] += mintValue;
        tokenSumDeposit[currentTokenAddress] += mintValue;
        l2ValuesSum[currentTokenAddress] += l2Value;
    }

    /// @notice Finalizes an ERC20 token withdrawal from L2 to L1 via the shared bridge.
    /// @dev Constructs an L2-to-L1 message with `IL1ERC20Bridge.finalizeWithdrawal` selector,
    /// mocks the L2 message inclusion proof on the bridgehub, then calls
    /// `sharedBridge.finalizeWithdrawal`. The `isWithdrawalFinalized` flag is force-set to
    /// false via `stdstore` before the call to allow repeated invocations with the same params.
    /// Mock justification: L2 proof verification is mocked because L2 batch commitments and
    /// merkle trees are unavailable in this L1-only integration test environment.
    function withdrawERC20Token(uint256 amountToWithdraw, address tokenAddress) private useGivenToken(tokenAddress) {
        uint256 l2BatchNumber = uint256(uint160(makeAddr("l2BatchNumber")));
        uint256 l2MessageIndex = uint256(uint160(makeAddr("l2MessageIndex")));
        uint16 l2TxNumberInBatch = uint16(uint160(makeAddr("l2TxNumberInBatch")));
        bytes32[] memory merkleProof = new bytes32[](1);

        _setSharedBridgeIsWithdrawalFinalized(currentChainId, l2BatchNumber, l2MessageIndex, false);
        uint256 beforeChainBalance = addresses.l1Nullifier.chainBalance(currentChainId, currentTokenAddress);
        uint256 beforeBridgeBalance = currentToken.balanceOf(address(addresses.sharedBridge));
        uint256 beforeUserBalance = currentToken.balanceOf(currentUser);

        if (beforeChainBalance < amountToWithdraw) {
            vm.expectRevert("L1AR: not enough funds 2");
        } else {
            tokenSumWithdrawal[currentTokenAddress] += amountToWithdraw;
        }

        bytes memory message = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            currentUser,
            currentTokenAddress,
            amountToWithdraw
        );

        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            data: message
        });

        vm.mockCall(
            addresses.bridgehubProxyAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehubBase.proveL2MessageInclusion.selector,
                currentChainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        vm.recordLogs();
        addresses.sharedBridge.finalizeWithdrawal({
            _chainId: currentChainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });

        // If we reach here, the withdrawal succeeded — assert outcomes unconditionally
        // Chain balance decreased by withdrawal amount
        assertEq(
            beforeChainBalance - addresses.l1Nullifier.chainBalance(currentChainId, currentTokenAddress),
            amountToWithdraw,
            "Chain balance should decrease by withdrawal amount"
        );

        // Bridge token balance decreased
        assertEq(
            beforeBridgeBalance - currentToken.balanceOf(address(addresses.sharedBridge)),
            amountToWithdraw,
            "Bridge token balance should decrease by withdrawal amount"
        );

        // Recipient received tokens
        assertEq(
            currentToken.balanceOf(currentUser) - beforeUserBalance,
            amountToWithdraw,
            "User should receive withdrawn tokens"
        );

        // Withdrawal marked as finalized (replay protection)
        assertTrue(
            addresses.l1Nullifier.isWithdrawalFinalized(currentChainId, l2BatchNumber, l2MessageIndex),
            "Withdrawal should be marked as finalized"
        );

        // Event: DepositFinalizedAssetRouter
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory finalizedLog = logs.requireOne("DepositFinalizedAssetRouter(uint256,bytes32,bytes)");
        assertEq(uint256(finalizedLog.topics[1]), currentChainId, "DepositFinalizedAssetRouter chainId mismatch");
    }

    /// @notice Finalizes an ETH withdrawal from L2 to L1 via the shared bridge.
    /// @dev Same flow as `withdrawERC20Token` but uses `IMailboxLegacy.finalizeEthWithdrawal`
    /// selector and asserts ETH balances instead of ERC20 balances.
    /// Mock justification: L2 proof verification is mocked because L2 batch commitments and
    /// merkle trees are unavailable in this L1-only integration test environment.
    function withdrawETHToken(uint256 amountToWithdraw, address tokenAddress) private useGivenToken(tokenAddress) {
        uint256 l2BatchNumber = uint256(uint160(makeAddr("l2BatchNumber")));
        uint256 l2MessageIndex = uint256(uint160(makeAddr("l2MessageIndex")));
        uint16 l2TxNumberInBatch = uint16(uint160(makeAddr("l2TxNumberInBatch")));
        bytes32[] memory merkleProof = new bytes32[](1);

        _setSharedBridgeIsWithdrawalFinalized(currentChainId, l2BatchNumber, l2MessageIndex, false);
        uint256 beforeChainBalance = addresses.l1Nullifier.chainBalance(currentChainId, currentTokenAddress);
        uint256 beforeBridgeBalance = address(addresses.sharedBridge).balance;
        uint256 beforeUserBalance = currentUser.balance;

        if (beforeChainBalance < amountToWithdraw) {
            vm.expectRevert("L1AR: not enough funds 2");
        } else {
            tokenSumWithdrawal[currentTokenAddress] += amountToWithdraw;
        }

        bytes memory message = abi.encodePacked(
            IMailboxLegacy.finalizeEthWithdrawal.selector,
            currentUser,
            amountToWithdraw
        );
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: l2TxNumberInBatch,
            sender: L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            data: message
        });

        vm.mockCall(
            addresses.bridgehubProxyAddress,
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                IBridgehubBase.proveL2MessageInclusion.selector,
                currentChainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );

        vm.recordLogs();
        addresses.sharedBridge.finalizeWithdrawal({
            _chainId: currentChainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: message,
            _merkleProof: merkleProof
        });
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // If we reach here, the withdrawal succeeded — assert outcomes unconditionally
        assertEq(
            beforeChainBalance - addresses.l1Nullifier.chainBalance(currentChainId, currentTokenAddress),
            amountToWithdraw,
            "Chain balance should decrease by withdrawal amount"
        );
        assertEq(
            beforeBridgeBalance - address(addresses.sharedBridge).balance,
            amountToWithdraw,
            "Bridge ETH balance should decrease by withdrawal amount"
        );
        assertEq(currentUser.balance - beforeUserBalance, amountToWithdraw, "User should receive withdrawn ETH");
        assertTrue(
            addresses.l1Nullifier.isWithdrawalFinalized(currentChainId, l2BatchNumber, l2MessageIndex),
            "Withdrawal should be marked as finalized"
        );

        // Event: DepositFinalizedAssetRouter
        Vm.Log memory finalizedLog = logs.requireOne("DepositFinalizedAssetRouter(uint256,bytes32,bytes)");
        assertEq(uint256(finalizedLog.topics[1]), currentChainId, "DepositFinalizedAssetRouter chainId mismatch");
    }

    /// @notice Routes an ETH deposit to the correct internal handler based on the selected
    /// chain's base token.
    /// @dev If the chain's base token is ETH, uses the Direct path (`depositEthBase`).
    /// If the chain's base token is ERC20, uses the TwoBridges path (`depositEthToERC20Chain`).
    function depositEthToBridgeSuccess(
        uint256 userIndexSeed,
        uint256 chainIndexSeed,
        uint256 l2Value
    ) public virtual useUser(userIndexSeed) useZKChain(chainIndexSeed) useBaseToken {
        if (currentTokenAddress == ETH_TOKEN_ADDRESS) {
            depositEthBase(l2Value);
        } else {
            depositEthToERC20Chain(l2Value);
        }
    }

    /// @notice Routes an ERC20 deposit to the correct internal handler based on the selected
    /// chain's base token and the deposit token.
    /// @dev Three cases:
    ///   - ETH-base chain: uses `depositERC20ToEthChain` (TwoBridges, ETH for gas + ERC20 deposit)
    ///   - ERC20-base chain, deposit token == base token: uses `depositERC20Base` (Direct)
    ///   - ERC20-base chain, deposit token != base token: uses `depositERC20ToERC20Chain` (TwoBridges)
    function depositERC20ToBridgeSuccess(
        uint256 userIndexSeed,
        uint256 chainIndexSeed,
        uint256 tokenIndexSeed,
        uint256 l2Value
    ) public virtual useUser(userIndexSeed) useZKChain(chainIndexSeed) useERC20Token(tokenIndexSeed) {
        address chainBaseToken = getZKChainBaseToken(currentChainId);

        if (chainBaseToken == ETH_TOKEN_ADDRESS) {
            depositERC20ToEthChain(l2Value, currentTokenAddress);
        } else {
            if (currentTokenAddress == chainBaseToken) {
                depositERC20Base(l2Value);
            } else {
                depositERC20ToERC20Chain(l2Value, chainBaseToken);
            }
        }
    }

    /// @notice Routes a withdrawal to the correct internal handler based on the selected
    /// chain's base token.
    /// @dev If base token is ERC20, calls `withdrawERC20Token`. If ETH, calls `withdrawETHToken`.
    function withdrawSuccess(
        uint256 userIndexSeed,
        uint256 chainIndexSeed,
        uint256 amountToWithdraw
    ) public virtual useUser(userIndexSeed) useZKChain(chainIndexSeed) {
        address token = getZKChainBaseToken(currentChainId);

        if (token != ETH_TOKEN_ADDRESS) {
            withdrawERC20Token(amountToWithdraw, token);
        } else if (token == ETH_TOKEN_ADDRESS) {
            withdrawETHToken(amountToWithdraw, token);
        }
    }

    /// @notice Returns an array of addresses that should be excluded from invariant testing
    /// target selection.
    function getAddressesToExclude() public returns (address[] memory) {
        addressesToExclude.push(addresses.bridgehubProxyAddress);
        addressesToExclude.push(address(addresses.sharedBridge));

        for (uint256 i = 0; i < users.length; i++) {
            addressesToExclude.push(users[i]);
        }

        for (uint256 i = 0; i < l2ContractAddresses.length; i++) {
            addressesToExclude.push(l2ContractAddresses[i]);
        }

        for (uint256 i = 0; i < zkChainIds.length; i++) {
            addressesToExclude.push(getZKChainAddress(zkChainIds[i]));
        }

        return addressesToExclude;
    }

    function prepare() public virtual {
        _generateUserAddresses();

        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);

        _deployEra();
        // _deployZKChain(ETH_TOKEN_ADDRESS); // TODO(EVM-1391): Justify commented code
        _deployZKChain(tokens[0]);

        for (uint256 i = 0; i < zkChainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            l2ContractAddresses.push(contractAddress);

            _addL2ChainContract(zkChainIds[i], contractAddress);
        }
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
