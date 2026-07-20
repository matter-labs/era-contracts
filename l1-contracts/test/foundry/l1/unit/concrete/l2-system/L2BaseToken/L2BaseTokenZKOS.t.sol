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
/// @notice Unit tests for L2BaseTokenZKOS (init, pre-V31 total-supply backfill, totalSupply).
/// See {protocol-docs/bridging.md}.
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
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        // The mocked mint hook does not actually mint, so fund the contract manually.
        vm.deal(address(l2BaseToken), INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        uint256 holderBalanceBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initL2(1);

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
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        vm.deal(address(l2BaseToken), INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initL2(1);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(BaseTokenHolderAlreadyInitialized.selector);
        l2BaseToken.initL2(1);
    }

    function test_initL2_revertIfMintFails() public {
        vm.mockCallRevert(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), "Mint failed");

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(BaseTokenHolderMintFailed.selector);
        l2BaseToken.initL2(1);
    }

    function test_initL2_revertIfTransferFails() public {
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        vm.deal(address(l2BaseToken), INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        RejectingContract rejecting = new RejectingContract();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(rejecting).code);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert("Address: unable to send value, recipient may have reverted");
        l2BaseToken.initL2(1);
    }

    /// @notice initL2 works against the real BaseTokenHolder: L2BaseToken must be a trusted sender.
    function test_initL2_withActualBaseTokenHolder() public {
        // Deploy real BaseTokenHolder for this integration test
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);

        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        // The mocked mint hook does not actually mint, so fund the contract manually.
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initL2(1);

        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            INITIAL_BASE_TOKEN_HOLDER_BALANCE,
            "BaseTokenHolder should receive initial balance from L2BaseToken"
        );
    }

    /// @notice BaseTokenHolder rejects receive() from untrusted senders.
    function test_baseTokenHolder_rejectsUntrustedSenders_receive() public {
        // Deploy real BaseTokenHolder for access-control tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        address untrustedSender = makeAddr("untrustedSender");
        vm.deal(untrustedSender, 1 ether);

        vm.prank(untrustedSender);
        (bool success, ) = L2_BASE_TOKEN_HOLDER_ADDR.call{value: 1 ether}("");
        assertFalse(success, "Transfer should fail from untrusted sender");
    }

    /// @notice BaseTokenHolder rejects burnAndStartBridging from non-bridging callers.
    function test_baseTokenHolder_rejectsUntrustedSenders_burnAndStartBridging() public {
        // Deploy real BaseTokenHolder for access-control tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        address untrustedSender = makeAddr("untrustedSender");
        vm.deal(untrustedSender, 1 ether);

        vm.prank(untrustedSender);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, untrustedSender));
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: 1 ether}(0);
    }

    /// @notice burnAndStartBridging from the InteropCenter notifies the L2AssetTracker.
    function test_baseTokenHolder_notifiesAssetTrackerOnBridging() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 burnAmount = 1 ether;

        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256,uint256)", 0, burnAmount)
        );

        vm.deal(L2_INTEROP_CENTER_ADDR, burnAmount);
        vm.prank(L2_INTEROP_CENTER_ADDR);
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: burnAmount}(0);
    }

    /// @notice burnAndStartBridging from the NativeTokenVault notifies the L2AssetTracker.
    function test_baseTokenHolder_notifiesAssetTrackerFromNTV() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 burnAmount = 2 ether;

        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256,uint256)", 0, burnAmount)
        );

        vm.deal(L2_NATIVE_TOKEN_VAULT_ADDR, burnAmount);
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: burnAmount}(0);
    }

    /// @notice L2BaseToken is NOT a bridging caller: base-token withdrawals go through the InteropCenter.
    function test_baseTokenHolder_revertsFromL2BaseToken_burnAndStartBridging() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 burnAmount = 1 ether;

        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, burnAmount);
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR));
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: burnAmount}(0);
    }

    /// @notice receive() from L2BaseToken (the init path, not a bridging operation) must NOT notify
    /// the L2AssetTracker.
    function test_baseTokenHolder_doesNotNotifyAssetTrackerFromL2BaseToken() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 initAmount = 1 ether;

        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256,uint256)", 0, initAmount),
            0 // count = 0 means we expect it NOT to be called
        );

        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, initAmount);
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        (bool success, ) = L2_BASE_TOKEN_HOLDER_ADDR.call{value: initAmount}("");
        assertTrue(success, "Transfer should succeed");
    }

    /// @notice The full initL2 flow must NOT notify the L2AssetTracker.
    function test_initL2_doesNotTriggerAssetTracker() public {
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature(
                "handleInitiateBaseTokenBridgingOnL2(uint256,uint256)",
                0,
                INITIAL_BASE_TOKEN_HOLDER_BALANCE
            ),
            0 // count = 0 means we expect it NOT to be called
        );

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initL2(1);

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

        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IL2AssetTracker.backFillZKSyncOSBaseTokenV31MigrationData.selector, totalSupply)
        );

        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2BaseToken.setZKsyncOSPreV31TotalSupply(totalSupply);
    }

    function test_setZkosPreV31TotalSupply_revertsOnSecondCall() public {
        uint256 totalSupply = 42 ether;

        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2BaseToken.setZKsyncOSPreV31TotalSupply(totalSupply);

        vm.prank(SERVICE_TRANSACTION_SENDER);
        vm.expectRevert(BaseTokenPreV31TotalSupplyAlreadySet.selector);
        l2BaseToken.setZKsyncOSPreV31TotalSupply(totalSupply);
    }

    /*//////////////////////////////////////////////////////////////
                        totalSupply() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_totalSupply_revertsWhenBackfillNeeded() public {
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        vm.mockCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSelector(IL2AssetTracker.needBaseTokenTotalSupplyBackfill.selector),
            abi.encode(true)
        );

        vm.expectRevert(BaseTokenPreV31TotalSupplyNotSet.selector);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).totalSupply();
    }

    function test_totalSupply_worksWhenBackfillNotNeeded() public {
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        // Deploy BaseTokenHolder so holder balance is known
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, hex"00");
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // Without setting preV31Supply, totalSupply = 0 + (INITIAL - INITIAL) = 0
        assertEq(
            L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).totalSupply(),
            0,
            "totalSupply should be 0 when preV31Supply is 0 and holder has initial balance"
        );
    }

    function test_totalSupply_worksWhenBaseTokenHolderBalanceGreaterThanInitial() public {
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        // Deploy BaseTokenHolder so holder balance is known
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, hex"00");
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE + 100);

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
