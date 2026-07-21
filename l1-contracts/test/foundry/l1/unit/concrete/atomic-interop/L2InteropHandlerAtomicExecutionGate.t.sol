// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2InteropHandler} from "contracts/interop/interop-handler/L2InteropHandler.sol";
import {IInteropHandlerBase} from "contracts/interop/interop-handler/IInteropHandlerBase.sol";
import {IAtomicFlowManager} from "contracts/atomic-interop/IAtomicFlowManager.sol";
import {AtomicFinalityProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {ExecutingNotAllowed} from "contracts/interop/InteropErrors.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {
    BundleAttributes,
    BundleStatus,
    InteropBundle,
    InteropCall,
    INTEROP_BUNDLE_VERSION
} from "contracts/common/Messaging.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2_NATIVE_TOKEN_VAULT} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

/// @notice Pins the `executeAtomicBundle` execution-address permission gate — the destination-side
/// contract that `InteropCenter._validateAtomicBundle`'s send-side reachability check mirrors. The two
/// checks must stay consistent: every `executionAddress` shape the send side admits must be executable
/// here, and every shape it rejects must indeed be dead on arrival. Each admitted/rejected encoding is
/// exercised through the real handler so a change to either side breaks a test instead of silently
/// re-opening the stranded-funds footgun.
///
/// Deliberately mocked (this test isolates the permission gate):
///   - `AtomicFlowManager.requireFlowFinalized` (the atomicity gate) — its proof verification is
///     separately covered by AtomicInteropProof.t.sol and AtomicFlowManagerMaxLegsFinalize.t.sol; here
///     it is driven to success so execution reaches (and is decided by) the permission gate alone.
///   - `L2_NATIVE_TOKEN_VAULT.BASE_TOKEN_ASSET_ID` — destination-context plumbing, not under test.
/// The bundle carries zero calls, so a successful execution has no call side effects and the observable
/// outcome is exactly the gate's verdict: `BundleExecuted` + `FullyExecuted`, or `ExecutingNotAllowed`.
contract L2InteropHandlerAtomicExecutionGateTest is Test {
    uint256 internal constant SOURCE_CHAIN_ID = 777;
    bytes32 internal constant BASE_TOKEN_ASSET_ID = keccak256("destination base token asset id");

    L2InteropHandler internal handler;
    address internal executor;
    AtomicFinalityProof internal emptyFinality;

    function setUp() public {
        handler = new L2InteropHandler();
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        handler.initL2();
        executor = makeAddr("atomic executor");

        // Destination-context plumbing: the handler compares the bundle's destination base token asset
        // id against the local NTV's. Give the canonical NTV address code so the call can be mocked.
        vm.etch(address(L2_NATIVE_TOKEN_VAULT), hex"00");
        vm.mockCall(
            address(L2_NATIVE_TOKEN_VAULT),
            abi.encodeWithSelector(L2_NATIVE_TOKEN_VAULT.BASE_TOKEN_ASSET_ID.selector),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );
        // Atomicity gate: driven to success so the permission gate decides the outcome.
        vm.etch(L2_ATOMIC_FLOW_MANAGER_ADDR, hex"00");
        vm.mockCall(
            L2_ATOMIC_FLOW_MANAGER_ADDR,
            abi.encodeWithSelector(IAtomicFlowManager.requireFlowFinalized.selector),
            abi.encode()
        );
    }

    /// @dev A minimal zero-call atomic bundle destined for this chain, pinned to `_executionAddress`.
    /// The salt is derived from the execution address so every variant gets a unique bundle hash.
    function _atomicBundle(
        bytes memory _executionAddress
    ) internal view returns (bytes memory bundleBytes, bytes32 bundleHash) {
        InteropBundle memory bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: SOURCE_CHAIN_ID,
            destinationChainId: block.chainid,
            destinationBaseTokenAssetId: BASE_TOKEN_ASSET_ID,
            interopBundleSalt: keccak256(abi.encodePacked("gate salt", _executionAddress)),
            calls: new InteropCall[](0),
            bundleAttributes: BundleAttributes({
                executionAddress: _executionAddress,
                unbundlerAddress: bytes(""),
                useFixedFee: false,
                salt: bytes32(0)
            })
        });
        bundleBytes = abi.encode(bundle);
        bundleHash = InteropDataEncoding.encodeInteropBundleHash(SOURCE_CHAIN_ID, bundleBytes);
    }

    function _assertExecutes(bytes memory _executionAddress, address _caller) internal {
        (bytes memory bundleBytes, bytes32 bundleHash) = _atomicBundle(_executionAddress);
        // The atomicity gate must actually be consulted before execution.
        vm.expectCall(
            L2_ATOMIC_FLOW_MANAGER_ADDR,
            abi.encodeWithSelector(IAtomicFlowManager.requireFlowFinalized.selector, bundleHash, emptyFinality)
        );
        vm.expectEmit(address(handler));
        emit IInteropHandlerBase.BundleExecuted(bundleHash);
        vm.prank(_caller);
        handler.executeAtomicBundle(bundleBytes, emptyFinality);
        assertEq(
            uint256(handler.bundleStatus(bundleHash)),
            uint256(BundleStatus.FullyExecuted),
            "admitted executor must fully execute the bundle"
        );
    }

    function _assertRejected(bytes memory _executionAddress, address _caller) internal {
        (bytes memory bundleBytes, bytes32 bundleHash) = _atomicBundle(_executionAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutingNotAllowed.selector,
                bundleHash,
                InteroperableAddress.formatEvmV1(block.chainid, _caller),
                _executionAddress
            )
        );
        vm.prank(_caller);
        handler.executeAtomicBundle(bundleBytes, emptyFinality);
        assertEq(
            uint256(handler.bundleStatus(bundleHash)),
            uint256(BundleStatus.Unreceived),
            "rejected execution must leave the bundle untouched"
        );
    }

    /// @notice A destination-pinned executor is admitted — the send side allows this encoding.
    function test_executeAtomicBundle_AdmitsDestinationPinnedExecutor() public {
        _assertExecutes(InteroperableAddress.formatEvmV1(block.chainid, executor), executor);
    }

    /// @notice A chain-agnostic executor (empty chain reference, chain id 0) is admitted — the send
    /// side allows this encoding.
    function test_executeAtomicBundle_AdmitsChainAgnosticExecutor() public {
        _assertExecutes(InteroperableAddress.formatEvmV1(executor), executor);
    }

    /// @notice An executor pinned to another chain is rejected even for the pinned address itself —
    /// the reason `InteropCenter._validateAtomicBundle` blocks such sends: with no atomic relay path,
    /// nobody can ever pass this gate.
    function test_executeAtomicBundle_RejectsForeignChainExecutor() public {
        _assertRejected(InteroperableAddress.formatEvmV1(block.chainid + 1, executor), executor);
    }

    /// @notice A chain-only encoding (address parses to `address(0)`) admits no caller — the reason
    /// the send side rejects zero executors: `msg.sender` can never be `address(0)`.
    function test_executeAtomicBundle_RejectsChainOnlyExecutionAddress() public {
        _assertRejected(InteroperableAddress.formatEvmV1(block.chainid), executor);
    }

    /// @notice An executor pinned to the destination admits only that address; any other caller is
    /// rejected.
    function test_executeAtomicBundle_RejectsNonPinnedCaller() public {
        _assertRejected(InteroperableAddress.formatEvmV1(block.chainid, executor), makeAddr("someone else"));
    }
}
