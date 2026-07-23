// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
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
import {L1InteropCenter} from "contracts/interop/interop-center/L1InteropCenter.sol";
import {
    AttributeAlreadySet,
    AttributeViolatesRestriction,
    FactoryDepsNotAllowedForIndirectCall,
    L1ToL2TransactionParamsMissing,
    SingleCallBundleRequired
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
import {
    ChainIdNotRegistered,
    MsgValueMismatch,
    Unauthorized,
    WrongMagicValue
} from "contracts/common/L1ContractErrors.sol";
import {BridgehubL2TransactionRequest, InteropCallStarter} from "contracts/common/Messaging.sol";
import {IAssetRouterShared} from "contracts/bridge/asset-router/IAssetRouterShared.sol";

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

    function test_requestL2TransactionIndirect_forwardsAndConfirmsExactRequest() public {
        _useMockSharedBridge();
        _initializeBridgehub();

        address caller = makeAddr("INDIRECT_CALLER");
        L2TransactionRequestIndirect memory request = L2TransactionRequestIndirect({
            chainId: _setUpZKChainForChainId(501),
            mintValue: 1 ether,
            l2Value: 0.25 ether,
            l2GasLimit: 1_000_000,
            l2GasPerPubdataByteLimit: 800,
            refundRecipient: makeAddr("REFUND_RECIPIENT"),
            secondBridgeAddress: secondBridgeAddress,
            secondBridgeValue: 0.1 ether,
            secondBridgeCalldata: abi.encode("deposit data")
        });
        _setUpBaseTokenForChainId(request.chainId, true, address(0));

        IndirectCallRequest memory outputRequest = IndirectCallRequest({
            magicValue: INDIRECT_CALL_MAGIC_VALUE,
            l2Contract: makeAddr("L2_CONTRACT"),
            l2Calldata: abi.encodeCall(SimpleExecutor.execute, (makeAddr("TARGET"), 0, hex"1234")),
            factoryDeps: _singleFactoryDependency(),
            txDataHash: keccak256("TX_DATA")
        });
        bytes32 canonicalHash = keccak256("CANONICAL_TX_HASH");

        // This unit test isolates L1InteropCenter routing from the downstream bridge and mailbox
        // implementations; their exact calls are asserted below, including values and calldata.
        vm.mockCall(
            secondBridgeAddress,
            abi.encodeWithSelector(IL1CrossChainSender.initiateIndirectCall.selector),
            abi.encode(outputRequest)
        );
        vm.mockCall(
            secondBridgeAddress,
            abi.encodeWithSelector(IL1CrossChainSender.confirmL2Transaction.selector),
            hex""
        );
        vm.mockCall(
            address(mockChainContract),
            abi.encodeWithSelector(mockChainContract.bridgehubRequestL2Transaction.selector),
            abi.encode(canonicalHash)
        );

        _expectIndirectCalls(request, caller, outputRequest, canonicalHash);

        (bytes memory recipient, bytes memory payload, bytes[] memory attributes) = L1InteropRequests.encodeIndirect(
            request
        );

        uint256 msgValue = request.mintValue + request.secondBridgeValue;
        vm.deal(caller, msgValue);
        vm.recordLogs();
        vm.prank(caller);
        bytes32 sendId = l1InteropCenter.sendMessage{value: msgValue}(recipient, payload, attributes);

        assertEq(sendId, canonicalHash);
        _assertMessageSent(vm.getRecordedLogs(), request, outputRequest, caller, canonicalHash, attributes);
    }

    function test_sendBundle_indirect_forwardsAndConfirmsExactRequest() public {
        _useMockSharedBridge();
        _initializeBridgehub();

        address caller = makeAddr("INDIRECT_BUNDLE_CALLER");
        L2TransactionRequestIndirect memory request = L2TransactionRequestIndirect({
            chainId: _setUpZKChainForChainId(502),
            mintValue: 1 ether,
            l2Value: 0.25 ether,
            l2GasLimit: 1_000_000,
            l2GasPerPubdataByteLimit: 800,
            refundRecipient: makeAddr("REFUND_RECIPIENT"),
            secondBridgeAddress: secondBridgeAddress,
            secondBridgeValue: 0.1 ether,
            secondBridgeCalldata: abi.encode("deposit data")
        });
        _setUpBaseTokenForChainId(request.chainId, true, address(0));

        IndirectCallRequest memory outputRequest = IndirectCallRequest({
            magicValue: INDIRECT_CALL_MAGIC_VALUE,
            l2Contract: makeAddr("L2_CONTRACT"),
            l2Calldata: abi.encodeCall(SimpleExecutor.execute, (makeAddr("TARGET"), 0, hex"1234")),
            factoryDeps: _singleFactoryDependency(),
            txDataHash: keccak256("TX_DATA")
        });
        bytes32 canonicalHash = keccak256("CANONICAL_TX_HASH");

        vm.mockCall(
            secondBridgeAddress,
            abi.encodeWithSelector(IL1CrossChainSender.initiateIndirectCall.selector),
            abi.encode(outputRequest)
        );
        vm.mockCall(
            secondBridgeAddress,
            abi.encodeWithSelector(IL1CrossChainSender.confirmL2Transaction.selector),
            hex""
        );
        vm.mockCall(
            address(mockChainContract),
            abi.encodeWithSelector(mockChainContract.bridgehubRequestL2Transaction.selector),
            abi.encode(canonicalHash)
        );
        _expectIndirectCalls(request, caller, outputRequest, canonicalHash);

        bytes[] memory callAttributes = new bytes[](2);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (request.l2Value));
        callAttributes[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (request.secondBridgeValue));
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(request.secondBridgeAddress),
            data: request.secondBridgeCalldata,
            callAttributes: callAttributes
        });
        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.l1ToL2TransactionParams,
            (request.mintValue, request.l2GasLimit, request.l2GasPerPubdataByteLimit, request.refundRecipient)
        );

        uint256 msgValue = request.mintValue + request.secondBridgeValue;
        vm.deal(caller, msgValue);
        vm.recordLogs();
        vm.prank(caller);
        bytes32 sendId = l1InteropCenter.sendBundle{value: msgValue}(
            InteroperableAddress.formatEvmV1(request.chainId),
            calls,
            bundleAttributes
        );

        assertEq(sendId, canonicalHash);
        _assertMessageSent(vm.getRecordedLogs(), request, outputRequest, caller, canonicalHash, callAttributes);
    }

    function _singleFactoryDependency() private pure returns (bytes[] memory factoryDeps) {
        factoryDeps = new bytes[](1);
        factoryDeps[0] = hex"010203";
    }

    function _assertMessageSent(
        Vm.Log[] memory _logs,
        L2TransactionRequestIndirect memory _request,
        IndirectCallRequest memory _outputRequest,
        address _caller,
        bytes32 _canonicalHash,
        bytes[] memory _attributes
    ) private view {
        uint256 logsLength = _logs.length;
        for (uint256 i = 0; i < logsLength; ++i) {
            if (
                _logs[i].emitter == address(l1InteropCenter) &&
                _logs[i].topics[0] == IERC7786GatewaySource.MessageSent.selector
            ) {
                assertEq(_logs[i].topics[1], _canonicalHash);
                assertEq(
                    _logs[i].data,
                    abi.encode(
                        InteroperableAddress.formatEvmV1(block.chainid, _caller),
                        InteroperableAddress.formatEvmV1(_request.chainId, _outputRequest.l2Contract),
                        _request.secondBridgeCalldata,
                        _request.l2Value,
                        _attributes
                    )
                );
                return;
            }
        }
        assertTrue(false, "MessageSent event was not emitted");
    }

    function _expectIndirectCalls(
        L2TransactionRequestIndirect memory _request,
        address _caller,
        IndirectCallRequest memory _outputRequest,
        bytes32 _canonicalHash
    ) private {
        vm.expectCall(
            sharedBridgeAddress,
            _request.mintValue,
            abi.encodeCall(
                IAssetRouterShared.bridgehubDepositBaseToken,
                (_request.chainId, ETH_TOKEN_ASSET_ID, _caller, _request.mintValue)
            )
        );
        vm.expectCall(
            secondBridgeAddress,
            _request.secondBridgeValue,
            abi.encodeCall(
                IL1CrossChainSender.initiateIndirectCall,
                (_request.chainId, _caller, _request.l2Value, _request.secondBridgeCalldata)
            )
        );
        vm.expectCall(
            address(mockChainContract),
            abi.encodeWithSelector(
                mockChainContract.bridgehubRequestL2Transaction.selector,
                BridgehubL2TransactionRequest({
                    sender: secondBridgeAddress,
                    contractL2: _outputRequest.l2Contract,
                    mintValue: _request.mintValue,
                    l2Value: _request.l2Value,
                    l2Calldata: _outputRequest.l2Calldata,
                    l2GasLimit: _request.l2GasLimit,
                    l2GasPerPubdataByteLimit: _request.l2GasPerPubdataByteLimit,
                    factoryDeps: _outputRequest.factoryDeps,
                    refundRecipient: _request.refundRecipient
                })
            )
        );
        vm.expectCall(
            secondBridgeAddress,
            abi.encodeCall(
                IL1CrossChainSender.confirmL2Transaction,
                (_request.chainId, _outputRequest.txDataHash, _canonicalHash)
            )
        );
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

    function test_sendBundle_direct_forwardsExactRequestAndEmitsMessageSent() public {
        _useMockSharedBridge();
        _initializeBridgehub();

        address caller = makeAddr("BUNDLE_CALLER");
        bytes[] memory factoryDeps = _singleFactoryDependency();
        (L2TransactionRequestDirect memory request, bytes32 canonicalHash) = _prepareETHL2TransactionDirectRequest({
            mockChainId: 501,
            mockMintValue: 1 ether,
            mockL2Contract: makeAddr("L2_CONTRACT"),
            mockL2Value: 0.25 ether,
            mockL2Calldata: abi.encodeCall(SimpleExecutor.execute, (makeAddr("TARGET"), 0, hex"1234")),
            mockL2GasLimit: 1_000_000,
            mockL2GasPerPubdataByteLimit: 800,
            mockFactoryDeps: factoryDeps,
            randomCaller: caller
        });

        bytes[] memory callAttributes = new bytes[](1);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (request.l2Value));
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(request.l2Contract),
            data: request.l2Calldata,
            callAttributes: callAttributes
        });
        bytes[] memory bundleAttributes = new bytes[](2);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.l1ToL2TransactionParams,
            (request.mintValue, request.l2GasLimit, request.l2GasPerPubdataByteLimit, request.refundRecipient)
        );
        bundleAttributes[1] = abi.encodeCall(IERC7786Attributes.factoryDeps, (request.factoryDeps));

        vm.expectCall(
            sharedBridgeAddress,
            request.mintValue,
            abi.encodeCall(
                IAssetRouterShared.bridgehubDepositBaseToken,
                (request.chainId, ETH_TOKEN_ASSET_ID, caller, request.mintValue)
            )
        );
        vm.expectCall(
            address(mockChainContract),
            abi.encodeWithSelector(
                mockChainContract.bridgehubRequestL2Transaction.selector,
                BridgehubL2TransactionRequest({
                    sender: caller,
                    contractL2: request.l2Contract,
                    mintValue: request.mintValue,
                    l2Value: request.l2Value,
                    l2Calldata: request.l2Calldata,
                    l2GasLimit: request.l2GasLimit,
                    l2GasPerPubdataByteLimit: request.l2GasPerPubdataByteLimit,
                    factoryDeps: request.factoryDeps,
                    refundRecipient: caller
                })
            )
        );
        vm.expectEmit(true, false, false, true, address(l1InteropCenter));
        emit IERC7786GatewaySource.MessageSent({
            sendId: canonicalHash,
            sender: InteroperableAddress.formatEvmV1(block.chainid, caller),
            recipient: InteroperableAddress.formatEvmV1(request.chainId, request.l2Contract),
            payload: request.l2Calldata,
            value: request.l2Value,
            attributes: callAttributes
        });

        vm.deal(caller, request.mintValue);
        vm.prank(caller);
        bytes32 sendId = l1InteropCenter.sendBundle{value: request.mintValue}(
            InteroperableAddress.formatEvmV1(request.chainId),
            calls,
            bundleAttributes
        );

        assertEq(sendId, canonicalHash);
    }

    function test_sendBundle_RevertWhen_callCountIsNotOne() public {
        _useMockSharedBridge();
        _initializeBridgehub();

        InteropCallStarter[] memory calls = new InteropCallStarter[](0);
        vm.expectRevert(abi.encodeWithSelector(SingleCallBundleRequired.selector, 0));
        l1InteropCenter.sendBundle(hex"", calls, new bytes[](0));

        calls = new InteropCallStarter[](2);
        vm.expectRevert(abi.encodeWithSelector(SingleCallBundleRequired.selector, 2));
        l1InteropCenter.sendBundle(hex"", calls, new bytes[](0));
    }

    function test_sendBundle_RevertWhen_callAttributeIsAtBundleLevel() public {
        _useMockSharedBridge();
        _initializeBridgehub();

        InteropCallStarter[] memory calls = _emptyBundleCall();
        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (1));

        vm.expectRevert(
            abi.encodeWithSelector(
                AttributeViolatesRestriction.selector,
                IERC7786Attributes.interopCallValue.selector,
                uint256(L1InteropCenter.L1AttributeParsingRestrictions.OnlyBundleAttributes)
            )
        );
        l1InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(eraChainId), calls, bundleAttributes);
    }

    function test_sendBundle_RevertWhen_bundleAttributeIsAtCallLevel() public {
        _useMockSharedBridge();
        _initializeBridgehub();

        InteropCallStarter[] memory calls = _emptyBundleCall();
        calls[0].callAttributes = new bytes[](1);
        calls[0].callAttributes[0] = abi.encodeCall(IERC7786Attributes.l1ToL2TransactionParams, (0, 0, 0, address(0)));
        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(IERC7786Attributes.l1ToL2TransactionParams, (0, 0, 0, address(0)));

        vm.expectRevert(
            abi.encodeWithSelector(
                AttributeViolatesRestriction.selector,
                IERC7786Attributes.l1ToL2TransactionParams.selector,
                uint256(L1InteropCenter.L1AttributeParsingRestrictions.OnlyCallAttributes)
            )
        );
        l1InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(eraChainId), calls, bundleAttributes);
    }

    function _emptyBundleCall() private pure returns (InteropCallStarter[] memory calls) {
        calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(address(1)),
            data: hex"",
            callAttributes: new bytes[](0)
        });
    }

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

    function test_sendMessage_RevertWhen_chainIsNotRegistered() public {
        _useMockSharedBridge();
        _initializeBridgehub();

        uint256 unregisteredChainId = eraChainId + 1;
        bytes[] memory attributes = new bytes[](1);
        attributes[0] = abi.encodeCall(IERC7786Attributes.l1ToL2TransactionParams, (0, 0, 0, address(0)));

        vm.expectRevert(abi.encodeWithSelector(ChainIdNotRegistered.selector, unregisteredChainId));
        l1InteropCenter.sendMessage(
            InteroperableAddress.formatEvmV1(unregisteredChainId, mockL2Contract),
            hex"",
            attributes
        );
    }

    function test_pause_blocksSendMessageUntilOwnerUnpauses() public {
        _useMockSharedBridge();
        _initializeBridgehub();

        vm.prank(bridgeOwner);
        l1InteropCenter.pause();
        assertTrue(l1InteropCenter.paused());

        vm.expectRevert("Pausable: paused");
        l1InteropCenter.sendMessage(hex"", hex"", new bytes[](0));
        vm.expectRevert("Pausable: paused");
        l1InteropCenter.sendBundle(hex"", new InteropCallStarter[](0), new bytes[](0));

        vm.prank(bridgeOwner);
        l1InteropCenter.unpause();
        assertFalse(l1InteropCenter.paused());
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
