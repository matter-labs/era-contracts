// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";

import {GWAssetTracker} from "contracts/bridge/asset-tracker/GWAssetTracker.sol";
import {IGWAssetTracker} from "contracts/bridge/asset-tracker/IGWAssetTracker.sol";
import {L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_INTEROP_CENTER_ADDR, L2_MESSAGE_ROOT_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_ASSET_ROUTER_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_COMPRESSOR_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {IChainAssetHandler} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {InvalidFeeRecipient, SettlementFeePayerNotAgreed} from "contracts/bridge/asset-tracker/AssetTrackerErrors.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {GWAssetTrackerTestHelper} from "./GWAssetTracker.t.sol";
import {ProcessLogsTestHelper} from "./ProcessLogsTestHelper.sol";
import {L2Log, InteropBundle} from "contracts/common/Messaging.sol";
import {ProcessLogsInput} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

contract GWAssetTrackerFeesTest is Test {
    GWAssetTrackerTestHelper public gwAssetTracker;
    TestnetERC20Token public wrappedZKToken;

    address public owner;
    address public mockBridgehub;
    address public mockMessageRoot;
    address public mockNativeTokenVault;
    address public mockChainAssetHandler;
    address public mockZKChain;
    address public mockAssetRouter;

    uint256 public constant L1_CHAIN_ID = 1;
    uint256 public constant CHAIN_ID = 270;
    uint256 public constant OTHER_CHAIN_ID = 271;
    uint256 public constant DESTINATION_CHAIN_ID = 300;
    bytes32 public constant BASE_TOKEN_ASSET_ID = keccak256("baseTokenAssetId");

    event GatewaySettlementFeeUpdated(uint256 indexed oldFee, uint256 indexed newFee);
    event SettlementFeePayerAgreementUpdated(address indexed payer, uint256 indexed chainId, bool agreed);
    event GatewaySettlementFeesCollected(
        uint256 indexed chainId,
        address indexed feePayer,
        uint256 amount,
        uint256 interopCallCount
    );

    function setUp() public {
        // Deploy wrapped ZK token first (before GWAssetTracker setup)
        wrappedZKToken = new TestnetERC20Token("Wrapped ZK", "WZK", 18);

        // Deploy GWAssetTracker (using test helper for internal function access)
        gwAssetTracker = new GWAssetTrackerTestHelper();
        owner = makeAddr("owner");

        // Create mock addresses
        mockBridgehub = makeAddr("mockBridgehub");
        mockMessageRoot = makeAddr("mockMessageRoot");
        mockNativeTokenVault = makeAddr("mockNativeTokenVault");
        mockChainAssetHandler = makeAddr("mockChainAssetHandler");
        mockZKChain = makeAddr("mockZKChain");
        mockAssetRouter = makeAddr("mockAssetRouter");

        // Mock the L2 contract addresses
        vm.etch(L2_BRIDGEHUB_ADDR, address(mockBridgehub).code);
        vm.etch(L2_MESSAGE_ROOT_ADDR, address(mockMessageRoot).code);
        vm.etch(L2_NATIVE_TOKEN_VAULT_ADDR, address(mockNativeTokenVault).code);
        vm.etch(L2_CHAIN_ASSET_HANDLER_ADDR, address(mockChainAssetHandler).code);
        vm.etch(L2_ASSET_ROUTER_ADDR, address(mockAssetRouter).code);

        // Mock the WETH_TOKEN() call on NativeTokenVault to return our test token
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(IL2NativeTokenVault.WETH_TOKEN.selector),
            abi.encode(address(wrappedZKToken))
        );

        // Set up the contract
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.initL2(L1_CHAIN_ID, owner);

        vm.mockCall(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector),
            abi.encode(1)
        );

        // Set up persistent mocks needed by processLogsAndMessages
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(mockZKChain)
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );
        // Mock baseTokenAssetId for the destination chain used in interop bundles
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, DESTINATION_CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );
        // Mock message root addChainBatchRoot (accept any arguments)
        vm.mockCall(
            L2_MESSAGE_ROOT_ADDR,
            abi.encodeWithSignature("addChainBatchRoot(uint256,uint256,bytes32)"),
            abi.encode()
        );
    }

    /// @notice Builds a ProcessLogsInput with interop bundles (does NOT call processLogsAndMessages).
    function _buildInteropBundlesInput(
        uint256 _numBundles,
        uint256[] memory _callsPerBundle,
        address _payer,
        uint256 _batchNumber
    ) internal returns (ProcessLogsInput memory) {
        require(_numBundles == _callsPerBundle.length, "length mismatch");

        L2Log[] memory logs = new L2Log[](_numBundles);
        bytes[] memory messages = new bytes[](_numBundles);

        for (uint256 i = 0; i < _numBundles; i++) {
            InteropBundle memory bundle = ProcessLogsTestHelper.createSimpleInteropBundle(
                CHAIN_ID,
                DESTINATION_CHAIN_ID,
                _callsPerBundle[i],
                keccak256(abi.encode("salt", i, _batchNumber))
            );
            bytes memory message = ProcessLogsTestHelper.encodeInteropCenterMessage(bundle);
            logs[i] = ProcessLogsTestHelper.createInteropCenterLog(uint16(i), message);
            messages[i] = message;
        }

        return
            ProcessLogsTestHelper.buildProcessLogsInput(gwAssetTracker, CHAIN_ID, _batchNumber, logs, messages, _payer);
    }

    /// @notice Builds input and executes processLogsAndMessages with interop bundles.
    function _processLogsWithInteropBundles(
        uint256 _numBundles,
        uint256[] memory _callsPerBundle,
        address _payer,
        uint256 _batchNumber
    ) internal {
        ProcessLogsInput memory input = _buildInteropBundlesInput(_numBundles, _callsPerBundle, _payer, _batchNumber);
        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);
    }

    /// @notice Single-bundle convenience: builds input and executes.
    function _processLogsWithSingleBundle(uint256 _numCalls, address _payer, uint256 _batchNumber) internal {
        uint256[] memory callsPerBundle = new uint256[](1);
        callsPerBundle[0] = _numCalls;
        _processLogsWithInteropBundles(1, callsPerBundle, _payer, _batchNumber);
    }

    /// @notice Single-bundle convenience: builds input only (for use with vm.expectRevert).
    function _buildSingleBundleInput(
        uint256 _numCalls,
        address _payer,
        uint256 _batchNumber
    ) internal returns (ProcessLogsInput memory) {
        uint256[] memory callsPerBundle = new uint256[](1);
        callsPerBundle[0] = _numCalls;
        return _buildInteropBundlesInput(1, callsPerBundle, _payer, _batchNumber);
    }

    /*//////////////////////////////////////////////////////////////
                        SETTLEMENT FEE CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_setGatewaySettlementFee() public {
        uint256 newFee = 0.01 ether;

        vm.prank(owner);
        gwAssetTracker.setGatewaySettlementFee(newFee);

        assertEq(gwAssetTracker.gatewaySettlementFee(), newFee);
    }

    function test_setGatewaySettlementFee_Unauthorized() public {
        address nonOwner = makeAddr("nonOwner");
        uint256 newFee = 0.01 ether;

        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        gwAssetTracker.setGatewaySettlementFee(newFee);
    }

    function test_setGatewaySettlementFee_EmitsEvent() public {
        uint256 oldFee = gwAssetTracker.gatewaySettlementFee();
        uint256 newFee = 0.01 ether;

        vm.expectEmit(true, true, false, false);
        emit GatewaySettlementFeeUpdated(oldFee, newFee);

        vm.prank(owner);
        gwAssetTracker.setGatewaySettlementFee(newFee);
    }

    function test_setGatewaySettlementFee_Zero() public {
        // First set a non-zero fee
        vm.prank(owner);
        gwAssetTracker.setGatewaySettlementFee(0.01 ether);

        // Then set to zero (disable fees)
        vm.prank(owner);
        gwAssetTracker.setGatewaySettlementFee(0);

        assertEq(gwAssetTracker.gatewaySettlementFee(), 0);
    }

    function test_setGatewaySettlementFee_UpdateMultipleTimes() public {
        uint256[] memory fees = new uint256[](3);
        fees[0] = 0.01 ether;
        fees[1] = 0.05 ether;
        fees[2] = 0.001 ether;

        for (uint256 i = 0; i < fees.length; i++) {
            vm.prank(owner);
            gwAssetTracker.setGatewaySettlementFee(fees[i]);
            assertEq(gwAssetTracker.gatewaySettlementFee(), fees[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        FEE WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    function test_withdrawGatewayFees() public {
        // Mint tokens to the GWAssetTracker (simulating collected fees)
        uint256 collectedFees = 10 ether;
        wrappedZKToken.mint(address(gwAssetTracker), collectedFees);

        address recipient = makeAddr("feeRecipient");
        uint256 recipientBalanceBefore = wrappedZKToken.balanceOf(recipient);

        vm.prank(owner);
        gwAssetTracker.withdrawGatewayFees(recipient);

        assertEq(wrappedZKToken.balanceOf(recipient), recipientBalanceBefore + collectedFees);
        assertEq(wrappedZKToken.balanceOf(address(gwAssetTracker)), 0);
    }

    function test_withdrawGatewayFees_Unauthorized() public {
        address nonOwner = makeAddr("nonOwner");
        address recipient = makeAddr("feeRecipient");

        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        gwAssetTracker.withdrawGatewayFees(recipient);
    }

    function test_withdrawGatewayFees_InvalidFeeRecipient() public {
        vm.prank(owner);
        vm.expectRevert(InvalidFeeRecipient.selector);
        gwAssetTracker.withdrawGatewayFees(address(0));
    }

    function test_withdrawGatewayFees_ZeroBalance() public {
        address recipient = makeAddr("feeRecipient");
        uint256 recipientBalanceBefore = wrappedZKToken.balanceOf(recipient);

        // Should not revert even with zero balance
        vm.prank(owner);
        gwAssetTracker.withdrawGatewayFees(recipient);

        assertEq(wrappedZKToken.balanceOf(recipient), recipientBalanceBefore);
    }

    /*//////////////////////////////////////////////////////////////
                    SETTLEMENT FEE PAYER AGREEMENT
    //////////////////////////////////////////////////////////////*/

    function test_agreeToPaySettlementFees() public {
        address payer = makeAddr("payer");

        vm.prank(payer);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID);

        assertTrue(gwAssetTracker.settlementFeePayerAgreement(payer, CHAIN_ID));
    }

    function test_agreeToPaySettlementFees_EmitsEvent() public {
        address payer = makeAddr("payer");

        vm.expectEmit(true, true, false, true);
        emit SettlementFeePayerAgreementUpdated(payer, CHAIN_ID, true);

        vm.prank(payer);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID);
    }

    function test_agreeToPaySettlementFees_MultipleChains() public {
        address payer = makeAddr("payer");

        vm.startPrank(payer);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID);
        gwAssetTracker.agreeToPaySettlementFees(OTHER_CHAIN_ID);
        vm.stopPrank();

        assertTrue(gwAssetTracker.settlementFeePayerAgreement(payer, CHAIN_ID));
        assertTrue(gwAssetTracker.settlementFeePayerAgreement(payer, OTHER_CHAIN_ID));
    }

    function test_agreeToPaySettlementFees_Idempotent() public {
        address payer = makeAddr("payer");

        vm.startPrank(payer);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID); // Call again
        vm.stopPrank();

        assertTrue(gwAssetTracker.settlementFeePayerAgreement(payer, CHAIN_ID));
    }

    function test_revokeSettlementFeePayerAgreement() public {
        address payer = makeAddr("payer");

        // First agree
        vm.prank(payer);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID);
        assertTrue(gwAssetTracker.settlementFeePayerAgreement(payer, CHAIN_ID));

        // Then revoke
        vm.prank(payer);
        gwAssetTracker.revokeSettlementFeePayerAgreement(CHAIN_ID);
        assertFalse(gwAssetTracker.settlementFeePayerAgreement(payer, CHAIN_ID));
    }

    function test_revokeSettlementFeePayerAgreement_EmitsEvent() public {
        address payer = makeAddr("payer");

        // First agree
        vm.prank(payer);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID);

        vm.expectEmit(true, true, false, true);
        emit SettlementFeePayerAgreementUpdated(payer, CHAIN_ID, false);

        vm.prank(payer);
        gwAssetTracker.revokeSettlementFeePayerAgreement(CHAIN_ID);
    }

    function test_revokeSettlementFeePayerAgreement_OnlyAffectsSpecificChain() public {
        address payer = makeAddr("payer");

        // Agree for both chains
        vm.startPrank(payer);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID);
        gwAssetTracker.agreeToPaySettlementFees(OTHER_CHAIN_ID);

        // Revoke for one chain
        gwAssetTracker.revokeSettlementFeePayerAgreement(CHAIN_ID);
        vm.stopPrank();

        assertFalse(gwAssetTracker.settlementFeePayerAgreement(payer, CHAIN_ID));
        assertTrue(gwAssetTracker.settlementFeePayerAgreement(payer, OTHER_CHAIN_ID));
    }

    function test_revokeSettlementFeePayerAgreement_NeverAgreed() public {
        address payer = makeAddr("payer");

        // Revoking without ever agreeing should not revert
        vm.prank(payer);
        gwAssetTracker.revokeSettlementFeePayerAgreement(CHAIN_ID);

        assertFalse(gwAssetTracker.settlementFeePayerAgreement(payer, CHAIN_ID));
    }

    /*//////////////////////////////////////////////////////////////
                        WRAPPED ZK TOKEN SETUP
    //////////////////////////////////////////////////////////////*/

    function test_wrappedZKToken_SetOnInit() public {
        assertEq(address(gwAssetTracker.wrappedZKToken()), address(wrappedZKToken));
    }

    function test_wrappedZKToken_UsedForFeeCollection() public {
        // This verifies that the wrappedZKToken is the one used for fee operations
        IERC20 token = gwAssetTracker.wrappedZKToken();
        assertEq(address(token), address(wrappedZKToken));
    }

    /*//////////////////////////////////////////////////////////////
                    SETTLEMENT FEE PAYER - SECURITY
    //////////////////////////////////////////////////////////////*/

    function test_settlementFeePayerAgreement_DifferentPayersIndependent() public {
        address payer1 = makeAddr("payer1");
        address payer2 = makeAddr("payer2");

        // Only payer1 agrees
        vm.prank(payer1);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID);

        assertTrue(gwAssetTracker.settlementFeePayerAgreement(payer1, CHAIN_ID));
        assertFalse(gwAssetTracker.settlementFeePayerAgreement(payer2, CHAIN_ID));
    }

    function test_settlementFeePayerAgreement_CannotAgreeForOthers() public {
        address payer = makeAddr("payer");
        address attacker = makeAddr("attacker");

        // Attacker cannot make payer agree
        vm.prank(attacker);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID);

        // Only attacker is recorded as agreed, not payer
        assertTrue(gwAssetTracker.settlementFeePayerAgreement(attacker, CHAIN_ID));
        assertFalse(gwAssetTracker.settlementFeePayerAgreement(payer, CHAIN_ID));
    }

    /*//////////////////////////////////////////////////////////////
                    SETTLEMENT FEE COLLECTION VIA processLogsAndMessages
                    FAILURE PATHS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that fee collection reverts when payer has NOT agreed
    function test_processLogs_feeCollection_payerNotAgreed() public {
        uint256 fee = 0.01 ether;
        vm.prank(owner);
        gwAssetTracker.setGatewaySettlementFee(fee);

        address payer = makeAddr("unagreedPayer");

        // Payer has NOT called agreeToPaySettlementFees
        assertFalse(gwAssetTracker.settlementFeePayerAgreement(payer, CHAIN_ID));

        // Build input first (makes external calls), then expect revert on processLogsAndMessages
        ProcessLogsInput memory input = _buildSingleBundleInput(5, payer, 1);
        vm.expectRevert(abi.encodeWithSelector(SettlementFeePayerNotAgreed.selector, payer, CHAIN_ID));
        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);
    }

    /// @notice Test that fee collection reverts when payer revoked agreement after previously agreeing
    function test_processLogs_feeCollection_payerRevokedAfterAgreement() public {
        uint256 fee = 0.01 ether;
        vm.prank(owner);
        gwAssetTracker.setGatewaySettlementFee(fee);

        address payer = makeAddr("revokingPayer");

        // Payer agrees
        vm.prank(payer);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID);
        assertTrue(gwAssetTracker.settlementFeePayerAgreement(payer, CHAIN_ID));

        // Payer revokes
        vm.prank(payer);
        gwAssetTracker.revokeSettlementFeePayerAgreement(CHAIN_ID);
        assertFalse(gwAssetTracker.settlementFeePayerAgreement(payer, CHAIN_ID));

        // Build input first, then expect revert
        ProcessLogsInput memory input = _buildSingleBundleInput(3, payer, 1);
        vm.expectRevert(abi.encodeWithSelector(SettlementFeePayerNotAgreed.selector, payer, CHAIN_ID));
        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);
    }

    /// @notice Test that fee collection reverts when payer has insufficient allowance
    function test_processLogs_feeCollection_insufficientAllowance() public {
        uint256 fee = 1 ether;
        vm.prank(owner);
        gwAssetTracker.setGatewaySettlementFee(fee);

        address payer = makeAddr("lowAllowancePayer");

        // Payer agrees
        vm.prank(payer);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID);

        // Payer has enough balance but insufficient allowance
        wrappedZKToken.mint(payer, 100 ether);
        vm.prank(payer);
        wrappedZKToken.approve(address(gwAssetTracker), 0); // Zero allowance

        // Build input first, then expect revert
        ProcessLogsInput memory input = _buildSingleBundleInput(5, payer, 1);
        vm.expectRevert();
        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);
    }

    /// @notice Test that fee collection reverts when payer has insufficient balance
    function test_processLogs_feeCollection_insufficientBalance() public {
        uint256 fee = 1 ether;
        vm.prank(owner);
        gwAssetTracker.setGatewaySettlementFee(fee);

        address payer = makeAddr("lowBalancePayer");

        // Payer agrees
        vm.prank(payer);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID);

        // Payer has approval but not enough balance
        wrappedZKToken.mint(payer, 1 ether); // Only 1 ether, but 5 * 1 ether = 5 ether needed
        vm.prank(payer);
        wrappedZKToken.approve(address(gwAssetTracker), type(uint256).max);

        // Build input first, then expect revert
        ProcessLogsInput memory input = _buildSingleBundleInput(5, payer, 1);
        vm.expectRevert();
        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);
    }

    /// @notice Test zero payer address with non-zero chargeable calls
    function test_processLogs_feeCollection_zeroPayerWithChargeableCalls() public {
        uint256 fee = 0.01 ether;
        vm.prank(owner);
        gwAssetTracker.setGatewaySettlementFee(fee);

        // Build input first, then expect revert
        ProcessLogsInput memory input = _buildSingleBundleInput(3, address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(SettlementFeePayerNotAgreed.selector, address(0), CHAIN_ID));
        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);
    }

    /*//////////////////////////////////////////////////////////////
                    FEE COLLECTION VIA processLogsAndMessages
                    EXACT ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Test exact fee math with a single bundle containing multiple calls
    function test_processLogs_feeCollection_exactFeeAccounting() public {
        uint256 fee = 0.003 ether;
        vm.prank(owner);
        gwAssetTracker.setGatewaySettlementFee(fee);

        address payer = makeAddr("exactPayer");

        vm.prank(payer);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID);

        uint256 mintAmount = 100 ether;
        wrappedZKToken.mint(payer, mintAmount);
        vm.prank(payer);
        wrappedZKToken.approve(address(gwAssetTracker), type(uint256).max);

        uint256 interopCallCount = 7;
        uint256 expectedTotalFee = fee * interopCallCount; // 0.003 * 7 = 0.021 ether

        uint256 payerBalanceBefore = wrappedZKToken.balanceOf(payer);
        uint256 trackerBalanceBefore = wrappedZKToken.balanceOf(address(gwAssetTracker));

        // Build input first, then set expectEmit right before the call
        ProcessLogsInput memory input = _buildSingleBundleInput(interopCallCount, payer, 1);

        vm.expectEmit(true, true, false, true);
        emit GatewaySettlementFeesCollected(CHAIN_ID, payer, expectedTotalFee, interopCallCount);

        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);

        assertEq(
            wrappedZKToken.balanceOf(payer),
            payerBalanceBefore - expectedTotalFee,
            "Payer balance should decrease by exact fee"
        );
        assertEq(
            wrappedZKToken.balanceOf(address(gwAssetTracker)),
            trackerBalanceBefore + expectedTotalFee,
            "Tracker balance should increase by exact fee"
        );
    }

    /// @notice Test that zero interop logs (no bundles) means no fee collection
    function test_processLogs_feeCollection_noInteropLogsSkips() public {
        uint256 fee = 0.01 ether;
        vm.prank(owner);
        gwAssetTracker.setGatewaySettlementFee(fee);

        address payer = makeAddr("zeroPayer");
        // Does not need to agree if chargeable count is 0

        // Process with zero logs (empty batch)
        L2Log[] memory logs = new L2Log[](0);
        bytes[] memory messages = new bytes[](0);

        ProcessLogsInput memory input = ProcessLogsTestHelper.buildProcessLogsInput(
            gwAssetTracker,
            CHAIN_ID,
            1,
            logs,
            messages,
            payer
        );

        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);
        // Should not revert - fee collection skips when chargeableInteropCount is 0
    }

    /// @notice Test that zero fee skips collection even with non-zero chargeable count
    function test_processLogs_feeCollection_zeroFeeSkips() public {
        // Fee is already zero by default
        assertEq(gwAssetTracker.gatewaySettlementFee(), 0);

        address payer = makeAddr("zeroFeePayer");
        // Does not need to agree if fee is 0

        // Should not revert, fee collection skips when fee is 0
        _processLogsWithSingleBundle(10, payer, 1);
    }

    /// @notice Test fee collection across multiple batches accumulates correctly
    function test_processLogs_feeCollection_multipleBatchesAccumulate() public {
        uint256 fee = 0.005 ether;
        vm.prank(owner);
        gwAssetTracker.setGatewaySettlementFee(fee);

        address payer = makeAddr("multiPayer");

        vm.prank(payer);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID);

        wrappedZKToken.mint(payer, 100 ether);
        vm.prank(payer);
        wrappedZKToken.approve(address(gwAssetTracker), type(uint256).max);

        // First batch: 1 bundle with 3 calls
        _processLogsWithSingleBundle(3, payer, 1);

        // Second batch: 1 bundle with 5 calls
        _processLogsWithSingleBundle(5, payer, 2);

        // Third batch: 1 bundle with 2 calls
        _processLogsWithSingleBundle(2, payer, 3);

        // Total: 3 + 5 + 2 = 10 calls, 10 * 0.005 = 0.05 ether
        uint256 totalExpected = fee * 10;
        assertEq(
            wrappedZKToken.balanceOf(address(gwAssetTracker)),
            totalExpected,
            "Accumulated fees should match total across multiple batches"
        );
    }

    /// @notice Test fee accounting with multiple bundles in a single batch
    function test_processLogs_feeCollection_multipleBundlesInOneBatch() public {
        uint256 fee = 0.002 ether;
        vm.prank(owner);
        gwAssetTracker.setGatewaySettlementFee(fee);

        address payer = makeAddr("multiBundlePayer");

        vm.prank(payer);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID);

        wrappedZKToken.mint(payer, 100 ether);
        vm.prank(payer);
        wrappedZKToken.approve(address(gwAssetTracker), type(uint256).max);

        // 3 bundles in one batch: 2 calls + 4 calls + 1 call = 7 total
        uint256[] memory callsPerBundle = new uint256[](3);
        callsPerBundle[0] = 2;
        callsPerBundle[1] = 4;
        callsPerBundle[2] = 1;
        uint256 totalCalls = 7;
        uint256 expectedFee = fee * totalCalls; // 0.002 * 7 = 0.014 ether

        uint256 payerBalanceBefore = wrappedZKToken.balanceOf(payer);

        // Build input first, then set expectEmit right before the call
        ProcessLogsInput memory input = _buildInteropBundlesInput(3, callsPerBundle, payer, 1);

        vm.expectEmit(true, true, false, true);
        emit GatewaySettlementFeesCollected(CHAIN_ID, payer, expectedFee, totalCalls);

        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);

        assertEq(
            wrappedZKToken.balanceOf(payer),
            payerBalanceBefore - expectedFee,
            "Fee should reflect total calls across all bundles"
        );
    }

    /// @notice Test mixed interop and non-interop logs - only interop logs incur fees
    function test_processLogs_feeCollection_mixedInteropAndNonInteropLogs() public {
        uint256 fee = 0.01 ether;
        vm.prank(owner);
        gwAssetTracker.setGatewaySettlementFee(fee);

        address payer = makeAddr("mixedPayer");

        vm.prank(payer);
        gwAssetTracker.agreeToPaySettlementFees(CHAIN_ID);

        wrappedZKToken.mint(payer, 100 ether);
        vm.prank(payer);
        wrappedZKToken.approve(address(gwAssetTracker), type(uint256).max);

        // Create one interop bundle with 3 calls AND one non-interop log (compressor)
        InteropBundle memory bundle = ProcessLogsTestHelper.createSimpleInteropBundle(
            CHAIN_ID,
            DESTINATION_CHAIN_ID,
            3,
            keccak256("mixedSalt")
        );
        bytes memory interopMessage = ProcessLogsTestHelper.encodeInteropCenterMessage(bundle);
        bytes memory compressorMessage = bytes("compressorMsg");

        L2Log[] memory logs = new L2Log[](2);
        // Interop center log
        logs[0] = ProcessLogsTestHelper.createInteropCenterLog(0, interopMessage);
        // Compressor log (no fee impact)
        logs[1] = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: 1,
            sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            key: bytes32(uint256(uint160(L2_COMPRESSOR_ADDR))),
            value: keccak256(compressorMessage)
        });

        bytes[] memory messages = new bytes[](2);
        messages[0] = interopMessage;
        messages[1] = compressorMessage;

        ProcessLogsInput memory input = ProcessLogsTestHelper.buildProcessLogsInput(
            gwAssetTracker,
            CHAIN_ID,
            1,
            logs,
            messages,
            payer
        );

        uint256 expectedFee = fee * 3; // Only the 3 interop calls count
        uint256 payerBalanceBefore = wrappedZKToken.balanceOf(payer);

        vm.expectEmit(true, true, false, true);
        emit GatewaySettlementFeesCollected(CHAIN_ID, payer, expectedFee, 3);

        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);

        assertEq(
            wrappedZKToken.balanceOf(payer),
            payerBalanceBefore - expectedFee,
            "Only interop calls should incur fees, not compressor logs"
        );
    }
}
