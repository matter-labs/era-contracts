// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {IChainRegistrationSender} from "contracts/core/chain-registration/IChainRegistrationSender.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {
    ChainHasNoBatchesInMessageRoot,
    InteropNotEnabled,
    InteropPeerAlreadyAllowed,
    InvalidInteropPeer,
    ZKChainNotRegistered
} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

import {InteropGatingDeployer} from "./_SharedInteropGatingDeployer.t.sol";

import {LogFinder} from "test-utils/LogFinder.sol";
import {NEW_PRIORITY_REQUEST_SIGNATURE} from "test/foundry/TestConstants.sol";

/// @notice The interop gating state of `ChainRegistrationSender` with a real ecosystem. See
/// {protocol-docs/interop-gating.md#interop-peer-whitelist} and {protocol-docs/l1sload.md}.
contract ChainRegistrationSenderTests is InteropGatingDeployer {
    using LogFinder for Vm.Log[];

    uint256 internal constant UNREGISTERED_CHAIN_ID = 123456;

    uint256 internal chainId;
    uint256 internal peerChainId;
    address internal chainAdmin;

    function setUp() public {
        _deployInteropGatingEcosystem();
        chainId = zkChainIds[0];
        peerChainId = zkChainIds[1];
        // The fixture's chains share one admin, which also owns `ChainRegistrationSender`. The chain gets an admin
        // of its own, so the admin paths don't pass as the owner's.
        chainAdmin = _setOwnAdmin(chainId, "chainAdmin");
        assertNotEq(chainAdmin, addresses.chainRegistrationSender.owner());
    }

    function _allowInteropPeer() internal returns (Vm.Log[] memory logs) {
        vm.expectEmit(true, true, false, true, address(addresses.chainRegistrationSender));
        emit IChainRegistrationSender.InteropPeerAllowed(chainId, peerChainId);
        vm.recordLogs();
        vm.prank(chainAdmin);
        addresses.chainRegistrationSender.allowInteropPeer(chainId, peerChainId);
        logs = vm.getRecordedLogs();
        assertTrue(addresses.chainRegistrationSender.interopPeerAllowed(chainId, peerChainId));
    }

    /// @notice Allowing a peer writes the pair and snapshots the peer's base token from the Bridgehub, on L1 only:
    /// no chain gets a priority transaction, and the peer's side waits for the peer's admin.
    function test_allowInteropPeer_writesL1StateOnly() public {
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        uint256 chainPriorityTxs = IGetters(getZKChainAddress(chainId)).getTotalPriorityTxs();
        uint256 peerPriorityTxs = IGetters(getZKChainAddress(peerChainId)).getTotalPriorityTxs();

        Vm.Log[] memory logs = _allowInteropPeer();

        _assertNoPriorityTx(logs);
        assertEq(IGetters(getZKChainAddress(chainId)).getTotalPriorityTxs(), chainPriorityTxs);
        assertEq(IGetters(getZKChainAddress(peerChainId)).getTotalPriorityTxs(), peerPriorityTxs);
        assertFalse(addresses.chainRegistrationSender.interopPeerAllowed(peerChainId, chainId));
        assertEq(
            addresses.chainRegistrationSender.interopBaseTokenAssetId(peerChainId),
            addresses.bridgehub.baseTokenAssetId(peerChainId),
            "the peer's base token snapshot"
        );
        assertNotEq(addresses.chainRegistrationSender.interopBaseTokenAssetId(peerChainId), bytes32(0));
        assertEq(addresses.chainRegistrationSender.interopBaseTokenAssetId(chainId), bytes32(0));
    }

    /// @notice An allowed pair stays allowed until it is deregistered, so a second call has nothing to do.
    function test_allowInteropPeer_revertWhen_alreadyAllowed() public {
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        _allowInteropPeer();

        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InteropPeerAlreadyAllowed.selector, chainId, peerChainId));
        addresses.chainRegistrationSender.allowInteropPeer(chainId, peerChainId);
    }

    function test_allowInteropPeer_revertWhen_notChainAdmin() public {
        address notAdmin = makeAddr("notAdmin");
        vm.prank(notAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notAdmin));
        addresses.chainRegistrationSender.allowInteropPeer(chainId, peerChainId);
    }

    /// @notice The admin of the peer cannot write the chain's whitelist.
    function test_allowInteropPeer_revertWhen_peerAdmin() public {
        address peerAdmin = _setOwnAdmin(peerChainId, "peerAdmin");

        vm.prank(peerAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, peerAdmin));
        addresses.chainRegistrationSender.allowInteropPeer(chainId, peerChainId);
    }

    function test_allowInteropPeer_revertWhen_chainNotRegistered() public {
        vm.expectRevert(ZKChainNotRegistered.selector);
        addresses.chainRegistrationSender.allowInteropPeer(UNREGISTERED_CHAIN_ID, peerChainId);
    }

    function test_allowInteropPeer_revertWhen_peerNotRegistered() public {
        vm.prank(chainAdmin);
        vm.expectRevert(ZKChainNotRegistered.selector);
        addresses.chainRegistrationSender.allowInteropPeer(chainId, UNREGISTERED_CHAIN_ID);
    }

    function test_allowInteropPeer_revertWhen_peerIsSelf() public {
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropPeer.selector, chainId, chainId));
        addresses.chainRegistrationSender.allowInteropPeer(chainId, chainId);
    }

    function test_allowInteropPeer_revertWhen_peerIsL1() public {
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropPeer.selector, chainId, block.chainid));
        addresses.chainRegistrationSender.allowInteropPeer(chainId, block.chainid);
    }

    function test_allowInteropPeer_revertWhen_chainNotEnabled() public {
        _enableInterop(peerChainId);
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InteropNotEnabled.selector, chainId));
        addresses.chainRegistrationSender.allowInteropPeer(chainId, peerChainId);
    }

    function test_allowInteropPeer_revertWhen_peerNotEnabled() public {
        _enableInterop(chainId);
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InteropNotEnabled.selector, peerChainId));
        addresses.chainRegistrationSender.allowInteropPeer(chainId, peerChainId);
    }

    /// @notice A peer with an empty tree in the MessageRoot cannot be registered (see
    /// {protocol-docs/chain-lifecycle.md#interop-registration-chainregistrationsender}). Fresh chains have a
    /// seeded genesis leaf; this test mocks the invalid empty-tree state.
    function test_allowInteropPeer_revertWhen_peerHasNoBatchesInMessageRoot() public {
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        vm.mockCall(
            address(messageRoot),
            abi.encodeWithSelector(IMessageRootBase.chainTreeLeafCount.selector, peerChainId),
            abi.encode(uint256(0))
        );

        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainHasNoBatchesInMessageRoot.selector, peerChainId));
        addresses.chainRegistrationSender.allowInteropPeer(chainId, peerChainId);
    }

    /// @notice Deregistering pairs L1 never recorded, such as the ones the retired consent-free registration wrote on
    /// L2, emits and sends nothing to L2.
    function test_deregisterInteropPairs_pairsNeverAllowed() public {
        address owner = addresses.chainRegistrationSender.owner();

        vm.recordLogs();
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true, address(addresses.chainRegistrationSender));
        emit IChainRegistrationSender.InteropPairDeregistered(chainId, peerChainId);
        addresses.chainRegistrationSender.deregisterInteropPairs(chainId, _peers(peerChainId));
        vm.expectEmit(true, true, false, true, address(addresses.chainRegistrationSender));
        emit IChainRegistrationSender.InteropPairDeregistered(peerChainId, chainId);
        addresses.chainRegistrationSender.deregisterInteropPairs(peerChainId, _peers(chainId));
        vm.stopPrank();

        _assertNoPriorityTx(vm.getRecordedLogs());
    }

    /// @notice Governance can remove a pair the admin allowed, on L1 alone; the admin can then allow it again.
    function test_deregisterInteropPairs_allowedPair() public {
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        _allowInteropPeer();
        bytes32 snapshot = addresses.chainRegistrationSender.interopBaseTokenAssetId(peerChainId);

        vm.expectEmit(true, true, false, true, address(addresses.chainRegistrationSender));
        emit IChainRegistrationSender.InteropPairDeregistered(chainId, peerChainId);
        vm.recordLogs();
        vm.prank(addresses.chainRegistrationSender.owner());
        addresses.chainRegistrationSender.deregisterInteropPairs(chainId, _peers(peerChainId));

        _assertNoPriorityTx(vm.getRecordedLogs());
        assertFalse(addresses.chainRegistrationSender.interopPeerAllowed(chainId, peerChainId));
        assertEq(
            addresses.chainRegistrationSender.interopBaseTokenAssetId(peerChainId),
            snapshot,
            "the snapshot stays"
        );

        _allowInteropPeer();
    }

    /// @notice The chain's admin can remove a pair it allowed, and allow it again.
    function test_deregisterInteropPairs_byChainAdmin() public {
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        _allowInteropPeer();

        vm.expectEmit(true, true, false, true, address(addresses.chainRegistrationSender));
        emit IChainRegistrationSender.InteropPairDeregistered(chainId, peerChainId);
        vm.recordLogs();
        vm.prank(chainAdmin);
        addresses.chainRegistrationSender.deregisterInteropPairs(chainId, _peers(peerChainId));

        _assertNoPriorityTx(vm.getRecordedLogs());
        assertFalse(addresses.chainRegistrationSender.interopPeerAllowed(chainId, peerChainId));

        _allowInteropPeer();
    }

    /// @notice The chain's admin removes two allowed peers in one call, on L1 alone.
    function test_deregisterInteropPairs_severalPeers() public {
        _deployZKChain(ETH_TOKEN_ADDRESS);
        uint256 thirdChainId = zkChainIds[2];
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        _enableInterop(thirdChainId);
        _allowInteropPeer();
        vm.prank(chainAdmin);
        addresses.chainRegistrationSender.allowInteropPeer(chainId, thirdChainId);
        uint256[] memory peers = new uint256[](2);
        (peers[0], peers[1]) = (peerChainId, thirdChainId);

        vm.expectEmit(true, true, false, true, address(addresses.chainRegistrationSender));
        emit IChainRegistrationSender.InteropPairDeregistered(chainId, peerChainId);
        vm.expectEmit(true, true, false, true, address(addresses.chainRegistrationSender));
        emit IChainRegistrationSender.InteropPairDeregistered(chainId, thirdChainId);
        vm.recordLogs();
        vm.prank(chainAdmin);
        addresses.chainRegistrationSender.deregisterInteropPairs(chainId, peers);

        _assertNoPriorityTx(vm.getRecordedLogs());
        assertFalse(addresses.chainRegistrationSender.interopPeerAllowed(chainId, peerChainId));
        assertFalse(addresses.chainRegistrationSender.interopPeerAllowed(chainId, thirdChainId));
    }

    function test_deregisterInteropPairs_revertWhen_notOwnerNorChainAdmin() public {
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        _allowInteropPeer();
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        addresses.chainRegistrationSender.deregisterInteropPairs(chainId, _peers(peerChainId));

        assertTrue(addresses.chainRegistrationSender.interopPeerAllowed(chainId, peerChainId));
    }

    /// @notice The admin of the peer cannot remove the chain's side of the pair.
    function test_deregisterInteropPairs_revertWhen_peerAdmin() public {
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        _allowInteropPeer();
        address peerAdmin = _setOwnAdmin(peerChainId, "peerAdmin");
        uint256 priorityTxs = IGetters(getZKChainAddress(chainId)).getTotalPriorityTxs();

        vm.prank(peerAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, peerAdmin));
        addresses.chainRegistrationSender.deregisterInteropPairs(chainId, _peers(peerChainId));

        assertTrue(addresses.chainRegistrationSender.interopPeerAllowed(chainId, peerChainId));
        assertEq(IGetters(getZKChainAddress(chainId)).getTotalPriorityTxs(), priorityTxs);
    }

    /// @notice A list with one invalid peer reverts as a whole, the valid peers included.
    function test_deregisterInteropPairs_revertWhen_oneOfThePeersIsInvalid() public {
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        _allowInteropPeer();
        uint256[] memory peers = new uint256[](2);
        (peers[0], peers[1]) = (peerChainId, chainId);
        uint256 priorityTxs = IGetters(getZKChainAddress(chainId)).getTotalPriorityTxs();

        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropPeer.selector, chainId, chainId));
        addresses.chainRegistrationSender.deregisterInteropPairs(chainId, peers);

        assertTrue(addresses.chainRegistrationSender.interopPeerAllowed(chainId, peerChainId));
        assertEq(IGetters(getZKChainAddress(chainId)).getTotalPriorityTxs(), priorityTxs);
    }

    function test_deregisterInteropPairs_revertWhen_pairIsSelf() public {
        address owner = addresses.chainRegistrationSender.owner();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropPeer.selector, chainId, chainId));
        addresses.chainRegistrationSender.deregisterInteropPairs(chainId, _peers(chainId));
    }

    function test_deregisterInteropPairs_revertWhen_chainNotRegistered() public {
        address owner = addresses.chainRegistrationSender.owner();
        vm.prank(owner);
        vm.expectRevert(ZKChainNotRegistered.selector);
        addresses.chainRegistrationSender.deregisterInteropPairs(UNREGISTERED_CHAIN_ID, _peers(chainId));
    }

    function test_serviceTransaction_revertWhenCalledByDiamond() public {
        address chain = getZKChainAddress(chainId);
        bytes32 priorityRoot = IGetters(chain).getPriorityTreeRoot();

        vm.prank(chain);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, chain));
        MailboxFacet(chain).requestL2ServiceTransaction(makeAddr("l2Contract"), "");

        assertEq(IGetters(chain).getPriorityTreeRoot(), priorityRoot);
    }

    /*//////////////////////////////////////////////////////////////
                    suspendInterop / resumeInterop
    //////////////////////////////////////////////////////////////*/

    /// @notice The owner suspends and resumes a chain on L1 alone; the whitelist and the enabling are untouched.
    function test_suspendAndResume() public {
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        _allowInteropPeer();
        address owner = addresses.chainRegistrationSender.owner();

        vm.expectEmit(true, false, false, true, address(addresses.chainRegistrationSender));
        emit IChainRegistrationSender.InteropSuspended(peerChainId);
        vm.recordLogs();
        vm.prank(owner);
        addresses.chainRegistrationSender.suspendInterop(peerChainId);
        _assertNoPriorityTx(vm.getRecordedLogs());

        assertTrue(addresses.chainRegistrationSender.isInteropSuspended(peerChainId));
        assertFalse(addresses.chainRegistrationSender.isInteropSuspended(chainId));
        assertTrue(addresses.chainRegistrationSender.interopPeerAllowed(chainId, peerChainId));
        assertTrue(messageRoot.isInteropEnabled(peerChainId), "enabling is one-way and untouched");

        vm.expectEmit(true, false, false, true, address(addresses.chainRegistrationSender));
        emit IChainRegistrationSender.InteropResumed(peerChainId);
        vm.prank(owner);
        addresses.chainRegistrationSender.resumeInterop(peerChainId);
        assertFalse(addresses.chainRegistrationSender.isInteropSuspended(peerChainId));
    }

    function _peers(uint256 _peerChainId) internal pure returns (uint256[] memory peers) {
        peers = new uint256[](1);
        peers[0] = _peerChainId;
    }

    /// @dev The harness deploys every chain with the same admin, so tests that need two admins give the peer its own.
    function _setOwnAdmin(uint256 _chainId, string memory _name) internal returns (address admin) {
        address chain = getZKChainAddress(_chainId);
        admin = makeAddr(_name);
        vm.prank(_chainAdmin(_chainId));
        IAdmin(chain).setPendingAdmin(admin);
        vm.prank(admin);
        IAdmin(chain).acceptAdmin();
        assertEq(IGetters(chain).getAdmin(), admin);
    }

    function _assertNoPriorityTx(Vm.Log[] memory _logs) internal pure {
        assertEq(_logs.findAll(NEW_PRIORITY_REQUEST_SIGNATURE).length, 0, "no priority transaction");
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
