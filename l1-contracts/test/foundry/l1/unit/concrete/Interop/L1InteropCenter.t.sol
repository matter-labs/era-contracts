// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ExperimentalBridgeTestBase} from "../Bridgehub/_ExperimentalBridge_Shared.t.sol";
import {
    L2TransactionRequestDirect,
    IndirectCallRequest,
    L2TransactionRequestIndirect
} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {SimpleExecutor} from "contracts/dev-contracts/SimpleExecutor.sol";
import {IL1CrossChainSender} from "contracts/bridge/interfaces/IL1CrossChainSender.sol";
import {IERC7786GatewaySource} from "contracts/interop/IERC7786GatewaySource.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {L1InteropCenter} from "contracts/interop/L1InteropCenter.sol";
import {
    AttributeAlreadySet,
    FactoryDepsNotAllowedForIndirectCall,
    L1ToL2TransactionParamsMissing
} from "contracts/interop/InteropErrors.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {L1InteropRequests} from "foundry-test/l1/utils/L1InteropRequests.sol";
import {
    MIN_CROSS_CHAIN_SENDER_ADDRESS,
    ETH_TOKEN_ADDRESS,
    MAX_NEW_FACTORY_DEPS,
    INDIRECT_CALL_MAGIC_VALUE
} from "contracts/common/Config.sol";
import {CrossChainSenderAddressTooLow} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {MsgValueMismatch, Unauthorized, WrongMagicValue} from "contracts/common/L1ContractErrors.sol";

