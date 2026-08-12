// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2BaseTokenZKOS} from "contracts/l2-system/zksync-os/L2BaseTokenZKOS.sol";
import {IL2BaseTokenBase} from "contracts/l2-system/interfaces/IL2BaseTokenBase.sol";
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
import {INITIAL_BASE_TOKEN_HOLDER_BALANCE} from "contracts/common/Config.sol";
import {
    BaseTokenHolderAlreadyInitialized,
    BaseTokenHolderMintFailed,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";
import {BaseTokenHolder} from "contracts/l2-system/BaseTokenHolder.sol";
import {DummyL2AssetTracker} from "contracts/dev-contracts/test/DummyL2AssetTracker.sol";
import {DummyL2L1Messenger} from "contracts/dev-contracts/test/DummyL2L1Messenger.sol";
import {DummyL2BaseTokenHolder} from "contracts/dev-contracts/test/DummyL2BaseTokenHolder.sol";

/// @dev Harness exposing a setter for the slot that v31's backfill service transaction
/// (removed in this release) used to write, so an upgraded chain's pre-populated state can be
/// simulated without storage cheatcodes.
contract L2BaseTokenZKOSHarness is L2BaseTokenZKOS {
    function harnessSetZkosPreV31TotalSupply(uint256 _totalSupply) external {
        zkosPreV31TotalSupply = _totalSupply;
    }
}

/// @title L2BaseTokenZKOSTest
/// @notice Unit tests for L2BaseTokenZKOS (init, totalSupply).
/// See {protocol-docs/bridging.md#l2-asset-tracker}.
contract L2BaseTokenZKOSTest is Test {
    L2BaseTokenZKOS internal l2BaseToken;

    function setUp() public {
        l2BaseToken = new L2BaseTokenZKOS();

        // Deploy dummy dependencies at system addresses (replaces broad vm.mockCall)
        vm.etch(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, address(new DummyL2L1Messenger()).code);

        // Deploy dummy BaseTokenHolder that accepts ETH from any sender.
        // Tests that need real access-control checks etch the real BaseTokenHolder instead.
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new DummyL2BaseTokenHolder()).code);

        // The real BaseTokenHolder reports bridge flows to the vault; a recording mock stands in.
        vm.etch(
            L2_ASSET_TRACKER_ADDR,
            address(new DummyL2AssetTracker(address(0), DummyL2AssetTracker.RecordMode.None)).code
        );
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

    /// @notice Verifies that BaseTokenHolder reports InteropCenter bridging burns to the tracker.
    function test_baseTokenHolder_reportsInteropCenterBurnToTracker() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 burnAmount = 1 ether;

        // InteropCenter calls burnAndStartBridging (simulating a bridging burn).
        vm.deal(L2_INTEROP_CENTER_ADDR, burnAmount);
        vm.prank(L2_INTEROP_CENTER_ADDR);
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: burnAmount}(1);

        DummyL2AssetTracker tracker = DummyL2AssetTracker(L2_ASSET_TRACKER_ADDR);
        assertEq(tracker.toChainCalls(), 1);
        assertEq(tracker.recordedToChainId(), 1);
        assertEq(tracker.recordedToAmount(), burnAmount);
    }

    /// @notice Verifies that BaseTokenHolder reports nothing on initialization receive().
    /// @dev L2BaseToken sends via receive() during initialization, which is not a bridging operation
    function test_baseTokenHolder_doesNotReportReceiveFromL2BaseToken() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 initAmount = 1 ether;

        // L2BaseToken sends ETH to BaseTokenHolder via receive() (during initialization)
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, initAmount);
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        (bool success, ) = L2_BASE_TOKEN_HOLDER_ADDR.call{value: initAmount}("");
        assertTrue(success, "Transfer should succeed");

        DummyL2AssetTracker tracker = DummyL2AssetTracker(L2_ASSET_TRACKER_ADDR);
        assertEq(tracker.toChainCalls(), 0, "initialization receive must not be reported as an outbound flow");
        assertEq(tracker.fromChainCalls(), 0, "initialization receive must not be reported as an inbound flow");
    }

    /// @notice Verifies that initL2 does not record a bridge operation: the initialization
    /// transfer goes through the real holder's neutral receive() path, so the recording vault
    /// must observe no flow in either direction.
    function test_initL2_doesNotRecordBridgeOperation() public {
        // Deploy L2BaseTokenZKOS at the expected system contract address and the REAL holder,
        // so a regression routing the initialization through a bookkeeping entry point is caught.
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);

        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // Call initL2
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initL2(1);

        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            INITIAL_BASE_TOKEN_HOLDER_BALANCE,
            "BaseTokenHolder should have received initial balance"
        );
        DummyL2AssetTracker tracker = DummyL2AssetTracker(L2_ASSET_TRACKER_ADDR);
        assertEq(tracker.toChainCalls(), 0, "initL2 must not be reported as an outbound flow");
        assertEq(tracker.fromChainCalls(), 0, "initL2 must not be reported as an inbound flow");
    }

    /*//////////////////////////////////////////////////////////////
                        totalSupply() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_totalSupply_zeroForFreshChain() public {
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        // Deploy BaseTokenHolder so holder balance is known
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, hex"00");
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // On a fresh chain zkosPreV31TotalSupply is zero: totalSupply = 0 + (INITIAL - INITIAL) = 0
        assertEq(
            L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).totalSupply(),
            0,
            "totalSupply should be 0 when preV31Supply is 0 and holder has initial balance"
        );
    }

    /// @dev Simulates an upgraded chain whose `zkosPreV31TotalSupply` slot was backfilled while it
    /// ran v31, plus post-upgrade mints (a holder balance below the initial value means
    /// minted supply).
    function test_totalSupply_addsPreV31SupplyToMintedDelta() public {
        L2BaseTokenZKOSHarness harness = new L2BaseTokenZKOSHarness();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(harness).code);
        L2BaseTokenZKOSHarness token = L2BaseTokenZKOSHarness(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        token.harnessSetZkosPreV31TotalSupply(200);

        // 100 wei were minted after the upgrade: the holder balance is below the initial value.
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new DummyL2BaseTokenHolder()).code);
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE - 100);

        // totalSupply = preV31Supply + INITIAL - holder.balance = 200 + 100 = 300
        assertEq(token.totalSupply(), 300, "totalSupply returns wrong value");
    }

    /// @dev An upgraded chain can be in a net-burn state: withdrawals move value INTO the holder,
    /// so its balance can exceed the initial value by up to the pre-v31 circulating supply.
    /// totalSupply() must not revert there. The burn goes through a real withdrawal.
    function test_totalSupply_supportsNetBurnOfPreV31Supply() public {
        L2BaseTokenZKOSHarness harness = new L2BaseTokenZKOSHarness();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(harness).code);
        L2BaseTokenZKOSHarness token = L2BaseTokenZKOSHarness(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        token.harnessSetZkosPreV31TotalSupply(200);

        // Post-upgrade steady state: the holder holds exactly the initial balance. The real holder
        // is used so the bridging call below goes through its actual access control.
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // A holder of pre-v31 supply bridges 150 wei out to L1: the value flows into the holder.
        // Upstream (#2364) drove this through `L2BaseToken.withdraw()`, which this release removed
        // with the rest of the legacy withdrawal path; base-token exits now go through the
        // InteropCenter, which is the caller the holder still accepts.
        vm.deal(L2_INTEROP_CENTER_ADDR, 150);
        vm.prank(L2_INTEROP_CENTER_ADDR);
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: 150}(1);

        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            INITIAL_BASE_TOKEN_HOLDER_BALANCE + 150,
            "the bridged-out value must flow into the holder"
        );
        // totalSupply = preV31Supply + INITIAL - holder.balance = 200 - 150 = 50
        assertEq(token.totalSupply(), 50, "net-burn state should decrease totalSupply without reverting");
    }

    /// @dev Simulates a v31 chain (slot 50 already backfilled) going through this release's
    /// initL2: the historical value must survive and feed totalSupply().
    function test_initL2_preservesBackfilledPreV31Supply() public {
        L2BaseTokenZKOSHarness harness = new L2BaseTokenZKOSHarness();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(harness).code);
        L2BaseTokenZKOSHarness token = L2BaseTokenZKOSHarness(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        token.harnessSetZkosPreV31TotalSupply(200);

        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        token.initL2(1);

        assertEq(token.zkosPreV31TotalSupply(), 200, "initL2 must not touch the backfilled slot");
        // Holder now holds exactly the initial balance, so totalSupply() equals the pre-v31 value.
        assertEq(token.totalSupply(), 200, "totalSupply must keep the pre-v31 baseline after initL2");
    }

    /// @dev Pins `zkosPreV31TotalSupply` to storage slot 50: the value is written by v31's
    /// backfill service transaction, and this release (which removes the backfill path) must keep
    /// reading the exact same slot. The write goes through a derived-contract setter, the read
    /// through the raw slot.
    function test_zkosPreV31TotalSupply_stableStorageSlot() public {
        L2BaseTokenZKOSHarness harness = new L2BaseTokenZKOSHarness();
        harness.harnessSetZkosPreV31TotalSupply(31337);

        assertEq(
            uint256(vm.load(address(harness), bytes32(uint256(50)))),
            31337,
            "zkosPreV31TotalSupply must stay at slot 50 (populated on v31)"
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
