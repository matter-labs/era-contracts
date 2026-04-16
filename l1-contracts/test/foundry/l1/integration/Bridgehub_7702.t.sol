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

import {SimpleExecutor} from "contracts/dev-contracts/SimpleExecutor.sol";

import {
    DEFAULT_L2_LOGS_TREE_ROOT_HASH,
    EMPTY_STRING_KECCAK,
    ETH_TOKEN_ADDRESS,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA
} from "contracts/common/Config.sol";

import {BridgehubInvariantTests} from "test/foundry/l1/integration/BridgehubTests.t.sol";

import {LogFinder} from "test-utils/LogFinder.sol";

contract Bridgehub_7702 is BridgehubInvariantTests {
    using LogFinder for Vm.Log[];

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
        currentChainId = 10;
        currentChainAddress = getZKChainAddress(currentChainId);
        uint256 gasPrice = 10000000;
        vm.txGasPrice(gasPrice);

        simpleExecutor = new SimpleExecutor();

        uint256 l2GasLimit = 1000000;
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

        // --- ETH balance assertions ---
        // Caller was dealt exactly mintValue; all of it should be consumed
        assertEq(randomCaller.balance, 0, "Caller ETH balance should be fully consumed");

        // --- Decode and validate NewPriorityRequest ---
        NewPriorityRequest memory request = _getNewPriorityQueueFromLogs(logs);
        assertNotEq(request.txHash, bytes32(0), "Transaction hash should not be zero");

        // 7702-specific: sender must NOT be aliased — the EIP-7702 delegation means
        // the EOA itself is the msg.sender, so no L1-to-L2 alias should be applied.
        assertEq(address(uint160(request.transaction.from)), randomCaller, "7702: sender should not be aliased");

        // L2 target should be the actual chain contract, not just non-zero
        assertEq(
            address(uint160(request.transaction.to)),
            chainContracts[currentChainId],
            "L2 contract should match the chain's registered contract"
        );

        assertEq(request.transaction.value, l2Value, "Transaction value should match l2Value");
        assertEq(request.transaction.reserved[0], mintValue, "Mint value should match");

        // --- Event: BridgehubDepositBaseTokenInitiated ---
        Vm.Log memory depositLog = logs.requireOne(
            "BridgehubDepositBaseTokenInitiated(uint256,address,bytes32,uint256)"
        );
        assertEq(uint256(depositLog.topics[1]), currentChainId, "Deposit base token event chainId mismatch");

        // --- Simulate L2 side ---
        _handleRequestByMockL2Contract(request, RequestType.DIRECT);

        // Update tracking variables for invariant harness
        depositsUsers[currentUser][ETH_TOKEN_ADDRESS] += mintValue;
        depositsBridge[currentChainAddress][ETH_TOKEN_ADDRESS] += mintValue;
        tokenSumDeposit[ETH_TOKEN_ADDRESS] += mintValue;
        l2ValuesSum[ETH_TOKEN_ADDRESS] += l2Value;
    }

    //@check does it make sense to add here the rest of unhappy and edge scenarios instead of in unit testing>
    // Unhappy path tests:                                                                                                                                                                                                                                                                                                                                     
    // - Caller is dealt less ETH than mintValue (mintValue - 1).                                                                                                                                                                                                                                                                                                     
    // - Caller has ETH but mintValue is set to 1 — far below the L2 base cost.                                                                                                                                                                                                                                        
    // Edge case tests
    // - l2Value is 0, mintValue covers only gas. The 7702 delegation mechanics should still                                                                                            
    //    work: sender should not be aliased, ETH fully consumed, transaction queued.                                                                                                                                                 
    // - A regular contract (no signAndAttachDelegation) calls the bridgehub,
    //    the sender in the L2 canonical transaction should be aliased because it !is7702AccountSender                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   

    function depositEthSuccess(uint256 userIndexSeed, uint256 chainIndexSeed, uint256 l2Value) public {
        uint64 MAX = 2 ** 64 - 1;
        l2Value = bound(l2Value, 0.1 ether, MAX);

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
        l2Value = bound(l2Value, 0.1 ether, MAX);

        emit log_string("DEPOSIT ERC20");
        super.depositERC20ToBridgeSuccess(userIndexSeed, chainIndexSeed, tokenIndexSeed, l2Value);
    }

    function withdrawERC20Success(uint256 userIndexSeed, uint256 chainIndexSeed, uint256 amountToWithdraw) public {
        uint64 MAX = (2 ** 32 - 1) + 0.1 ether;
        amountToWithdraw = bound(amountToWithdraw, 0.1 ether, MAX);

        emit log_string("WITHDRAW ERC20");
        super.withdrawSuccess(userIndexSeed, chainIndexSeed, amountToWithdraw);
    }

    // add this to be excluded from coverage report
    function testBoundedBridgehubInvariant() internal {}
}
