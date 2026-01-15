// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";

import {GWAssetTracker} from "contracts/bridge/asset-tracker/GWAssetTracker.sol";
import {IGWAssetTracker} from "contracts/bridge/asset-tracker/IGWAssetTracker.sol";
import {L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_INTEROP_CENTER_ADDR, L2_MESSAGE_ROOT_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {IChainAssetHandler} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {InvalidFeeRecipient, SettlementFeePayerNotAgreed} from "contracts/bridge/asset-tracker/AssetTrackerErrors.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

contract GWAssetTrackerFeesTest is Test {
    GWAssetTracker public gwAssetTracker;
    TestnetERC20Token public wrappedZKToken;

    address public owner;
    address public mockBridgehub;
    address public mockMessageRoot;
    address public mockNativeTokenVault;
    address public mockChainAssetHandler;

    uint256 public constant L1_CHAIN_ID = 1;
    uint256 public constant CHAIN_ID = 270;
    uint256 public constant OTHER_CHAIN_ID = 271;

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

        // Deploy GWAssetTracker
        gwAssetTracker = new GWAssetTracker();
        owner = gwAssetTracker.owner();

        // Create mock addresses
        mockBridgehub = makeAddr("mockBridgehub");
        mockMessageRoot = makeAddr("mockMessageRoot");
        mockNativeTokenVault = makeAddr("mockNativeTokenVault");
        mockChainAssetHandler = makeAddr("mockChainAssetHandler");

        // Mock the L2 contract addresses
        vm.etch(L2_BRIDGEHUB_ADDR, address(mockBridgehub).code);
        vm.etch(L2_MESSAGE_ROOT_ADDR, address(mockMessageRoot).code);
        vm.etch(L2_NATIVE_TOKEN_VAULT_ADDR, address(mockNativeTokenVault).code);
        vm.etch(L2_CHAIN_ASSET_HANDLER_ADDR, address(mockChainAssetHandler).code);

        // Mock the WETH_TOKEN() call on NativeTokenVault to return our test token
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(IL2NativeTokenVault.WETH_TOKEN.selector),
            abi.encode(address(wrappedZKToken))
        );

        // Set up the contract
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.setAddresses(L1_CHAIN_ID);

        vm.mockCall(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector),
            abi.encode(1)
        );
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
}
