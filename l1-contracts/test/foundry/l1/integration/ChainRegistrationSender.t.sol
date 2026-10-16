// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {IBridgehubBase, L2TransactionRequestTwoBridgesOuter} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {CHAIN_REGISTRATION_SENDER_RESUBMISSION_ENCODING_VERSION} from "contracts/core/chain-registration/ChainRegistrationSender.sol";
import {IChainRegistrationSender} from "contracts/core/chain-registration/IChainRegistrationSender.sol";
import {IL2Bridgehub} from "contracts/core/bridgehub/IL2Bridgehub.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {Unauthorized, UnsupportedEncodingVersion} from "contracts/common/L1ContractErrors.sol";
import {ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {
    ChainHasNoBatchesInMessageRoot,
    ChainNotSettlingOnL1,
    InteropNotEnabled,
    InteropPeerAlreadyAllowed,
    InteropPeerNotAllowed,
    InvalidInteropPeer,
    ZKChainNotRegistered
} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

import {InteropGatingDeployer} from "./_SharedInteropGatingDeployer.t.sol";

import {LogFinder} from "test-utils/LogFinder.sol";

/// @notice The interop peer whitelist of `ChainRegistrationSender`. See
/// {protocol-docs/interop-gating.md#interop-peer-whitelist}.
contract ChainRegistrationSenderTests is InteropGatingDeployer {
    using LogFinder for Vm.Log[];

    uint256 internal constant UNREGISTERED_CHAIN_ID = 123456;
    uint256 internal constant GATEWAY_CHAIN_ID = 506;

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

    function _registrationCalldata(uint256 _peerChainId) internal view returns (bytes memory) {
        return
            abi.encodeCall(
                IL2Bridgehub.allowInteropPeer,
                (_peerChainId, addresses.bridgehub.baseTokenAssetId(_peerChainId))
            );
    }

    function _deregistrationCalldata(uint256 _peerChainId) internal pure returns (bytes memory) {
        return abi.encodeCall(IL2Bridgehub.deregisterChainForInterop, (_peerChainId));
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

    /// @notice Allowing a peer queues a service transaction registering it on the chain's L2 Bridgehub, and
    /// only on that chain: the peer's own L2 Bridgehub is written only once the peer's admin consents too.
    function test_allowInteropPeer_registersPeer() public {
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        uint256 peerPriorityTxs = IGetters(getZKChainAddress(peerChainId)).getTotalPriorityTxs();

        Vm.Log[] memory logs = _allowInteropPeer();

        assertEq(_priorityTxCalldata(logs, chainId), _registrationCalldata(peerChainId));
        assertEq(IGetters(getZKChainAddress(peerChainId)).getTotalPriorityTxs(), peerPriorityTxs);
        assertFalse(addresses.chainRegistrationSender.interopPeerAllowed(peerChainId, chainId));
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

    /// @notice The settlement layer is mocked to isolate this check from the separately-tested migration
    /// machinery.
    function test_allowInteropPeer_revertWhen_chainNotSettlingOnL1() public {
        _mockSettlementLayer(chainId, GATEWAY_CHAIN_ID);
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainNotSettlingOnL1.selector, chainId, GATEWAY_CHAIN_ID));
        addresses.chainRegistrationSender.allowInteropPeer(chainId, peerChainId);
    }

    /// @dev See `test_allowInteropPeer_revertWhen_chainNotSettlingOnL1` for why the settlement layer is mocked.
    function test_allowInteropPeer_revertWhen_peerNotSettlingOnL1() public {
        _mockSettlementLayer(peerChainId, GATEWAY_CHAIN_ID);
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainNotSettlingOnL1.selector, peerChainId, GATEWAY_CHAIN_ID));
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

    /// @notice Deregistering the legacy pairs, which L1 never recorded, of two chains registered on each other.
    function test_deregisterInteropPairs_clearsEveryPair() public {
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
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_priorityTxCalldata(logs, chainId), _deregistrationCalldata(peerChainId));
        assertEq(_priorityTxCalldata(logs, peerChainId), _deregistrationCalldata(chainId));
    }

    /// @notice Governance can remove a pair the admin allowed, which the admin can then allow again.
    function test_deregisterInteropPairs_allowedPair() public {
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        _allowInteropPeer();

        vm.expectEmit(true, true, false, true, address(addresses.chainRegistrationSender));
        emit IChainRegistrationSender.InteropPairDeregistered(chainId, peerChainId);
        vm.recordLogs();
        vm.prank(addresses.chainRegistrationSender.owner());
        addresses.chainRegistrationSender.deregisterInteropPairs(chainId, _peers(peerChainId));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_priorityTxCalldata(logs, chainId), _deregistrationCalldata(peerChainId));
        assertFalse(addresses.chainRegistrationSender.interopPeerAllowed(chainId, peerChainId));

        logs = _allowInteropPeer();
        assertEq(_priorityTxCalldata(logs, chainId), _registrationCalldata(peerChainId));
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
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_priorityTxCalldata(logs, chainId), _deregistrationCalldata(peerChainId));
        assertFalse(addresses.chainRegistrationSender.interopPeerAllowed(chainId, peerChainId));

        logs = _allowInteropPeer();
        assertEq(_priorityTxCalldata(logs, chainId), _registrationCalldata(peerChainId));
    }

    /// @notice The chain's admin removes two allowed peers in one call: one service transaction per peer, all on
    /// the chain, none on the peers.
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
        uint256 peerPriorityTxs = IGetters(getZKChainAddress(peerChainId)).getTotalPriorityTxs();
        uint256 thirdPriorityTxs = IGetters(getZKChainAddress(thirdChainId)).getTotalPriorityTxs();

        vm.expectEmit(true, true, false, true, address(addresses.chainRegistrationSender));
        emit IChainRegistrationSender.InteropPairDeregistered(chainId, peerChainId);
        vm.expectEmit(true, true, false, true, address(addresses.chainRegistrationSender));
        emit IChainRegistrationSender.InteropPairDeregistered(chainId, thirdChainId);
        vm.recordLogs();
        vm.prank(chainAdmin);
        addresses.chainRegistrationSender.deregisterInteropPairs(chainId, peers);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes[] memory calldatas = _priorityTxCalldatas(logs, chainId);
        assertEq(calldatas.length, 2, "one service transaction per peer");
        assertEq(calldatas[0], _deregistrationCalldata(peerChainId));
        assertEq(calldatas[1], _deregistrationCalldata(thirdChainId));
        assertEq(IGetters(getZKChainAddress(peerChainId)).getTotalPriorityTxs(), peerPriorityTxs);
        assertEq(IGetters(getZKChainAddress(thirdChainId)).getTotalPriorityTxs(), thirdPriorityTxs);
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

    /// @notice A resubmission re-sends the registration of an allowed peer, paid by the caller.
    function test_resubmission_allowedPeer_registersPeer() public {
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        _allowInteropPeer();

        Vm.Log[] memory logs = _resubmit(
            bytes.concat(CHAIN_REGISTRATION_SENDER_RESUBMISSION_ENCODING_VERSION, abi.encode(peerChainId))
        );

        assertEq(_priorityTxCalldata(logs, chainId), _registrationCalldata(peerChainId));
    }

    function test_resubmission_revertWhen_peerNotAllowed() public {
        _expectResubmissionRevert(
            bytes.concat(CHAIN_REGISTRATION_SENDER_RESUBMISSION_ENCODING_VERSION, abi.encode(peerChainId)),
            abi.encodeWithSelector(InteropPeerNotAllowed.selector, chainId, peerChainId)
        );
    }

    /// @notice The retired consent-free encoding is rejected.
    function test_resubmission_revertWhen_legacyEncodingVersion() public {
        _expectResubmissionRevert(
            bytes.concat(bytes1(0x01), abi.encode(peerChainId)),
            abi.encodeWithSelector(UnsupportedEncodingVersion.selector)
        );
    }

    function test_resubmission_revertWhen_peerIsSelf() public {
        _expectResubmissionRevert(
            bytes.concat(CHAIN_REGISTRATION_SENDER_RESUBMISSION_ENCODING_VERSION, abi.encode(chainId)),
            abi.encodeWithSelector(InteropPeerNotAllowed.selector, chainId, chainId)
        );
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

    function _mockSettlementLayer(uint256 _chainId, uint256 _settlementLayer) internal {
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeCall(IBridgehubBase.settlementLayer, (_chainId)),
            abi.encode(_settlementLayer)
        );
    }

    /// @dev Runs requestL2TransactionTwoBridges through ChainRegistrationSender; only ETH for base-token gas.
    function _resubmissionRequest(
        bytes memory _secondBridgeCalldata
    ) internal returns (address user, uint256 mintValue, L2TransactionRequestTwoBridgesOuter memory request) {
        user = makeAddr("resubmitter");
        uint256 gasPrice = 10000000;
        vm.txGasPrice(gasPrice);

        uint256 l2GasLimit = 1000000;
        mintValue = MailboxFacet(getZKChainAddress(chainId)).l2TransactionBaseCost(
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );
        vm.deal(user, mintValue);

        request = _createL2TransactionRequestTwoBridges({
            _chainId: chainId,
            _mintValue: mintValue,
            _secondBridgeValue: 0,
            _secondBridgeAddress: address(addresses.chainRegistrationSender),
            _l2Value: 0,
            _l2GasLimit: l2GasLimit,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _secondBridgeCalldata: _secondBridgeCalldata
        });
    }

    function _resubmit(bytes memory _secondBridgeCalldata) internal returns (Vm.Log[] memory logs) {
        (address user, uint256 mintValue, L2TransactionRequestTwoBridgesOuter memory request) = _resubmissionRequest(
            _secondBridgeCalldata
        );

        bool allowed = addresses.chainRegistrationSender.interopPeerAllowed(chainId, peerChainId);

        vm.recordLogs();
        vm.prank(user);
        bytes32 txHash = addresses.bridgehub.requestL2TransactionTwoBridges{value: mintValue}(request);
        logs = vm.getRecordedLogs();

        assertNotEq(txHash, bytes32(0));
        assertEq(user.balance, 0, "the caller pays the base-token gas");
        assertEq(addresses.chainRegistrationSender.interopPeerAllowed(chainId, peerChainId), allowed);
        Vm.Log memory baseTokenLog = logs.requireOne(
            "BridgehubDepositBaseTokenInitiated(uint256,address,bytes32,uint256)"
        );
        assertEq(uint256(baseTokenLog.topics[1]), chainId);
    }

    function _expectResubmissionRevert(bytes memory _secondBridgeCalldata, bytes memory _revertData) internal {
        (address user, uint256 mintValue, L2TransactionRequestTwoBridgesOuter memory request) = _resubmissionRequest(
            _secondBridgeCalldata
        );
        uint256 priorityTxs = IGetters(getZKChainAddress(chainId)).getTotalPriorityTxs();

        vm.prank(user);
        vm.expectRevert(_revertData);
        addresses.bridgehub.requestL2TransactionTwoBridges{value: mintValue}(request);

        assertEq(IGetters(getZKChainAddress(chainId)).getTotalPriorityTxs(), priorityTxs);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
