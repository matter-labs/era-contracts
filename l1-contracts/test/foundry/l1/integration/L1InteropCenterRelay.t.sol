// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";

import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";

import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {L2TransactionRequestTwoBridgesInner} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1CrossChainSender} from "contracts/bridge/interfaces/IL1CrossChainSender.sol";
import {L1InteropCenter} from "contracts/interop/L1InteropCenter.sol";
import {IL1InteropCenter, L1MessageAttributes} from "contracts/interop/IL1InteropCenter.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {IERC7786GatewaySource} from "contracts/interop/IERC7786GatewaySource.sol";
import {
    AttributeAlreadySet,
    FactoryDepsNotAllowedForIndirectCall,
    L1ToL2TransactionParamsMissing
} from "contracts/interop/InteropErrors.sol";

import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {
    ETH_TOKEN_ADDRESS,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    TWO_BRIDGES_MAGIC_VALUE
} from "contracts/common/Config.sol";
import {ChainIdNotRegistered, MsgValueMismatch, Unauthorized, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {L2TransactionRequestDirect} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

import {LogFinder} from "test-utils/LogFinder.sol";
import {NEW_PRIORITY_REQUEST_SIGNATURE} from "test/foundry/TestConstants.sol";

/// @notice Minimal cross-chain sender that records what the Bridgehub passes to it.
/// @dev Deliberately not the asset router: it lets the indirect relay be exercised while asserting the
/// caller-identity limitation documented in {protocol-docs/l1-interop-center.md#indirect-calls}.
contract RecordingCrossChainSender is IL1CrossChainSender {
    address public lastOriginalCaller;
    uint256 public lastValue;
    uint256 public lastMsgValue;
    address public immutable L2_CONTRACT;

    constructor(address _l2Contract) {
        L2_CONTRACT = _l2Contract;
    }

    function initiateIndirectCall(
        uint256,
        address _originalCaller,
        uint256 _value,
        bytes calldata _data
    ) external payable returns (L2TransactionRequestTwoBridgesInner memory request) {
        lastOriginalCaller = _originalCaller;
        lastValue = _value;
        lastMsgValue = msg.value;

        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: L2_CONTRACT,
            l2Calldata: _data,
            factoryDeps: new bytes[](0),
            txDataHash: bytes32(0)
        });
    }

    function bridgehubDeposit(
        uint256 _chainId,
        address _originalCaller,
        uint256 _value,
        bytes calldata _data
    ) external payable returns (L2TransactionRequestTwoBridgesInner memory request) {
        return this.initiateIndirectCall{value: msg.value}(_chainId, _originalCaller, _value, _data);
    }

    function bridgehubConfirmL2Transaction(uint256, bytes32, bytes32) external {}
}

