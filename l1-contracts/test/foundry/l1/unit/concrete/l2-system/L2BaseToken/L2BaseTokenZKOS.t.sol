// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2BaseTokenZKOS} from "contracts/l2-system/zksync-os/L2BaseTokenZKOS.sol";
import {IL2BaseTokenBase} from "contracts/l2-system/interfaces/IL2BaseTokenBase.sol";
import {IL2BaseTokenZKOS} from "contracts/l2-system/zksync-os/interfaces/IL2BaseTokenZKOS.sol";
import {
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
    MINT_BASE_TOKEN_HOOK
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2_BASE_TOKEN_HOLDER} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {INITIAL_BASE_TOKEN_HOLDER_BALANCE, SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";
import {
    BaseTokenHolderAlreadyInitialized,
    BaseTokenHolderMintFailed,
    BaseTokenPreV31TotalSupplyAlreadySet,
    BaseTokenPreV31TotalSupplyNotSet,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";
import {IL2AssetTracker} from "contracts/bridge/asset-tracker/IL2AssetTracker.sol";
import {BaseTokenHolder} from "contracts/l2-system/BaseTokenHolder.sol";
import {DummyL2AssetTracker} from "contracts/dev-contracts/test/DummyL2AssetTracker.sol";
import {DummyL2L1Messenger} from "contracts/dev-contracts/test/DummyL2L1Messenger.sol";
import {DummyL2BaseTokenHolder} from "contracts/dev-contracts/test/DummyL2BaseTokenHolder.sol";

/// @title L2BaseTokenZKOSTest
/// @notice Unit tests for L2BaseTokenZKOS contract
contract L2BaseTokenZKOSTest is Test {
    L2BaseTokenZKOS internal l2BaseToken;

    function setUp() public {
        l2BaseToken = new L2BaseTokenZKOS();

        // Deploy dummy dependencies at system addresses (replaces broad vm.mockCall)
        vm.etch(
            L2_ASSET_TRACKER_ADDR,
            address(new DummyL2AssetTracker(address(0), DummyL2AssetTracker.RecordMode.None)).code
        );
        vm.etch(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, address(new DummyL2L1Messenger()).code);

        // Deploy dummy BaseTokenHolder that accepts ETH from any sender.
        // Tests that need real access-control checks etch the real BaseTokenHolder instead.
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new DummyL2BaseTokenHolder()).code);
    }

    /*//////////////////////////////////////////////////////////////
                    initL2() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_initL2_success() public {
        // Mock the mint hook to succeed
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        // Give the L2BaseToken contract the minted balance (simulating what mint hook does)
        vm.deal(address(l2BaseToken), INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        uint256 holderBalanceBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        // Call from ComplexUpgrader
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initL2(1);

        // Verify BaseTokenHolder received the tokens
        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            holderBalanceBefore + INITIAL_BASE_TOKEN_HOLDER_BALANCE,
            "BaseTokenHolder should receive initial balance"
        );
    }

    function test_initL2_revertIfNotComplexUpgrader() public {
        address nonUpgrader = makeAddr("nonUpgrader");

        vm.prank(nonUpgrader);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonUpgrader));
        l2BaseToken.initL2(1);
    }

    function test_initL2_revertsOnSecondCall() public {
        // Mock the mint hook to succeed
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        // Give the L2BaseToken contract the minted balance
        vm.deal(address(l2BaseToken), INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // First call succeeds
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initL2(1);

        // Second call reverts with BaseTokenHolderAlreadyInitialized
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(BaseTokenHolderAlreadyInitialized.selector);
        l2BaseToken.initL2(1);
    }

    function test_initL2_revertIfMintFails() public {
        // Mock the mint hook to fail
        vm.mockCallRevert(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), "Mint failed");

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(BaseTokenHolderMintFailed.selector);
        l2BaseToken.initL2(1);
    }

    function test_initL2_revertIfTransferFails() public {
        // Mock the mint hook to succeed
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        // Give the contract some balance but not enough
        vm.deal(address(l2BaseToken), INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // Make BaseTokenHolder reject transfers
        RejectingContract rejecting = new RejectingContract();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(rejecting).code);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert("Address: unable to send value, recipient may have reverted");
        l2BaseToken.initL2(1);
    }

    /// @notice Verifies that initL2 works with actual BaseTokenHolder
    /// @dev This test ensures L2BaseToken is in the trusted sender list of BaseTokenHolder
    /// @dev CRITICAL: This test validates that BaseTokenHolder can receive ETH from L2BaseToken
    function test_initL2_withActualBaseTokenHolder() public {
        // Deploy real BaseTokenHolder for this integration test
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);

        // Deploy L2BaseTokenZKOS at the expected system contract address
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        // Mock the mint hook to succeed
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        // Give the L2BaseToken contract the minted balance (simulating what mint hook does)
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // Call from ComplexUpgrader - this should succeed because L2BaseToken is a trusted sender
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initL2(1);

        // Verify BaseTokenHolder received the tokens
        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            INITIAL_BASE_TOKEN_HOLDER_BALANCE,
            "BaseTokenHolder should receive initial balance from L2BaseToken"
        );
    }

    /// @notice Verifies that BaseTokenHolder rejects ETH from untrusted senders via receive()
    /// @dev This test ensures that only L2BaseToken can send ETH via receive()
    function test_baseTokenHolder_rejectsUntrustedSenders_receive() public {
        // Deploy real BaseTokenHolder for access-control tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        // Try to send ETH from an untrusted address via receive()
        address untrustedSender = makeAddr("untrustedSender");
        vm.deal(untrustedSender, 1 ether);

        vm.prank(untrustedSender);
        (bool success, ) = L2_BASE_TOKEN_HOLDER_ADDR.call{value: 1 ether}("");
        assertFalse(success, "Transfer should fail from untrusted sender");
    }

    /// @notice Verifies that BaseTokenHolder rejects burnAndStartBridging from untrusted senders
    /// @dev This test ensures that only bridging callers can use burnAndStartBridging
    function test_baseTokenHolder_rejectsUntrustedSenders_burnAndStartBridging() public {
        // Deploy real BaseTokenHolder for access-control tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        // Try to call burnAndStartBridging from an untrusted address
        address untrustedSender = makeAddr("untrustedSender");
        vm.deal(untrustedSender, 1 ether);

        vm.prank(untrustedSender);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, untrustedSender));
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: 1 ether}(0);
    }

    /// @notice Verifies that BaseTokenHolder notifies L2AssetTracker when receiving ETH via burnAndStartBridging from InteropCenter
    /// @dev This test ensures bridging operations are properly tracked
    function test_baseTokenHolder_notifiesAssetTrackerOnBridging() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 burnAmount = 1 ether;

        // Expect the AssetTracker call when InteropCenter calls burnAndStartBridging
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256,uint256)", 0, burnAmount)
        );

        // InteropCenter calls burnAndStartBridging (simulating a bridging burn)
        vm.deal(L2_INTEROP_CENTER_ADDR, burnAmount);
        vm.prank(L2_INTEROP_CENTER_ADDR);
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: burnAmount}(0);
    }

    /// @notice Verifies that BaseTokenHolder notifies L2AssetTracker when receiving ETH via burnAndStartBridging from NativeTokenVault
    /// @dev This test ensures bridging operations are properly tracked
    function test_baseTokenHolder_notifiesAssetTrackerFromNTV() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 burnAmount = 2 ether;

        // Expect the AssetTracker call when NativeTokenVault calls burnAndStartBridging
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256,uint256)", 0, burnAmount)
        );

        // NativeTokenVault calls burnAndStartBridging (simulating a bridging burn)
        vm.deal(L2_NATIVE_TOKEN_VAULT_ADDR, burnAmount);
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: burnAmount}(0);
    }

    /// @notice Verifies that L2BaseToken is NOT a bridging caller for burnAndStartBridging.
    /// @dev Base-token withdrawals go through the InteropCenter (which burns the value via
    /// burnAndStartBridging), so L2BaseToken calling it directly must revert.
    function test_baseTokenHolder_revertsFromL2BaseToken_burnAndStartBridging() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 burnAmount = 1 ether;

        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, burnAmount);
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR));
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: burnAmount}(0);
    }

    /// @notice Verifies that BaseTokenHolder does NOT notify L2AssetTracker when receiving ETH via receive() from L2BaseToken
    /// @dev L2BaseToken sends via receive() during initialization, which is not a bridging operation
    function test_baseTokenHolder_doesNotNotifyAssetTrackerFromL2BaseToken() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 initAmount = 1 ether;

        // Expect the AssetTracker to NOT be called (count = 0)
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256,uint256)", 0, initAmount),
            0 // count = 0 means we expect it NOT to be called
        );

        // L2BaseToken sends ETH to BaseTokenHolder via receive() (during initialization)
        // We should NOT see a call to L2AssetTracker
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, initAmount);
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        (bool success, ) = L2_BASE_TOKEN_HOLDER_ADDR.call{value: initAmount}("");
        assertTrue(success, "Transfer should succeed");
    }

    /// @notice Verifies that initL2 does NOT trigger L2AssetTracker
    /// @dev This tests the full initialization flow to ensure asset tracker is not notified
    function test_initL2_doesNotTriggerAssetTracker() public {
        // Deploy L2BaseTokenZKOS at the expected system contract address
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        // Mock the mint hook to succeed
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        // Give the L2BaseToken contract the minted balance
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // Expect the AssetTracker to NOT be called during initialization
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature(
                "handleInitiateBaseTokenBridgingOnL2(uint256,uint256)",
                0,
                INITIAL_BASE_TOKEN_HOLDER_BALANCE
            ),
            0 // count = 0 means we expect it NOT to be called
        );

        // Call initL2
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initL2(1);

        // Verify BaseTokenHolder received the initial balance
        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            INITIAL_BASE_TOKEN_HOLDER_BALANCE,
            "BaseTokenHolder should have received initial balance"
        );
    }

    /*//////////////////////////////////////////////////////////////
                setZKsyncOSPreV31TotalSupply() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setZkosPreV31TotalSupply_success() public {
        uint256 preV31Supply = 42 ether;

        vm.expectEmit(false, false, false, true);
        emit IL2BaseTokenZKOS.ZKsyncOSPreV31TotalSupplySet(preV31Supply);

        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2BaseToken.setZKsyncOSPreV31TotalSupply(preV31Supply);

        assertEq(l2BaseToken.zkosPreV31TotalSupply(), preV31Supply, "zkosPreV31TotalSupply should be set");
    }

    function test_setZkosPreV31TotalSupply_emitsEvent() public {
        uint256 totalSupply = 42 ether;

        vm.expectEmit(false, false, false, true);
        emit IL2BaseTokenZKOS.ZKsyncOSPreV31TotalSupplySet(totalSupply);

        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2BaseToken.setZKsyncOSPreV31TotalSupply(totalSupply);
    }

    function test_setZkosPreV31TotalSupply_revertIfNotServiceTransactionSender() public {
        address nonServiceSender = makeAddr("nonServiceSender");

        vm.prank(nonServiceSender);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonServiceSender));
        l2BaseToken.setZKsyncOSPreV31TotalSupply(42 ether);
    }

    function test_setZkosPreV31TotalSupply_affectsTotalSupply() public {
        uint256 preV31Supply = 10 ether;

        // Deploy at system address so we can check totalSupply
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        // Deploy BaseTokenHolder so holder balance is known
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, hex"00");
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // Set the pre-V31 total supply
        vm.prank(SERVICE_TRANSACTION_SENDER);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).setZKsyncOSPreV31TotalSupply(preV31Supply);

        // totalSupply = preV31Supply + (INITIAL - holder.balance) = preV31Supply + 0 = preV31Supply
        assertEq(
            L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).totalSupply(),
            preV31Supply,
            "totalSupply should equal preV31Supply when holder balance equals initial"
        );
    }

    function test_setZkosPreV31TotalSupply_callsBackfill() public {
        uint256 totalSupply = 42 ether;

        // Expect the backfill call to L2AssetTracker
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IL2AssetTracker.backFillZKSyncOSBaseTokenV31MigrationData.selector, totalSupply)
        );

        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2BaseToken.setZKsyncOSPreV31TotalSupply(totalSupply);
    }

    function test_setZkosPreV31TotalSupply_revertsOnSecondCall() public {
        uint256 totalSupply = 42 ether;

        // First call succeeds
        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2BaseToken.setZKsyncOSPreV31TotalSupply(totalSupply);

        // Second call reverts with local re-call guard
        vm.prank(SERVICE_TRANSACTION_SENDER);
        vm.expectRevert(BaseTokenPreV31TotalSupplyAlreadySet.selector);
        l2BaseToken.setZKsyncOSPreV31TotalSupply(totalSupply);
    }

    /*//////////////////////////////////////////////////////////////
                        totalSupply() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_totalSupply_revertsWhenBackfillNeeded() public {
        // Deploy at system address
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        // Mock needBaseTokenTotalSupplyBackfill to return true
        vm.mockCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IL2AssetTracker.needBaseTokenTotalSupplyBackfill.selector),
            abi.encode(true)
        );

        vm.expectRevert(BaseTokenPreV31TotalSupplyNotSet.selector);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).totalSupply();
    }

    function test_totalSupply_worksWhenBackfillNotNeeded() public {
        // Deploy at system address
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        // Deploy BaseTokenHolder so holder balance is known
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, hex"00");
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // needBaseTokenTotalSupplyBackfill returns false (from setUp mock)

        // Without setting preV31Supply, totalSupply = 0 + (INITIAL - INITIAL) = 0
        assertEq(
            L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).totalSupply(),
            0,
            "totalSupply should be 0 when preV31Supply is 0 and holder has initial balance"
        );
    }

    function test_totalSupply_worksWhenBaseTokenHolderBalanceGreaterThanInitial() public {
        // Deploy at system address
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        // Deploy BaseTokenHolder so holder balance is known
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, hex"00");
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE + 100);

        // Set the pre-V31 total supply
        vm.prank(SERVICE_TRANSACTION_SENDER);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).setZKsyncOSPreV31TotalSupply(200);

        // totalSupply = preV31Supply + INITIAL - holder.balance = 200 + INITIAL - (INITIAL + 100) = 100
        assertEq(
            L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).totalSupply(),
            100,
            "totalSupply returns wrong value"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        INTERFACE COMPLIANCE
    //////////////////////////////////////////////////////////////*/

    function test_implementsIL2BaseTokenBase() public view {
        // Verify the contract implements the interface
        IL2BaseTokenBase token = IL2BaseTokenBase(address(l2BaseToken));
        assert(address(token) == address(l2BaseToken));
    }
}

/// @notice Helper contract that rejects ETH transfers via receive()
contract RejectingContract {
    receive() external payable {
        revert("Rejected");
    }
}