contract L1InteropCenterTest is ExperimentalBridgeTestBase {
    function test_requestL2TransactionDirect_RevertWhen_incorrectETHParams(
        uint256 mockChainId,
        uint256 mockMintValue,
        address mockL2Contract,
        uint256 mockL2Value,
        uint256 msgValue,
        bytes memory mockL2Calldata,
        uint256 mockL2GasLimit,
        uint256 mockL2GasPerPubdataByteLimit,
        bytes[] memory mockFactoryDeps
    ) public {
        _useMockSharedBridge();
        _initializeBridgehub();

        address randomCaller = makeAddr("RANDOM_CALLER");
        vm.assume(msgValue != mockMintValue);

        (L2TransactionRequestDirect memory l2TxnReqDirect, bytes32 hash) = _prepareETHL2TransactionDirectRequest({
            mockChainId: mockChainId,
            mockMintValue: mockMintValue,
            mockL2Contract: mockL2Contract,
            mockL2Value: mockL2Value,
            mockL2Calldata: mockL2Calldata,
            mockL2GasLimit: mockL2GasLimit,
            mockL2GasPerPubdataByteLimit: mockL2GasPerPubdataByteLimit,
            mockFactoryDeps: mockFactoryDeps,
            randomCaller: randomCaller
        });

        vm.deal(randomCaller, msgValue);
        vm.expectRevert(abi.encodeWithSelector(MsgValueMismatch.selector, mockMintValue, msgValue));
        vm.prank(randomCaller);
        L1InteropRequests.requestDirect(l1InteropCenter, msgValue, l2TxnReqDirect);
    }

    function test_requestL2TransactionDirect_ETHCase(
        uint256 mockChainId,
        uint256 mockMintValue,
        address mockL2Contract,
        uint256 mockL2Value,
        bytes memory mockL2Calldata,
        uint256 mockL2GasLimit,
        uint256 mockL2GasPerPubdataByteLimit,
        bytes[] memory mockFactoryDeps,
        uint256 gasPrice
    ) public {
        _useMockSharedBridge();
        _initializeBridgehub();

        address randomCaller = makeAddr("RANDOM_CALLER");
        mockChainId = bound(mockChainId, 1, type(uint48).max);
        // Base-token burns require a non-zero amount, so the mint value must be positive for a successful request.
        mockMintValue = bound(mockMintValue, 1, type(uint128).max);

        (L2TransactionRequestDirect memory l2TxnReqDirect, bytes32 hash) = _prepareETHL2TransactionDirectRequest({
            mockChainId: mockChainId,
            mockMintValue: mockMintValue,
            mockL2Contract: mockL2Contract,
            mockL2Value: mockL2Value,
            mockL2Calldata: mockL2Calldata,
            mockL2GasLimit: mockL2GasLimit,
            mockL2GasPerPubdataByteLimit: mockL2GasPerPubdataByteLimit,
            mockFactoryDeps: mockFactoryDeps,
            randomCaller: randomCaller
        });

        vm.deal(randomCaller, l2TxnReqDirect.mintValue);
        gasPrice = bound(gasPrice, 1_000, 50_000_000);
        vm.txGasPrice(gasPrice * 1 gwei);
        uint256 sentValue = randomCaller.balance;
        vm.prank(randomCaller);
        bytes32 resultantHash = L1InteropRequests.requestDirect(l1InteropCenter, sentValue, l2TxnReqDirect);

        assertTrue(resultantHash == hash);
    }

    // This is an example how to test behaviour of 7702. Keeping it, so the logic can be reused in the future
    function test_requestL2TransactionDirect_NonETHCase7702(
        uint256 mockChainId,
        uint256 mockMintValue,
        address mockL2Contract,
        uint256 mockL2Value,
        bytes memory mockL2Calldata,
        uint256 mockL2GasLimit,
        uint256 mockL2GasPerPubdataByteLimit,
        bytes[] memory mockFactoryDeps,
        uint256 gasPrice,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        _useFullSharedBridge();
        _initializeBridgehub();

        uint256 randomCallerPk = uint256(keccak256("RANDOM_CALLER"));
        address payable randomCaller = payable(vm.addr(randomCallerPk));
        mockChainId = bound(mockChainId, 1, type(uint48).max);

        vm.assume(mockFactoryDeps.length <= MAX_NEW_FACTORY_DEPS);
        vm.assume(mockMintValue > 0);

        L2TransactionRequestDirect memory l2TxnReqDirect = _createMockL2TransactionRequestDirect({
            mockChainId: mockChainId,
            mockMintValue: mockMintValue,
            mockL2Contract: mockL2Contract,
            mockL2Value: mockL2Value,
            mockL2Calldata: mockL2Calldata,
            mockL2GasLimit: mockL2GasLimit,
            mockL2GasPerPubdataByteLimit: mockL2GasPerPubdataByteLimit,
            mockFactoryDeps: mockFactoryDeps,
            mockRefundRecipient: randomCaller
        });

        l2TxnReqDirect.chainId = _setUpZKChainForChainId(l2TxnReqDirect.chainId);

        _setUpBaseTokenForChainId(l2TxnReqDirect.chainId, false, address(testToken));

        assertTrue(bridgehub.getZKChain(l2TxnReqDirect.chainId) == address(mockChainContract));
        bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));

        vm.mockCall(
            address(mockChainContract),
            abi.encodeWithSelector(mockChainContract.bridgehubRequestL2Transaction.selector),
            abi.encode(canonicalHash)
        );

        mockChainContract.setFeeParams();
        mockChainContract.setBaseTokenGasMultiplierPrice(uint128(1), uint128(1));
        mockChainContract.setBridgeHubAddress(address(bridgehub));
        assertTrue(mockChainContract.getBridgeHubAddress() == address(bridgehub));

        gasPrice = bound(gasPrice, 1_000, 50_000_000);
        vm.txGasPrice(gasPrice * 1 gwei);

        vm.deal(randomCaller, 1 ether);

        // Now, let's call the same function with zero msg.value
        testToken.mint(randomCaller, l2TxnReqDirect.mintValue);
        assertEq(testToken.balanceOf(randomCaller), l2TxnReqDirect.mintValue);

        bytes memory calldataForExecutor;
        {
            (bytes memory recipient, bytes memory payload, bytes[] memory attributes) = L1InteropRequests.encodeDirect(
                l2TxnReqDirect
            );
            calldataForExecutor = abi.encodeCall(IERC7786GatewaySource.sendMessage, (recipient, payload, attributes));
        }

        vm.recordLogs(); // start recording all logs

        vm.prank(randomCaller);
        testToken.approve(sharedBridgeAddress, l2TxnReqDirect.mintValue);
        assertEq(testToken.allowance(randomCaller, sharedBridgeAddress), l2TxnReqDirect.mintValue);
        vm.signAndAttachDelegation(address(simpleExecutor), randomCallerPk);
        SimpleExecutor(randomCaller).execute(address(l1InteropCenter), 0, calldataForExecutor);
    }

    function test_requestTransactionIndirectChecksMagicValue(
        uint256 chainId,
        uint256 mintValue,
        uint256 l2Value,
        uint256 l2GasLimit,
        uint256 l2GasPerPubdataByteLimit,
        address refundRecipient,
        uint256 secondBridgeValue,
        bytes memory secondBridgeCalldata,
        bytes32 magicValue
    ) public {
        _useMockSharedBridge();
        _initializeBridgehub();

        vm.assume(magicValue != INDIRECT_CALL_MAGIC_VALUE);

        chainId = bound(chainId, 1, type(uint48).max);
        // Base-token burns require a non-zero amount; bound the mint value so the flow reaches the magic-value check.
        mintValue = bound(mintValue, 1, type(uint128).max);

        L2TransactionRequestIndirect memory l2TxnReq2BridgeOut = _createMockL2TransactionRequestIndirectOuter({
            chainId: chainId,
            mintValue: mintValue,
            l2Value: l2Value,
            l2GasLimit: l2GasLimit,
            l2GasPerPubdataByteLimit: l2GasPerPubdataByteLimit,
            refundRecipient: refundRecipient,
            secondBridgeValue: secondBridgeValue,
            secondBridgeCalldata: secondBridgeCalldata
        });

        l2TxnReq2BridgeOut.chainId = _setUpZKChainForChainId(l2TxnReq2BridgeOut.chainId);

        _setUpBaseTokenForChainId(l2TxnReq2BridgeOut.chainId, true, address(0));
        assertTrue(bridgehub.baseToken(l2TxnReq2BridgeOut.chainId) == ETH_TOKEN_ADDRESS);

        assertTrue(bridgehub.getZKChain(l2TxnReq2BridgeOut.chainId) == address(mockChainContract));

        uint256 callerMsgValue = l2TxnReq2BridgeOut.mintValue + l2TxnReq2BridgeOut.secondBridgeValue;
        address randomCaller = makeAddr("RANDOM_CALLER");
        vm.deal(randomCaller, callerMsgValue);

        IndirectCallRequest memory request = IndirectCallRequest({
            magicValue: magicValue,
            l2Contract: makeAddr("L2_CONTRACT"),
            l2Calldata: new bytes(0),
            factoryDeps: new bytes[](0),
            txDataHash: bytes32(0)
        });

        vm.mockCall(
            secondBridgeAddress,
            abi.encodeWithSelector(IL1CrossChainSender.initiateIndirectCall.selector),
            abi.encode(request)
        );

        uint256 sentValue = randomCaller.balance;
        vm.expectRevert(abi.encodeWithSelector(WrongMagicValue.selector, INDIRECT_CALL_MAGIC_VALUE, magicValue));
        vm.prank(randomCaller);
        L1InteropRequests.requestIndirect(l1InteropCenter, sentValue, l2TxnReq2BridgeOut);
    }

    function test_requestL2TransactionIndirectWrongBridgeAddress(
        uint256 chainId,
        uint256 mintValue,
        uint256 msgValue,
        uint256 l2Value,
        uint256 l2GasLimit,
        uint256 l2GasPerPubdataByteLimit,
        address refundRecipient,
        uint256 secondBridgeValue,
        uint160 secondBridgeAddressValue,
        bytes memory secondBridgeCalldata
    ) public {
        _useMockSharedBridge();
        _initializeBridgehub();

        chainId = bound(chainId, 1, type(uint48).max);

        L2TransactionRequestIndirect memory l2TxnReq2BridgeOut = _createMockL2TransactionRequestIndirectOuter({
            chainId: chainId,
            mintValue: mintValue,
            l2Value: l2Value,
            l2GasLimit: l2GasLimit,
            l2GasPerPubdataByteLimit: l2GasPerPubdataByteLimit,
            refundRecipient: refundRecipient,
            secondBridgeValue: secondBridgeValue,
            secondBridgeCalldata: secondBridgeCalldata
        });

        l2TxnReq2BridgeOut.chainId = _setUpZKChainForChainId(l2TxnReq2BridgeOut.chainId);

        _setUpBaseTokenForChainId(l2TxnReq2BridgeOut.chainId, true, address(0));
        assertTrue(bridgehub.baseToken(l2TxnReq2BridgeOut.chainId) == ETH_TOKEN_ADDRESS);

        assertTrue(bridgehub.getZKChain(l2TxnReq2BridgeOut.chainId) == address(mockChainContract));

        uint256 callerMsgValue = l2TxnReq2BridgeOut.mintValue + l2TxnReq2BridgeOut.secondBridgeValue;
        address randomCaller = makeAddr("RANDOM_CALLER");
        vm.deal(randomCaller, callerMsgValue);

        mockChainContract.setBridgeHubAddress(address(bridgehub));

        bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));

        vm.mockCall(
            address(mockChainContract),
            abi.encodeWithSelector(mockChainContract.bridgehubRequestL2Transaction.selector),
            abi.encode(canonicalHash)
        );

        IndirectCallRequest memory outputRequest = IndirectCallRequest({
            magicValue: INDIRECT_CALL_MAGIC_VALUE,
            l2Contract: address(0),
            l2Calldata: abi.encode(""),
            factoryDeps: new bytes[](0),
            txDataHash: bytes32("")
        });
        secondBridgeAddressValue = uint160(bound(uint256(secondBridgeAddressValue), 0, uint256(type(uint16).max)));
        address secondBridgeAddress = address(secondBridgeAddressValue);

        vm.mockCall(
            address(secondBridgeAddressValue),
            l2TxnReq2BridgeOut.secondBridgeValue,
            abi.encodeWithSelector(
                IL1CrossChainSender.initiateIndirectCall.selector,
                l2TxnReq2BridgeOut.chainId,
                randomCaller,
                l2TxnReq2BridgeOut.l2Value,
                l2TxnReq2BridgeOut.secondBridgeCalldata
            ),
            abi.encode(outputRequest)
        );

        l2TxnReq2BridgeOut.secondBridgeAddress = address(secondBridgeAddressValue);
        uint256 sentValue = randomCaller.balance;
        vm.expectRevert(
            abi.encodeWithSelector(
                CrossChainSenderAddressTooLow.selector,
                secondBridgeAddress,
                MIN_CROSS_CHAIN_SENDER_ADDRESS
            )
        );
        vm.prank(randomCaller);
        L1InteropRequests.requestIndirect(l1InteropCenter, sentValue, l2TxnReq2BridgeOut);
    }

    /////////////////////////////////////////////////////////
    // L1InteropCenter entry point
    /////////////////////////////////////////////////////////

    function test_bridgehubDepositBaseToken_RevertWhen_notInteropCenter(address randomCaller) public {
        _useFullSharedBridge();
        _initializeBridgehub();
        vm.assume(randomCaller != address(l1InteropCenter));

        // The asset router authorizes the L1InteropCenter dynamically through the Bridgehub.
        // A non-Era chain id is used so that the Era-diamond-proxy legacy path can not be hit by the fuzzer.
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomCaller));
        vm.prank(randomCaller);
        sharedBridge.bridgehubDepositBaseToken(eraChainId + 1, ETH_TOKEN_ASSET_ID, randomCaller, 1 ether);
    }

    function test_initiateIndirectCall_RevertWhen_notInteropCenter(address randomCaller) public {
        _useFullSharedBridge();
        _initializeBridgehub();
        vm.assume(randomCaller != address(l1InteropCenter));

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomCaller));
        vm.prank(randomCaller);
        IL1CrossChainSender(address(sharedBridge)).initiateIndirectCall(eraChainId, randomCaller, 0, hex"");
    }

    function test_sendMessage_RevertWhen_l1ToL2TransactionParamsMissing(uint256 mockL2Value) public {
        _useMockSharedBridge();
        _initializeBridgehub();

        bytes[] memory attributes = new bytes[](1);
        attributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (mockL2Value));

        vm.expectRevert(L1ToL2TransactionParamsMissing.selector);
        l1InteropCenter.sendMessage(InteroperableAddress.formatEvmV1(eraChainId, mockL2Contract), hex"", attributes);
    }

    function test_sendMessage_RevertWhen_factoryDepsForIndirectCall() public {
        _useMockSharedBridge();
        _initializeBridgehub();

        bytes[] memory attributes = new bytes[](3);
        attributes[0] = abi.encodeCall(IERC7786Attributes.l1ToL2TransactionParams, (0, 0, 0, address(0)));
        attributes[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (uint256(0)));
        attributes[2] = abi.encodeCall(IERC7786Attributes.factoryDeps, (new bytes[](1)));

        vm.expectRevert(FactoryDepsNotAllowedForIndirectCall.selector);
        l1InteropCenter.sendMessage(
            InteroperableAddress.formatEvmV1(eraChainId, secondBridgeAddress),
            hex"",
            attributes
        );
    }

    function test_sendMessage_RevertWhen_unsupportedAttribute() public {
        _useMockSharedBridge();
        _initializeBridgehub();

        // `useFixedFee` is an L2-only attribute and must be rejected by the L1InteropCenter.
        bytes[] memory attributes = new bytes[](2);
        attributes[0] = abi.encodeCall(IERC7786Attributes.l1ToL2TransactionParams, (0, 0, 0, address(0)));
        attributes[1] = abi.encodeCall(IERC7786Attributes.useFixedFee, (true));

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC7786GatewaySource.UnsupportedAttribute.selector,
                IERC7786Attributes.useFixedFee.selector
            )
        );
        l1InteropCenter.sendMessage(InteroperableAddress.formatEvmV1(eraChainId, mockL2Contract), hex"", attributes);
    }

    function test_sendMessage_RevertWhen_duplicateAttribute() public {
        _useMockSharedBridge();
        _initializeBridgehub();

        bytes[] memory attributes = new bytes[](2);
        attributes[0] = abi.encodeCall(IERC7786Attributes.l1ToL2TransactionParams, (0, 0, 0, address(0)));
        attributes[1] = abi.encodeCall(IERC7786Attributes.l1ToL2TransactionParams, (0, 0, 0, address(0)));

        vm.expectRevert(
            abi.encodeWithSelector(AttributeAlreadySet.selector, IERC7786Attributes.l1ToL2TransactionParams.selector)
        );
        l1InteropCenter.sendMessage(InteroperableAddress.formatEvmV1(eraChainId, mockL2Contract), hex"", attributes);
    }

    function test_sendMessage_direct_emitsMessageSent(
        uint256 mockChainId,
        uint256 mockMintValue,
        address mockL2Contract,
        uint256 mockL2Value,
        bytes memory mockL2Calldata,
        uint256 mockL2GasLimit,
        uint256 mockL2GasPerPubdataByteLimit,
        bytes[] memory mockFactoryDeps
    ) public {
        _useMockSharedBridge();
        _initializeBridgehub();

        address randomCaller = makeAddr("RANDOM_CALLER");
        mockChainId = bound(mockChainId, 1, type(uint48).max);
        // Base-token burns require a non-zero amount, so the mint value must be positive for a successful request.
        mockMintValue = bound(mockMintValue, 1, type(uint128).max);

        (L2TransactionRequestDirect memory l2TxnReqDirect, bytes32 hash) = _prepareETHL2TransactionDirectRequest({
            mockChainId: mockChainId,
            mockMintValue: mockMintValue,
            mockL2Contract: mockL2Contract,
            mockL2Value: mockL2Value,
            mockL2Calldata: mockL2Calldata,
            mockL2GasLimit: mockL2GasLimit,
            mockL2GasPerPubdataByteLimit: mockL2GasPerPubdataByteLimit,
            mockFactoryDeps: mockFactoryDeps,
            randomCaller: randomCaller
        });

        (bytes memory recipient, bytes memory payload, bytes[] memory attributes) = L1InteropRequests.encodeDirect(
            l2TxnReqDirect
        );

        vm.deal(randomCaller, l2TxnReqDirect.mintValue);
        vm.expectEmit(true, false, false, true, address(l1InteropCenter));
        emit IERC7786GatewaySource.MessageSent({
            sendId: hash,
            sender: InteroperableAddress.formatEvmV1(block.chainid, randomCaller),
            recipient: InteroperableAddress.formatEvmV1(l2TxnReqDirect.chainId, l2TxnReqDirect.l2Contract),
            payload: l2TxnReqDirect.l2Calldata,
            value: l2TxnReqDirect.l2Value,
            attributes: attributes
        });
        vm.prank(randomCaller);
        bytes32 sendId = l1InteropCenter.sendMessage{value: l2TxnReqDirect.mintValue}(recipient, payload, attributes);

        // The sendId of an L1->L2 message is the canonical hash of the priority transaction that delivers it.
        assertEq(sendId, hash);
    }

    function test_supportsAttribute() public {
        _useMockSharedBridge();
        _initializeBridgehub();

        assertTrue(l1InteropCenter.supportsAttribute(IERC7786Attributes.interopCallValue.selector));
        assertTrue(l1InteropCenter.supportsAttribute(IERC7786Attributes.indirectCall.selector));
        assertTrue(l1InteropCenter.supportsAttribute(IERC7786Attributes.l1ToL2TransactionParams.selector));
        assertTrue(l1InteropCenter.supportsAttribute(IERC7786Attributes.factoryDeps.selector));

        assertFalse(l1InteropCenter.supportsAttribute(IERC7786Attributes.executionAddress.selector));
        assertFalse(l1InteropCenter.supportsAttribute(IERC7786Attributes.unbundlerAddress.selector));
        assertFalse(l1InteropCenter.supportsAttribute(IERC7786Attributes.useFixedFee.selector));
    }

    function test_l2TransactionBaseCost_passthrough(uint256 chainId) public {
        _useMockSharedBridge();
        _initializeBridgehub();

        chainId = bound(chainId, 1, type(uint48).max);
        chainId = _setUpZKChainForChainId(chainId);
        _setUpBaseTokenForChainId(chainId, true, address(0));

        uint256 expectedBaseCost = 12345;
        vm.mockCall(
            address(mockChainContract),
            abi.encodeWithSelector(mockChainContract.l2TransactionBaseCost.selector),
            abi.encode(expectedBaseCost)
        );

        // The estimation is forwarded to the destination chain's Mailbox through the interop center.
        assertEq(l1InteropCenter.l2TransactionBaseCost(chainId, 1 gwei, 1_000_000, 800), expectedBaseCost);
    }
}
