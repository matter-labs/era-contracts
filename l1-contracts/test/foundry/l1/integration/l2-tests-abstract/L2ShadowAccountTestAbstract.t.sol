// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER,
    L2_INTEROP_HANDLER_ADDR,
    L2_MESSAGE_VERIFICATION,
    L2_SHADOW_ACCOUNT_FACTORY,
    L2_SHADOW_ACCOUNT_FACTORY_ADDR
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

import {IERC7786Recipient} from "contracts/interop/IERC7786Recipient.sol";
import {IShadowAccount, ShadowAccountCall, ShadowAccountCallType} from "contracts/interop/IShadowAccount.sol";
import {IShadowAccountFactory} from "contracts/interop/IShadowAccountFactory.sol";
import {ShadowAccount} from "contracts/interop/ShadowAccount.sol";
import {ShadowAccountFactory} from "contracts/interop/ShadowAccountFactory.sol";
import {InteropHandler} from "contracts/interop/InteropHandler.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";
import {
    BundleAttributes,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    InteropBundle,
    InteropCall,
    L2Message,
    MessageInclusionProof
} from "contracts/common/Messaging.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {L2InteropTestUtils, BundleExecutionResult} from "./L2InteropTestUtils.sol";

/// @title L2ShadowAccountTestAbstract
/// @notice Tests for the ShadowAccount and ShadowAccountFactory contracts.
/// @dev Tests are structured by component and cover:
///      - Factory: deployment, deterministic addressing, idempotency
///      - ShadowAccount: initialization, authorization, call execution, delegatecall
///      - InteropHandler integration: end-to-end shadow account routing via bundles
///      - Edge cases and failure modes
abstract contract L2ShadowAccountTestAbstract is Test, L2InteropTestUtils {
    ShadowAccountFactory factory;
    uint256 constant SOURCE_CHAIN_ID = 270;
    address constant OWNER_ADDRESS = address(0xBEEF);

    function setUp() public virtual override {
        super.setUp();

        // Deploy the ShadowAccountFactory at the built-in address.
        ShadowAccountFactory factoryImpl = new ShadowAccountFactory();
        vm.etch(L2_SHADOW_ACCOUNT_FACTORY_ADDR, address(factoryImpl).code);
        factory = ShadowAccountFactory(L2_SHADOW_ACCOUNT_FACTORY_ADDR);
    }

    /*//////////////////////////////////////////////////////////////
                            Helpers
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the ERC-7930 encoded owner address for (SOURCE_CHAIN_ID, OWNER_ADDRESS).
    function _ownerEncoded() internal pure returns (bytes memory) {
        return InteroperableAddress.formatEvmV1(SOURCE_CHAIN_ID, OWNER_ADDRESS);
    }

    /// @dev Returns a different ERC-7930 encoded address for authorization tests.
    function _otherOwnerEncoded() internal pure returns (bytes memory) {
        return InteroperableAddress.formatEvmV1(SOURCE_CHAIN_ID, address(0xDEAD));
    }

    /// @dev Builds a simple ShadowAccountCall[] payload with a single call.
    function _buildSingleCallPayload(
        address target,
        uint256 value,
        bytes memory data
    ) internal pure returns (bytes memory) {
        ShadowAccountCall[] memory calls = new ShadowAccountCall[](1);
        calls[0] = ShadowAccountCall({
            callType: ShadowAccountCallType.Call,
            target: target,
            value: value,
            data: data
        });
        return abi.encode(calls);
    }

    /// @dev Builds a ShadowAccountCall[] payload with a delegatecall.
    function _buildSingleDelegatecallPayload(address target, bytes memory data) internal pure returns (bytes memory) {
        ShadowAccountCall[] memory calls = new ShadowAccountCall[](1);
        calls[0] = ShadowAccountCall({callType: ShadowAccountCallType.DelegateCall, target: target, value: 0, data: data});
        return abi.encode(calls);
    }

    /// @dev Creates and executes a bundle with a single shadow account call.
    function _executeShadowAccountBundle(
        bytes memory payload,
        uint256 callValue
    ) internal returns (bytes32 bundleHash) {
        bytes memory ownerAddr = _ownerEncoded();

        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: true,
            to: address(0), // Ignored when shadowAccount is true — InteropHandler routes to the computed shadow account.
            from: OWNER_ADDRESS,
            value: callValue,
            data: payload
        });

        InteropBundle memory bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: SOURCE_CHAIN_ID,
            destinationChainId: block.chainid,
            destinationBaseTokenAssetId: destinationBaseTokenAssetId,
            interopBundleSalt: keccak256(abi.encodePacked(OWNER_ADDRESS, uint256(0))),
            calls: calls,
            bundleAttributes: BundleAttributes({executionAddress: "", unbundlerAddress: ownerAddr, useFixedFee: false})
        });

        bytes memory bundleBytes = abi.encode(bundle);
        bundleHash = InteropDataEncoding.encodeInteropBundleHash(SOURCE_CHAIN_ID, bundleBytes);

        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR, SOURCE_CHAIN_ID);
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );

        L2_INTEROP_HANDLER.executeBundle(bundleBytes, proof);
    }

    /*//////////////////////////////////////////////////////////////
                        Factory Tests
    //////////////////////////////////////////////////////////////*/

    /// @notice Factory deploys a ShadowAccount with deterministic address.
    function test_factory_deploysAtPredictedAddress() public {
        bytes memory ownerAddr = _ownerEncoded();

        address predicted = factory.predictAddress(ownerAddr);
        assertTrue(predicted != address(0), "Predicted address should not be zero");
        assertEq(predicted.code.length, 0, "Account should not exist before deployment");

        address deployed = factory.getOrDeployShadowAccount(ownerAddr);
        assertEq(deployed, predicted, "Deployed address must match predicted address");
        assertTrue(deployed.code.length > 0, "Account should have code after deployment");
    }

    /// @notice Factory returns existing account on second call (idempotent).
    function test_factory_idempotentDeployment() public {
        bytes memory ownerAddr = _ownerEncoded();

        address first = factory.getOrDeployShadowAccount(ownerAddr);
        address second = factory.getOrDeployShadowAccount(ownerAddr);
        assertEq(first, second, "Second deployment must return existing account");
    }

    /// @notice Different owners get different shadow account addresses.
    function test_factory_differentOwnersGetDifferentAddresses() public {
        bytes memory owner1 = _ownerEncoded();
        bytes memory owner2 = _otherOwnerEncoded();

        address addr1 = factory.predictAddress(owner1);
        address addr2 = factory.predictAddress(owner2);
        assertTrue(addr1 != addr2, "Different owners must have different shadow accounts");
    }

    /// @notice Same owner on different source chains gets different shadow accounts.
    function test_factory_differentChainsGetDifferentAddresses() public {
        bytes memory ownerChain1 = InteroperableAddress.formatEvmV1(100, OWNER_ADDRESS);
        bytes memory ownerChain2 = InteroperableAddress.formatEvmV1(200, OWNER_ADDRESS);

        address addr1 = factory.predictAddress(ownerChain1);
        address addr2 = factory.predictAddress(ownerChain2);
        assertTrue(addr1 != addr2, "Same address on different chains must have different shadow accounts");
    }

    /// @notice Factory emits ShadowAccountDeployed on first deployment.
    function test_factory_emitsDeployEvent() public {
        bytes memory ownerAddr = _ownerEncoded();
        address predicted = factory.predictAddress(ownerAddr);

        vm.expectEmit(true, false, false, true);
        emit IShadowAccountFactory.ShadowAccountDeployed(predicted, ownerAddr);
        factory.getOrDeployShadowAccount(ownerAddr);
    }

    /*//////////////////////////////////////////////////////////////
                    ShadowAccount Initialization Tests
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize sets owner correctly.
    function test_shadowAccount_initializeSetsOwner() public {
        bytes memory ownerAddr = _ownerEncoded();
        address account = factory.getOrDeployShadowAccount(ownerAddr);

        bytes memory storedOwner = ShadowAccount(payable(account)).owner();
        assertEq(keccak256(storedOwner), keccak256(ownerAddr), "Owner must match deployed value");
    }

    /// @notice Initialize emits ShadowAccountInitialized event.
    function test_shadowAccount_initializeEmitsEvent() public {
        bytes memory ownerAddr = _ownerEncoded();
        address predicted = factory.predictAddress(ownerAddr);

        vm.expectEmit(false, false, false, true);
        emit IShadowAccount.ShadowAccountInitialized(ownerAddr);
        factory.getOrDeployShadowAccount(ownerAddr);
    }

    /// @notice Initialize reverts on second call.
    function test_shadowAccount_cannotInitializeTwice() public {
        bytes memory ownerAddr = _ownerEncoded();
        address account = factory.getOrDeployShadowAccount(ownerAddr);

        vm.prank(L2_SHADOW_ACCOUNT_FACTORY_ADDR);
        vm.expectRevert();
        ShadowAccount(payable(account)).initialize(ownerAddr);
    }

    /// @notice Initialize reverts when caller is not the factory.
    function test_shadowAccount_initializeOnlyFactory() public {
        // Deploy a ShadowAccount directly (not via factory) to test the factory check.
        ShadowAccount account = new ShadowAccount();
        vm.expectRevert();
        account.initialize(_ownerEncoded());
    }

    /*//////////////////////////////////////////////////////////////
                    ShadowAccount Authorization Tests
    //////////////////////////////////////////////////////////////*/

    /// @notice receiveMessage reverts when msg.sender is not InteropHandler.
    function test_shadowAccount_receiveMessageOnlyInteropHandler() public {
        bytes memory ownerAddr = _ownerEncoded();
        address account = factory.getOrDeployShadowAccount(ownerAddr);
        bytes memory payload = _buildSingleCallPayload(address(0x1), 0, "");

        vm.expectRevert();
        IERC7786Recipient(account).receiveMessage(bytes32(0), ownerAddr, payload);
    }

    /// @notice receiveMessage reverts when sender does not match owner.
    function test_shadowAccount_receiveMessageOnlyOwner() public {
        bytes memory ownerAddr = _ownerEncoded();
        address account = factory.getOrDeployShadowAccount(ownerAddr);
        bytes memory payload = _buildSingleCallPayload(address(0x1), 0, "");

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        vm.expectRevert();
        IERC7786Recipient(account).receiveMessage(bytes32(0), _otherOwnerEncoded(), payload);
    }

    /// @notice receiveMessage succeeds with correct sender and authorized caller.
    function test_shadowAccount_receiveMessageHappyPath() public {
        bytes memory ownerAddr = _ownerEncoded();
        address account = factory.getOrDeployShadowAccount(ownerAddr);

        // Target contract that just accepts calls
        address target = makeAddr("target");
        vm.etch(target, hex"00");

        // Build a payload with a call to the target
        ShadowAccountCall[] memory calls = new ShadowAccountCall[](1);
        calls[0] = ShadowAccountCall({
            callType: ShadowAccountCallType.Call,
            target: target,
            value: 0,
            data: ""
        });
        bytes memory payload = abi.encode(calls);

        // Mock the target call to succeed
        vm.mockCall(target, bytes(""), abi.encode(true));

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        bytes4 ret = IERC7786Recipient(account).receiveMessage(bytes32(0), ownerAddr, payload);
        assertEq(ret, IERC7786Recipient.receiveMessage.selector, "Should return correct selector");
    }

    /*//////////////////////////////////////////////////////////////
                    ShadowAccount Call Execution Tests
    //////////////////////////////////////////////////////////////*/

    /// @notice ShadowAccount executes a value transfer correctly.
    function test_shadowAccount_executesValueTransfer() public {
        bytes memory ownerAddr = _ownerEncoded();
        address account = factory.getOrDeployShadowAccount(ownerAddr);
        address recipient = makeAddr("recipient");

        // Fund the shadow account
        vm.deal(account, 1 ether);

        ShadowAccountCall[] memory calls = new ShadowAccountCall[](1);
        calls[0] = ShadowAccountCall({callType: ShadowAccountCallType.Call, target: recipient, value: 0.5 ether, data: ""});
        bytes memory payload = abi.encode(calls);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        IERC7786Recipient(account).receiveMessage(bytes32(0), ownerAddr, payload);

        assertEq(recipient.balance, 0.5 ether, "Recipient should have received 0.5 ETH");
        assertEq(account.balance, 0.5 ether, "Shadow account should have 0.5 ETH remaining");
    }

    /// @notice ShadowAccount executes multiple calls sequentially.
    function test_shadowAccount_executesMultipleCalls() public {
        bytes memory ownerAddr = _ownerEncoded();
        address account = factory.getOrDeployShadowAccount(ownerAddr);
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");

        vm.deal(account, 2 ether);

        ShadowAccountCall[] memory calls = new ShadowAccountCall[](2);
        calls[0] = ShadowAccountCall({
            callType: ShadowAccountCallType.Call,
            target: recipient1,
            value: 0.5 ether,
            data: ""
        });
        calls[1] = ShadowAccountCall({
            callType: ShadowAccountCallType.Call,
            target: recipient2,
            value: 0.3 ether,
            data: ""
        });
        bytes memory payload = abi.encode(calls);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        IERC7786Recipient(account).receiveMessage(bytes32(0), ownerAddr, payload);

        assertEq(recipient1.balance, 0.5 ether, "Recipient1 should have received 0.5 ETH");
        assertEq(recipient2.balance, 0.3 ether, "Recipient2 should have received 0.3 ETH");
    }

    /// @notice ShadowAccount emits ShadowAccountCallExecuted for each call.
    function test_shadowAccount_emitsCallExecutedEvents() public {
        bytes memory ownerAddr = _ownerEncoded();
        address account = factory.getOrDeployShadowAccount(ownerAddr);
        address target = makeAddr("target");

        ShadowAccountCall[] memory calls = new ShadowAccountCall[](1);
        calls[0] = ShadowAccountCall({callType: ShadowAccountCallType.Call, target: target, value: 0, data: ""});
        bytes memory payload = abi.encode(calls);

        vm.expectEmit(true, false, false, true);
        emit IShadowAccount.ShadowAccountCallExecuted(0, ShadowAccountCallType.Call, target);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        IERC7786Recipient(account).receiveMessage(bytes32(0), ownerAddr, payload);
    }

    /// @notice ShadowAccount reverts if a call fails.
    function test_shadowAccount_revertsOnCallFailure() public {
        bytes memory ownerAddr = _ownerEncoded();
        address account = factory.getOrDeployShadowAccount(ownerAddr);

        // Create a target that will revert
        address reverter = makeAddr("reverter");
        vm.mockCallRevert(reverter, bytes(""), bytes("revert reason"));

        ShadowAccountCall[] memory calls = new ShadowAccountCall[](1);
        calls[0] = ShadowAccountCall({callType: ShadowAccountCallType.Call, target: reverter, value: 0, data: ""});
        bytes memory payload = abi.encode(calls);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        vm.expectRevert();
        IERC7786Recipient(account).receiveMessage(bytes32(0), ownerAddr, payload);
    }

    /// @notice ShadowAccount supports delegatecall execution.
    function test_shadowAccount_executesDelegatecall() public {
        bytes memory ownerAddr = _ownerEncoded();
        address account = factory.getOrDeployShadowAccount(ownerAddr);
        address target = makeAddr("script");

        // Mock the delegatecall to succeed
        vm.mockCall(target, bytes(""), abi.encode(true));

        ShadowAccountCall[] memory calls = new ShadowAccountCall[](1);
        calls[0] = ShadowAccountCall({callType: ShadowAccountCallType.DelegateCall, target: target, value: 0, data: ""});
        bytes memory payload = abi.encode(calls);

        vm.expectEmit(true, false, false, true);
        emit IShadowAccount.ShadowAccountCallExecuted(0, ShadowAccountCallType.DelegateCall, target);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        bytes4 ret = IERC7786Recipient(account).receiveMessage(bytes32(0), ownerAddr, payload);
        assertEq(ret, IERC7786Recipient.receiveMessage.selector);
    }

    /// @notice ShadowAccount can receive ETH via receive().
    function test_shadowAccount_canReceiveEth() public {
        bytes memory ownerAddr = _ownerEncoded();
        address account = factory.getOrDeployShadowAccount(ownerAddr);

        vm.deal(address(this), 1 ether);
        (bool success, ) = account.call{value: 1 ether}("");
        assertTrue(success, "Should accept ETH");
        assertEq(account.balance, 1 ether, "Balance should be 1 ETH");
    }

    /*//////////////////////////////////////////////////////////////
                    InteropHandler Integration Tests
    //////////////////////////////////////////////////////////////*/

    /// @notice InteropHandler routes shadow account calls through the factory.
    /// @dev This is the core integration test: a bundle with shadowAccount=true
    ///      should deploy a ShadowAccount and execute the payload through it.
    function test_interopHandler_routesThroughShadowAccount() public {
        bytes memory ownerAddr = _ownerEncoded();
        address predicted = factory.predictAddress(ownerAddr);

        // The shadow account doesn't exist yet.
        assertEq(predicted.code.length, 0, "Shadow account should not exist before bundle execution");

        // Mock the shadow account's receiveMessage to succeed
        // (since in L1 context tests, the CREATE2 deployed contract may not work perfectly)
        vm.mockCall(
            predicted,
            abi.encodeWithSelector(IERC7786Recipient.receiveMessage.selector),
            abi.encode(IERC7786Recipient.receiveMessage.selector)
        );
        vm.mockCall(
            predicted,
            0,
            abi.encodeWithSelector(IERC7786Recipient.receiveMessage.selector),
            abi.encode(IERC7786Recipient.receiveMessage.selector)
        );

        bytes memory payload = _buildSingleCallPayload(makeAddr("someTarget"), 0, "");

        bytes32 bundleHash = _executeShadowAccountBundle(payload, 0);

        // Verify the bundle was fully executed.
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).bundleStatus(bundleHash)),
            2, // FullyExecuted
            "Bundle should be fully executed"
        );

        // Verify call status is Executed.
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).callStatus(bundleHash, 0)),
            1, // Executed
            "Call should be executed"
        );
    }

    /// @notice Non-shadow-account bundle calls still work (regression check).
    function test_interopHandler_nonShadowAccountCallStillWorks() public {
        // Create a standard (non-shadow-account) bundle call.
        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: interopTargetContract,
            from: OWNER_ADDRESS,
            value: 0,
            data: ""
        });

        InteropBundle memory bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: SOURCE_CHAIN_ID,
            destinationChainId: block.chainid,
            destinationBaseTokenAssetId: destinationBaseTokenAssetId,
            interopBundleSalt: keccak256(abi.encodePacked(OWNER_ADDRESS, uint256(1))),
            calls: calls,
            bundleAttributes: BundleAttributes({
                executionAddress: "",
                unbundlerAddress: _ownerEncoded(),
                useFixedFee: false
            })
        });

        bytes memory bundleBytes = abi.encode(bundle);
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(SOURCE_CHAIN_ID, bundleBytes);

        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR, SOURCE_CHAIN_ID);
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );

        L2_INTEROP_HANDLER.executeBundle(bundleBytes, proof);

        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).bundleStatus(bundleHash)),
            2, // FullyExecuted
            "Non-shadow bundle should be fully executed"
        );
    }

    /*//////////////////////////////////////////////////////////////
                            Fuzz Tests
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: different owners always get different shadow account addresses.
    function testFuzz_factory_differentOwnersDistinctAddresses(address owner1, address owner2) public {
        vm.assume(owner1 != owner2);

        bytes memory encoded1 = InteroperableAddress.formatEvmV1(SOURCE_CHAIN_ID, owner1);
        bytes memory encoded2 = InteroperableAddress.formatEvmV1(SOURCE_CHAIN_ID, owner2);

        address addr1 = factory.predictAddress(encoded1);
        address addr2 = factory.predictAddress(encoded2);
        assertTrue(addr1 != addr2, "Different owners must yield different addresses");
    }

    /// @notice Fuzz test: predict and deploy always match.
    function testFuzz_factory_predictMatchesDeploy(uint256 chainId, address ownerAddr) public {
        vm.assume(chainId > 0 && chainId < type(uint128).max);
        vm.assume(ownerAddr != address(0));

        bytes memory encoded = InteroperableAddress.formatEvmV1(chainId, ownerAddr);
        address predicted = factory.predictAddress(encoded);
        address deployed = factory.getOrDeployShadowAccount(encoded);
        assertEq(predicted, deployed, "Predicted must always match deployed");
    }
}
