// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {
    L2TransactionRequestDirect,
    L2TransactionRequestTwoBridgesOuter
} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
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
import {FinalizeL1DepositParams, L2CanonicalTransaction, L2Message, ProofData} from "contracts/common/Messaging.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";
import {IAssetTrackerBase} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";

import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {AddressesAlreadyGenerated} from "test/foundry/L1TestsErrors.sol";

contract BridgehubInvariantTests_1 is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    //@check Why is this file practically the same as BridgehubTests.t.sol???
    uint256 constant TEST_USERS_COUNT = 10;

    bytes32 constant NEW_PRIORITY_REQUEST_HASH =
        keccak256(
            "NewPriorityRequest(uint256,bytes32,uint64,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes),bytes[])"
        );

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
    function _getNewPriorityQueueFromLogs(Vm.Log[] memory logs) internal returns (NewPriorityRequest memory request) {
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

    // deposits ERC20 token to the ZK chain where base token is ETH
    // this function use requestL2TransactionTwoBridges function from shared bridge.
    // tokenAddress should be any ERC20 token, excluding ETH
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

        assertNotEq(resultantHash, bytes32(0));
        assertNotEq(request.txHash, bytes32(0));
        _handleRequestByMockL2Contract(request, RequestType.TWO_BRIDGES);

        depositsUsers[currentUser][ETH_TOKEN_ADDRESS] += mintValue;
        depositsBridge[currentChainAddress][ETH_TOKEN_ADDRESS] += mintValue;
        tokenSumDeposit[ETH_TOKEN_ADDRESS] += mintValue;

        depositsUsers[currentUser][currentTokenAddress] += l2Value;
        depositsBridge[currentChainAddress][currentTokenAddress] += l2Value;
        tokenSumDeposit[currentTokenAddress] += l2Value;
        l2ValuesSum[currentTokenAddress] += l2Value;
    }

    // deposits ETH token to chain where base token is some ERC20
    // modifier prevents you from using some other token as base
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

        assertNotEq(resultantHash, bytes32(0));
        assertNotEq(request.txHash, bytes32(0));
        _handleRequestByMockL2Contract(request, RequestType.TWO_BRIDGES);

        depositsUsers[currentUser][ETH_TOKEN_ADDRESS] += l2Value;
        depositsBridge[currentChainAddress][ETH_TOKEN_ADDRESS] += l2Value;
        tokenSumDeposit[ETH_TOKEN_ADDRESS] += l2Value;
        l2ValuesSum[ETH_TOKEN_ADDRESS] += l2Value;

        depositsUsers[currentUser][currentTokenAddress] += mintValue;
        depositsBridge[currentChainAddress][currentTokenAddress] += mintValue;
        tokenSumDeposit[currentTokenAddress] += mintValue;
    }

    // deposits ERC20 to token with base being also ERC20
    // there are no modifiers so watch out, baseTokenAddress should be base of ZK chain
    // currentToken should be different from base
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

        assertNotEq(resultantHash, bytes32(0));
        assertNotEq(request.txHash, bytes32(0));
        _handleRequestByMockL2Contract(request, RequestType.TWO_BRIDGES);

        depositsUsers[currentUser][baseTokenAddress] += mintValue;
        depositsBridge[currentChainAddress][baseTokenAddress] += mintValue;
        tokenSumDeposit[baseTokenAddress] += mintValue;

        depositsUsers[currentUser][currentTokenAddress] += l2Value;
        depositsBridge[currentChainAddress][currentTokenAddress] += l2Value;
        tokenSumDeposit[currentTokenAddress] += l2Value;
        l2ValuesSum[currentTokenAddress] += l2Value;
    }

    // deposits ETH to ZK chain where base is ETH
    function depositEthBase(uint256 l2Value) private {
        uint256 gasPrice = 10000000;
        vm.txGasPrice(gasPrice);

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

        vm.recordLogs();
        bytes32 resultantHash = addresses.bridgehub.requestL2TransactionDirect{value: mintValue}(txRequest);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        NewPriorityRequest memory request = _getNewPriorityQueueFromLogs(logs);

        assertNotEq(resultantHash, bytes32(0));
        assertNotEq(request.txHash, bytes32(0));
        _handleRequestByMockL2Contract(request, RequestType.DIRECT);

        depositsUsers[currentUser][ETH_TOKEN_ADDRESS] += mintValue;
        depositsBridge[currentChainAddress][ETH_TOKEN_ADDRESS] += mintValue;
        tokenSumDeposit[ETH_TOKEN_ADDRESS] += mintValue;
        l2ValuesSum[ETH_TOKEN_ADDRESS] += l2Value;
    }

    // deposits base ERC20 token to the bridge
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

        assertNotEq(resultantHash, bytes32(0));
        assertNotEq(request.txHash, bytes32(0));
        _handleRequestByMockL2Contract(request, RequestType.DIRECT);

        depositsUsers[currentUser][currentTokenAddress] += mintValue;
        depositsBridge[currentChainAddress][currentTokenAddress] += mintValue;
        tokenSumDeposit[currentTokenAddress] += mintValue;
        l2ValuesSum[currentTokenAddress] += l2Value;
    }

    /// @notice Finalizes an ERC20 base-token withdrawal from L2 to L1 via the new asset-router API.
    /// @dev The chain's base token is an ERC20 here, so the withdrawal decrements the chain's
    /// `chainBalance` for the base-token assetId and releases escrowed ERC20 to the recipient.
    function withdrawERC20Token(uint256 amountToWithdraw, address tokenAddress) private useGivenToken(tokenAddress) {
        _finalizeBaseTokenWithdrawal(amountToWithdraw, false);
    }

    /// @notice Finalizes an ETH base-token withdrawal from L2 to L1 via the new asset-router API.
    /// @dev Same flow as `withdrawERC20Token` but the base token is native ETH, so ETH balances are
    /// asserted instead of ERC20 balances.
    function withdrawETHToken(uint256 amountToWithdraw, address tokenAddress) private useGivenToken(tokenAddress) {
        _finalizeBaseTokenWithdrawal(amountToWithdraw, true);
    }

    /// @notice Drives a real `L1Nullifier.finalizeDeposit` for the current chain's base-token withdrawal
    /// and asserts the balance outcomes.
    /// @dev Replaces the removed legacy `L1AssetRouter.finalizeWithdrawal` flow. The withdrawal message is
    /// reconstructed in the asset-router `finalizeDeposit` format (see
    /// `L1Nullifier._parseL2WithdrawalMessage`): the base-token assetId plus `encodeBridgeMintData`
    /// transfer data, sent by the L2 base-token system contract (the sender the nullifier validates for a
    /// base-token withdrawal in `_verifyWithdrawal`).
    ///
    /// Mock justification: L2 batch commitments and merkle trees are unavailable in this L1-only
    /// integration environment, so the two message-root proof calls that `_verifyWithdrawal` makes are
    /// mocked:
    ///   - `proveL2MessageInclusionShared` -> `true` (message accepted as included)
    ///   - `getProofData` -> a `ProofData` with `settlementLayerChainId = 0`, i.e. direct-L1 settlement,
    ///     which makes `L1AssetTracker._getWithdrawalChain` attribute the withdrawal to `currentChainId`.
    /// Both are mocked on the selector only (loose match) because the exact `L2Message`/leaf reconstructed
    /// inside the nullifier is an implementation detail we do not want to duplicate here.
    /// @param _amountToWithdraw The base-token amount to withdraw.
    /// @param _isEth Whether the chain's base token is native ETH (vs an ERC20).
    function _finalizeBaseTokenWithdrawal(uint256 _amountToWithdraw, bool _isEth) private {
        // The base-token assetId is exactly what the nullifier compares the message assetId against; using
        // it guarantees the base-token branch (and its `L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR` sender check).
        bytes32 assetId = addresses.bridgehub.baseTokenAssetId(currentChainId);
        IAssetTrackerBase assetTracker = IAssetTrackerBase(address(addresses.l1NativeTokenVault.l1AssetTracker()));

        uint256 beforeChainBalance = assetTracker.chainBalance(currentChainId, assetId);
        uint256 beforeBridgeBalance = _isEth
            ? address(addresses.l1NativeTokenVault).balance
            : currentToken.balanceOf(address(addresses.l1NativeTokenVault));
        uint256 beforeUserBalance = _isEth ? currentUser.balance : currentToken.balanceOf(currentUser);

        FinalizeL1DepositParams memory params = _buildWithdrawalParams(assetId, _amountToWithdraw);
        _mockWithdrawalProof();

        if (beforeChainBalance < _amountToWithdraw) {
            // Not enough escrowed balance for this chain/asset -> the asset tracker reverts.
            vm.expectRevert();
            addresses.l1Nullifier.finalizeDeposit(params);
            return;
        }
        tokenSumWithdrawal[currentTokenAddress] += _amountToWithdraw;

        vm.recordLogs();
        addresses.l1Nullifier.finalizeDeposit(params);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Chain balance for the base-token asset decreased by the withdrawal amount.
        assertEq(
            beforeChainBalance - assetTracker.chainBalance(currentChainId, assetId),
            _amountToWithdraw,
            "Chain balance should decrease by withdrawal amount"
        );

        if (_isEth) {
            // Escrowed ETH left the vault and reached the recipient.
            assertEq(
                beforeBridgeBalance - address(addresses.l1NativeTokenVault).balance,
                _amountToWithdraw,
                "Vault ETH balance should decrease by withdrawal amount"
            );
            assertEq(currentUser.balance - beforeUserBalance, _amountToWithdraw, "User should receive withdrawn ETH");
        } else {
            // Escrowed ERC20 left the vault and reached the recipient.
            assertEq(
                beforeBridgeBalance - currentToken.balanceOf(address(addresses.l1NativeTokenVault)),
                _amountToWithdraw,
                "Vault token balance should decrease by withdrawal amount"
            );
            assertEq(
                currentToken.balanceOf(currentUser) - beforeUserBalance,
                _amountToWithdraw,
                "User should receive withdrawn tokens"
            );
        }

        // Withdrawal marked as finalized (replay protection).
        assertTrue(
            addresses.l1Nullifier.isWithdrawalFinalized(currentChainId, params.l2BatchNumber, params.l2MessageIndex),
            "Withdrawal should be marked as finalized"
        );

        // Verify DepositFinalizedAssetRouter event emission (indexed chainId in topics[1]).
        _assertDepositFinalizedEvent(logs);
    }

    /// @notice Builds the `FinalizeL1DepositParams` for a base-token withdrawal of `_amount` to `currentUser`.
    /// @dev Reconstructs the asset-router `finalizeDeposit` withdrawal message. For a base-token withdrawal
    /// emitted by `L2BaseToken.withdraw`, the original caller and origin token are empty and the metadata is
    /// empty (see `l2-withdrawal-helper.ts::finalizeWithdrawalOnL1`).
    function _buildWithdrawalParams(
        bytes32 _assetId,
        uint256 _amount
    ) private returns (FinalizeL1DepositParams memory params) {
        bytes memory transferData = DataEncoding.encodeBridgeMintData({
            _originalCaller: address(0),
            _remoteReceiver: currentUser,
            _originToken: address(0),
            _amount: _amount,
            _erc20Metadata: hex""
        });
        bytes32[] memory merkleProof = new bytes32[](1);
        params = FinalizeL1DepositParams({
            chainId: currentChainId,
            l2BatchNumber: uint256(uint160(makeAddr("l2BatchNumber"))),
            l2MessageIndex: uint256(uint160(makeAddr("l2MessageIndex"))),
            l2Sender: L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            l2TxNumberInBatch: uint16(uint160(makeAddr("l2TxNumberInBatch"))),
            message: DataEncoding.encodeAssetRouterFinalizeDepositData(currentChainId, _assetId, transferData),
            merkleProof: merkleProof
        });
    }

    /// @notice Asserts a `DepositFinalizedAssetRouter` event was emitted for `currentChainId`.
    /// @dev This file does not use `LogFinder`, so the logs are scanned manually by topic hash.
    function _assertDepositFinalizedEvent(Vm.Log[] memory _logs) private {
        bytes32 depositFinalizedHash = keccak256("DepositFinalizedAssetRouter(uint256,bytes32,bytes)");
        bool foundFinalized = false;
        for (uint256 i = 0; i < _logs.length; ++i) {
            if (_logs[i].topics[0] == depositFinalizedHash) {
                assertEq(uint256(_logs[i].topics[1]), currentChainId, "DepositFinalizedAssetRouter chainId mismatch");
                foundFinalized = true;
                break;
            }
        }
        assertTrue(foundFinalized, "DepositFinalizedAssetRouter event should be emitted");
    }

    /// @notice Mocks the two message-root proof calls made by `L1Nullifier._verifyWithdrawal`.
    /// @dev Mocked on selector only (loose match) so we do not have to reconstruct the exact `L2Message`/leaf.
    /// `getProofData` returns `settlementLayerChainId = 0` (direct L1 settlement) so the withdrawal is
    /// attributed to the source chain by `L1AssetTracker._getWithdrawalChain`.
    function _mockWithdrawalProof() private {
        address messageRoot = address(addresses.l1Nullifier.MESSAGE_ROOT());
        vm.mockCall(
            messageRoot,
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        ProofData memory proofData;
        proofData.settlementLayerChainId = 0;
        vm.mockCall(messageRoot, abi.encodeWithSelector(IMessageRootBase.getProofData.selector), abi.encode(proofData));
    }

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
        _deployZKChain(ETH_TOKEN_ADDRESS);
        _deployZKChain(tokens[0]);
        _deployZKChain(tokens[1]);

        for (uint256 i = 0; i < zkChainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            l2ContractAddresses.push(contractAddress);

            _addL2ChainContract(zkChainIds[i], contractAddress);
        }
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