/// @title L1InteropCenterRelayTest
/// @notice Covers the ERC-7786 entry point that relays L1->L2 requests to the Bridgehub.
/// @dev Runs against the real deployment (Bridgehub, asset router, native token vault and two chains:
/// one with ETH and one with an ERC20 base token) so that the relayed request is produced by the same
/// code path as a direct Bridgehub call. See {protocol-docs/l1-interop-center.md}.
contract L1InteropCenterRelayTest is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    using LogFinder for Vm.Log[];

    struct NewPriorityRequest {
        uint256 txId;
        bytes32 txHash;
        uint64 expirationTimestamp;
        L2CanonicalTransaction transaction;
        bytes[] factoryDeps;
    }

    uint256 internal constant L2_GAS_LIMIT = 1_000_000;
    uint256 internal constant GAS_PRICE = 10_000_000;

    L1InteropCenter internal interopCenter;
    address internal user;

    /// @dev The chain whose base token is ETH.
    uint256 internal ethChainId;
    /// @dev The chain whose base token is an ERC20.
    uint256 internal erc20ChainId;
    TestnetERC20Token internal baseToken;

    function setUp() public {
        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);

        _deployEra();
        ethChainId = eraZKChainId;

        baseToken = TestnetERC20Token(_erc20Token());
        _deployZKChain(address(baseToken));
        erc20ChainId = zkChainIds[zkChainIds.length - 1];

        for (uint256 i = 0; i < zkChainIds.length; ++i) {
            _addL2ChainContract(zkChainIds[i], makeAddr(string(abi.encode("l2Contract", i))));
        }

        interopCenter = new L1InteropCenter(IL1Bridgehub(address(addresses.bridgehub)));
        vm.prank(addresses.bridgehubOwnerAddress);
        IL1Bridgehub(address(addresses.bridgehub)).setInteropCenter(address(interopCenter));

        user = makeAddr("USER");

        vm.txGasPrice(GAS_PRICE);
    }

    /*//////////////////////////////////////////////////////////////
                            Direct calls
    //////////////////////////////////////////////////////////////*/

    function test_sendMessage_directCall_ethBaseToken() public {
        uint256 l2Value = 1 ether;
        uint256 mintValue = l2Value + _baseCost(ethChainId);
        address l2Contract = chainContracts[ethChainId];
        bytes memory payload = abi.encode("PAYLOAD");

        vm.deal(user, mintValue);

        bytes[] memory attributes = _attributes({
            _mintValue: mintValue,
            _refundRecipient: address(0),
            _interopCallValue: l2Value,
            _indirect: false,
            _indirectCallMessageValue: 0
        });

        vm.recordLogs();
        vm.prank(user, user);
        bytes32 sendId = interopCenter.sendMessage{value: mintValue}(
            InteroperableAddress.formatEvmV1(ethChainId, l2Contract),
            payload,
            attributes
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        NewPriorityRequest memory request = _getNewPriorityRequest(logs);

        // The returned sendId is the canonical hash of the priority transaction that delivers the message.
        assertEq(sendId, request.txHash, "sendId should be the canonical tx hash");
        assertEq(address(uint160(request.transaction.to)), l2Contract, "L2 contract mismatch");
        assertEq(request.transaction.value, l2Value, "L2 value mismatch");
        assertEq(request.transaction.reserved[0], mintValue, "mintValue mismatch");
        assertEq(request.transaction.gasLimit, L2_GAS_LIMIT, "gas limit mismatch");
        assertEq(request.transaction.data, payload, "payload mismatch");
        assertEq(user.balance, 0, "the whole msg.value should be forwarded");
        assertEq(address(interopCenter).balance, 0, "no ETH should be left in the interop center");

        // The Bridgehub is told which account the request is made for, so the message arrives from the
        // message sender and not from the relay. See {protocol-docs/l1-interop-center.md#trusted-forwarding}.
        assertEq(address(uint160(request.transaction.from)), user, "sender should be the message sender");

        // An omitted refundRecipient defaults to the message sender, as for a direct Bridgehub call.
        assertEq(
            address(uint160(request.transaction.reserved[1])),
            user,
            "refund recipient should default to the message sender"
        );

        Vm.Log memory messageSent = logs.requireOne("MessageSent(bytes32,bytes,bytes,bytes,uint256,bytes[])");
        assertEq(messageSent.topics[1], sendId, "MessageSent should be indexed by sendId");
        (bytes memory sender, , bytes memory eventPayload, uint256 value, ) = abi.decode(
            messageSent.data,
            (bytes, bytes, bytes, uint256, bytes[])
        );
        assertEq(sender, InteroperableAddress.formatEvmV1(block.chainid, user), "event sender mismatch");
        assertEq(eventPayload, payload, "event payload mismatch");
        assertEq(value, l2Value, "event value mismatch");
    }

    function test_sendMessage_directCall_producesTheSameRequestAsTheBridgehub() public {
        uint256 l2Value = 1 ether;
        uint256 mintValue = l2Value + _baseCost(ethChainId);
        bytes memory payload = abi.encode("PAYLOAD");

        L2TransactionRequestDirect memory request = _createL2TransactionRequestDirect({
            _chainId: ethChainId,
            _mintValue: mintValue,
            _l2Value: l2Value,
            _l2GasLimit: L2_GAS_LIMIT,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _l2CallData: payload
        });
        // The mocker fills in a refund recipient; the message carries the same one as an attribute.
        vm.deal(user, mintValue);

        uint256 snapshot = vm.snapshotState();
        vm.prank(user, user);
        bytes32 directHash = IL1Bridgehub(address(addresses.bridgehub)).requestL2TransactionDirect{value: mintValue}(
            request
        );
        vm.revertToState(snapshot);

        // The mocked request carries factory dependencies, so the message carries them as an attribute.
        bytes[] memory attributes = new bytes[](3);
        attributes[0] = abi.encodeCall(
            IERC7786Attributes.l1ToL2TransactionParams,
            (mintValue, L2_GAS_LIMIT, REQUIRED_L2_GAS_PRICE_PER_PUBDATA, request.refundRecipient)
        );
        attributes[1] = abi.encodeCall(IERC7786Attributes.interopCallValue, (l2Value));
        attributes[2] = abi.encodeCall(IERC7786Attributes.factoryDeps, (request.factoryDeps));

        vm.prank(user, user);
        bytes32 relayedHash = interopCenter.sendMessage{value: mintValue}(
            InteroperableAddress.formatEvmV1(ethChainId, request.l2Contract),
            payload,
            attributes
        );

        // Equal canonical hashes mean every field of the priority transaction matched, the sender and the
        // refund recipient included. See {protocol-docs/l1-interop-center.md#trusted-forwarding}.
        assertEq(relayedHash, directHash, "the relayed request should hash like the direct one");
    }

    function test_sendMessage_directCall_erc20BaseToken() public {
        uint256 mintValue = _baseCost(erc20ChainId);
        address l2Contract = chainContracts[erc20ChainId];

        baseToken.mint(user, mintValue);
        vm.prank(user);
        baseToken.approve(address(addresses.sharedBridge), mintValue);

        bytes[] memory attributes = _attributes({
            _mintValue: mintValue,
            _refundRecipient: address(0),
            _interopCallValue: 0,
            _indirect: false,
            _indirectCallMessageValue: 0
        });

        vm.recordLogs();
        vm.prank(user);
        bytes32 sendId = interopCenter.sendMessage(
            InteroperableAddress.formatEvmV1(erc20ChainId, l2Contract),
            abi.encode("PAYLOAD"),
            attributes
        );

        NewPriorityRequest memory request = _getNewPriorityRequest(vm.getRecordedLogs());
        assertEq(sendId, request.txHash, "sendId should be the canonical tx hash");
        assertEq(request.transaction.reserved[0], mintValue, "mintValue mismatch");

        // The base token is taken from the caller's own allowance, so the relay never holds it.
        assertEq(baseToken.balanceOf(user), 0, "the base token should be taken from the caller");
        assertEq(baseToken.balanceOf(address(interopCenter)), 0, "no base token should be held by the relay");
    }

    function test_sendMessage_directCall_explicitRefundRecipientIsPreserved() public {
        address refundRecipient = makeAddr("REFUND_RECIPIENT");
        uint256 mintValue = _baseCost(ethChainId);
        vm.deal(user, mintValue);

        vm.recordLogs();
        vm.prank(user);
        interopCenter.sendMessage{value: mintValue}(
            InteroperableAddress.formatEvmV1(ethChainId, chainContracts[ethChainId]),
            abi.encode("PAYLOAD"),
            _attributes({
                _mintValue: mintValue,
                _refundRecipient: refundRecipient,
                _interopCallValue: 0,
                _indirect: false,
                _indirectCallMessageValue: 0
            })
        );

        NewPriorityRequest memory request = _getNewPriorityRequest(vm.getRecordedLogs());
        assertEq(address(uint160(request.transaction.reserved[1])), refundRecipient, "refund recipient mismatch");
    }

    function test_sendMessage_directCall_RevertWhen_msgValueDoesNotCoverMintValue() public {
        uint256 mintValue = _baseCost(ethChainId);
        vm.deal(user, mintValue);

        // The Bridgehub still performs the base-token value accounting for the relayed request.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(MsgValueMismatch.selector, mintValue, mintValue - 1));
        interopCenter.sendMessage{value: mintValue - 1}(
            InteroperableAddress.formatEvmV1(ethChainId, chainContracts[ethChainId]),
            abi.encode("PAYLOAD"),
            _attributes({
                _mintValue: mintValue,
                _refundRecipient: address(0),
                _interopCallValue: 0,
                _indirect: false,
                _indirectCallMessageValue: 0
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                            Indirect calls
    //////////////////////////////////////////////////////////////*/

    function test_sendMessage_indirectCall_relaysThroughCrossChainSender() public {
        address l2Contract = chainContracts[ethChainId];
        RecordingCrossChainSender crossChainSender = new RecordingCrossChainSender(l2Contract);

        uint256 crossChainSenderValue = 0.5 ether;
        uint256 mintValue = _baseCost(ethChainId);
        vm.deal(user, mintValue + crossChainSenderValue);

        bytes memory payload = abi.encode("SENDER_PAYLOAD");

        vm.recordLogs();
        vm.prank(user);
        bytes32 sendId = interopCenter.sendMessage{value: mintValue + crossChainSenderValue}(
            InteroperableAddress.formatEvmV1(ethChainId, address(crossChainSender)),
            payload,
            _attributes({
                _mintValue: mintValue,
                _refundRecipient: address(0),
                _interopCallValue: 0,
                _indirect: true,
                _indirectCallMessageValue: crossChainSenderValue
            })
        );

        NewPriorityRequest memory request = _getNewPriorityRequest(vm.getRecordedLogs());
        assertEq(sendId, request.txHash, "sendId should be the canonical tx hash");
        // The destination-side call is the one the cross-chain sender returned, not the message payload.
        assertEq(address(uint160(request.transaction.to)), l2Contract, "L2 contract mismatch");
        assertEq(crossChainSender.lastMsgValue(), crossChainSenderValue, "cross-chain sender value mismatch");
        assertEq(crossChainSender.lastValue(), 0, "destination-side call value mismatch");

        // The cross-chain sender is reached with the message sender as the original caller.
        assertEq(crossChainSender.lastOriginalCaller(), user, "original caller should be the message sender");
    }

    function test_sendMessage_indirectCall_assetRouterDepositIsAttributedToTheSender() public {
        uint256 depositAmount = 10 ether;
        uint256 mintValue = _baseCost(ethChainId);
        address token = _erc20Token();
        TestnetERC20Token depositToken = TestnetERC20Token(token);

        vm.deal(user, mintValue);
        depositToken.mint(user, depositAmount);
        vm.prank(user);
        depositToken.approve(address(addresses.sharedBridge), depositAmount);

        bytes memory secondBridgeCalldata = abi.encode(token, depositAmount, chainContracts[ethChainId]);

        vm.recordLogs();
        vm.prank(user);
        bytes32 sendId = interopCenter.sendMessage{value: mintValue}(
            InteroperableAddress.formatEvmV1(ethChainId, address(addresses.sharedBridge)),
            secondBridgeCalldata,
            _attributes({
                _mintValue: mintValue,
                _refundRecipient: address(0),
                _interopCallValue: 0,
                _indirect: true,
                _indirectCallMessageValue: 0
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(depositToken.balanceOf(user), 0, "the deposited token should be taken from the caller");
        assertNotEq(sendId, bytes32(0), "sendId should not be zero");

        // The depositor recorded on L1 is the account that sent the message, so a failed deposit stays
        // recoverable by them. See {protocol-docs/l1-interop-center.md#trusted-forwarding}.
        Vm.Log memory depositLog = logs.requireOne("BridgehubDepositInitiated(uint256,bytes32,address,bytes32,bytes)");
        assertEq(address(uint160(uint256(depositLog.topics[3]))), user, "depositor should be the message sender");
        assertEq(
            addresses.l1Nullifier.depositHappened(ethChainId, sendId),
            depositLog.topics[2],
            "the deposit should be recorded against the relayed request"
        );
    }

    function test_sendMessage_indirectCall_RevertWhen_factoryDepsProvided() public {
        uint256 mintValue = _baseCost(ethChainId);
        vm.deal(user, mintValue);

        bytes[] memory attributes = new bytes[](3);
        attributes[0] = abi.encodeCall(
            IERC7786Attributes.l1ToL2TransactionParams,
            (mintValue, L2_GAS_LIMIT, REQUIRED_L2_GAS_PRICE_PER_PUBDATA, address(0))
        );
        attributes[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));
        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = "FACTORY_DEP";
        attributes[2] = abi.encodeCall(IERC7786Attributes.factoryDeps, (factoryDeps));

        vm.prank(user);
        vm.expectRevert(FactoryDepsNotAllowedForIndirectCall.selector);
        interopCenter.sendMessage{value: mintValue}(
            InteroperableAddress.formatEvmV1(ethChainId, makeAddr("CROSS_CHAIN_SENDER")),
            abi.encode("PAYLOAD"),
            attributes
        );
    }

    /*//////////////////////////////////////////////////////////////
                            Validation
    //////////////////////////////////////////////////////////////*/

    function test_sendMessage_RevertWhen_chainNotRegistered() public {
        uint256 unregisteredChainId = 12345;

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ChainIdNotRegistered.selector, unregisteredChainId));
        interopCenter.sendMessage(
            InteroperableAddress.formatEvmV1(unregisteredChainId, makeAddr("L2_CONTRACT")),
            abi.encode("PAYLOAD"),
            _attributes({
                _mintValue: 0,
                _refundRecipient: address(0),
                _interopCallValue: 0,
                _indirect: false,
                _indirectCallMessageValue: 0
            })
        );
    }

    function test_sendMessage_RevertWhen_recipientAddressIsEmpty() public {
        vm.prank(user);
        vm.expectRevert(ZeroAddress.selector);
        interopCenter.sendMessage(
            InteroperableAddress.formatEvmV1(ethChainId, address(0)),
            abi.encode("PAYLOAD"),
            _attributes({
                _mintValue: 0,
                _refundRecipient: address(0),
                _interopCallValue: 0,
                _indirect: false,
                _indirectCallMessageValue: 0
            })
        );
    }

    function test_sendMessage_RevertWhen_l1ToL2TransactionParamsMissing() public {
        bytes[] memory attributes = new bytes[](1);
        attributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (0));

        vm.prank(user);
        vm.expectRevert(L1ToL2TransactionParamsMissing.selector);
        interopCenter.sendMessage(
            InteroperableAddress.formatEvmV1(ethChainId, chainContracts[ethChainId]),
            abi.encode("PAYLOAD"),
            attributes
        );
    }

    function test_sendMessage_RevertWhen_attributeSetTwice() public {
        bytes[] memory attributes = new bytes[](2);
        attributes[0] = abi.encodeCall(
            IERC7786Attributes.l1ToL2TransactionParams,
            (0, L2_GAS_LIMIT, REQUIRED_L2_GAS_PRICE_PER_PUBDATA, address(0))
        );
        attributes[1] = attributes[0];

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(AttributeAlreadySet.selector, IERC7786Attributes.l1ToL2TransactionParams.selector)
        );
        interopCenter.sendMessage(
            InteroperableAddress.formatEvmV1(ethChainId, chainContracts[ethChainId]),
            abi.encode("PAYLOAD"),
            attributes
        );
    }

    function test_sendMessage_RevertWhen_attributeUnsupported() public {
        bytes[] memory attributes = new bytes[](1);
        attributes[0] = abi.encodeCall(IERC7786Attributes.useFixedFee, (true));

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC7786GatewaySource.UnsupportedAttribute.selector,
                IERC7786Attributes.useFixedFee.selector
            )
        );
        interopCenter.sendMessage(
            InteroperableAddress.formatEvmV1(ethChainId, chainContracts[ethChainId]),
            abi.encode("PAYLOAD"),
            attributes
        );
    }

    /*//////////////////////////////////////////////////////////////
                            Trusted forwarding
    //////////////////////////////////////////////////////////////*/

    function test_requestL2TransactionDirectFor_RevertWhen_callerIsNotTheInteropCenter() public {
        L2TransactionRequestDirect memory request = _createL2TransactionRequestDirect({
            _chainId: ethChainId,
            _mintValue: 0,
            _l2Value: 0,
            _l2GasLimit: L2_GAS_LIMIT,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _l2CallData: abi.encode("PAYLOAD")
        });

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, user));
        IL1Bridgehub(address(addresses.bridgehub)).requestL2TransactionDirectFor(makeAddr("VICTIM"), request);
    }

    function test_setInteropCenter_RevertWhen_callerIsNotOwnerOrUpgrader() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, user));
        IL1Bridgehub(address(addresses.bridgehub)).setInteropCenter(makeAddr("OTHER_INTEROP_CENTER"));
    }

    function test_setInteropCenter_RevertWhen_addressIsZero() public {
        vm.prank(addresses.bridgehubOwnerAddress);
        vm.expectRevert(ZeroAddress.selector);
        IL1Bridgehub(address(addresses.bridgehub)).setInteropCenter(address(0));
    }

    function test_setInteropCenter() public {
        address newInteropCenter = makeAddr("OTHER_INTEROP_CENTER");
        IL1Bridgehub bridgehub = IL1Bridgehub(address(addresses.bridgehub));

        vm.expectEmit(true, false, false, true, address(bridgehub));
        emit IL1Bridgehub.InteropCenterSet(newInteropCenter);
        vm.prank(addresses.bridgehubOwnerAddress);
        bridgehub.setInteropCenter(newInteropCenter);

        assertEq(bridgehub.interopCenter(), newInteropCenter, "interop center mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                            Views
    //////////////////////////////////////////////////////////////*/

    function test_supportsAttribute() public view {
        assertTrue(interopCenter.supportsAttribute(IERC7786Attributes.l1ToL2TransactionParams.selector));
        assertTrue(interopCenter.supportsAttribute(IERC7786Attributes.interopCallValue.selector));
        assertTrue(interopCenter.supportsAttribute(IERC7786Attributes.indirectCall.selector));
        assertTrue(interopCenter.supportsAttribute(IERC7786Attributes.factoryDeps.selector));
        // Bundle-only L2 attributes have no meaning for a priority transaction.
        assertFalse(interopCenter.supportsAttribute(IERC7786Attributes.useFixedFee.selector));
        assertFalse(interopCenter.supportsAttribute(IERC7786Attributes.interopBundleSalt.selector));
    }

    function test_parseL1Attributes() public {
        address refundRecipient = makeAddr("REFUND_RECIPIENT");
        L1MessageAttributes memory parsed = IL1InteropCenter(address(interopCenter)).parseL1Attributes(
            _attributes({
                _mintValue: 7,
                _refundRecipient: refundRecipient,
                _interopCallValue: 11,
                _indirect: true,
                _indirectCallMessageValue: 13
            })
        );

        assertEq(parsed.mintValue, 7, "mintValue mismatch");
        assertEq(parsed.l2GasLimit, L2_GAS_LIMIT, "gas limit mismatch");
        assertEq(parsed.l2GasPerPubdataByteLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA, "gas per pubdata mismatch");
        assertEq(parsed.refundRecipient, refundRecipient, "refund recipient mismatch");
        assertEq(parsed.interopCallValue, 11, "interop call value mismatch");
        assertTrue(parsed.indirectCall, "indirect call flag mismatch");
        assertEq(parsed.indirectCallMessageValue, 13, "indirect call message value mismatch");
        assertEq(parsed.factoryDeps.length, 0, "factory deps mismatch");
    }

    function test_l2TransactionBaseCost_matchesTheChainMailbox() public view {
        uint256 fromInteropCenter = interopCenter.l2TransactionBaseCost(
            ethChainId,
            GAS_PRICE,
            L2_GAS_LIMIT,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );
        uint256 fromMailbox = MailboxFacet(getZKChainAddress(ethChainId)).l2TransactionBaseCost(
            GAS_PRICE,
            L2_GAS_LIMIT,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );

        assertEq(fromInteropCenter, fromMailbox, "base cost mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                            Helpers
    //////////////////////////////////////////////////////////////*/

    function _attributes(
        uint256 _mintValue,
        address _refundRecipient,
        uint256 _interopCallValue,
        bool _indirect,
        uint256 _indirectCallMessageValue
    ) internal pure returns (bytes[] memory attributes) {
        attributes = new bytes[](_indirect ? 3 : 2);
        attributes[0] = abi.encodeCall(
            IERC7786Attributes.l1ToL2TransactionParams,
            (_mintValue, L2_GAS_LIMIT, REQUIRED_L2_GAS_PRICE_PER_PUBDATA, _refundRecipient)
        );
        attributes[1] = abi.encodeCall(IERC7786Attributes.interopCallValue, (_interopCallValue));
        if (_indirect) {
            attributes[2] = abi.encodeCall(IERC7786Attributes.indirectCall, (_indirectCallMessageValue));
        }
    }

    function _baseCost(uint256 _chainId) internal view returns (uint256) {
        return
            MailboxFacet(getZKChainAddress(_chainId)).l2TransactionBaseCost(
                GAS_PRICE,
                L2_GAS_LIMIT,
                REQUIRED_L2_GAS_PRICE_PER_PUBDATA
            );
    }

    function _erc20Token() internal view returns (address token) {
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (tokens[i] != ETH_TOKEN_ADDRESS) {
                return tokens[i];
            }
        }
    }

    function _getNewPriorityRequest(Vm.Log[] memory _logs) internal pure returns (NewPriorityRequest memory request) {
        Vm.Log memory log = _logs.requireOne(NEW_PRIORITY_REQUEST_SIGNATURE);
        (request.txId, request.txHash, request.expirationTimestamp, request.transaction, request.factoryDeps) = abi
            .decode(log.data, (uint256, bytes32, uint64, L2CanonicalTransaction, bytes[]));
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
