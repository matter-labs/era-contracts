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
import {ArrayLengthMismatch, Unauthorized, UnsupportedEncodingVersion} from "contracts/common/L1ContractErrors.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {
    ChainHasNoBatchesInMessageRoot,
    ChainNotSettlingOnL1,
    InteropNotEnabled,
    InvalidInteropPeer,
    RegistrationRequiresConsent,
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
        chainAdmin = _chainAdmin(chainId);
    }

    function _registrationCalldata(uint256 _peerChainId) internal view returns (bytes memory) {
        return
            abi.encodeCall(
                IL2Bridgehub.registerChainForInterop,
                (_peerChainId, addresses.bridgehub.baseTokenAssetId(_peerChainId))
            );
    }

    function _clearCalldata(uint256 _peerChainId) internal pure returns (bytes memory) {
        return abi.encodeCall(IL2Bridgehub.registerChainForInterop, (_peerChainId, bytes32(0)));
    }

    function _setInteropPeer(bool _allowed) internal returns (Vm.Log[] memory logs) {
        vm.expectEmit(true, true, false, true, address(addresses.chainRegistrationSender));
        emit IChainRegistrationSender.InteropPeerSet(chainId, peerChainId, _allowed);
        vm.recordLogs();
        vm.prank(chainAdmin);
        addresses.chainRegistrationSender.setInteropPeer(chainId, peerChainId, _allowed);
        logs = vm.getRecordedLogs();
        assertEq(addresses.chainRegistrationSender.interopPeerAllowed(chainId, peerChainId), _allowed);
    }

    /// @notice Consent-free registration is retired.
    function test_registerChain_reverts() public {
        vm.expectRevert(RegistrationRequiresConsent.selector);
        addresses.chainRegistrationSender.registerChain(peerChainId, chainId);
    }

    /// @notice Allowing a peer queues a service transaction registering it on the chain's L2 Bridgehub, and
    /// only on that chain: the peer's own L2 Bridgehub is written only once the peer's admin consents too.
    function test_setInteropPeer_allow_registersPeer() public {
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        uint256 peerPriorityTxs = IGetters(getZKChainAddress(peerChainId)).getTotalPriorityTxs();

        Vm.Log[] memory logs = _setInteropPeer(true);

        assertEq(_priorityTxCalldata(logs, chainId), _registrationCalldata(peerChainId));
        assertEq(IGetters(getZKChainAddress(peerChainId)).getTotalPriorityTxs(), peerPriorityTxs);
        assertFalse(addresses.chainRegistrationSender.interopPeerAllowed(peerChainId, chainId));
    }

    /// @notice Revoking clears the peer on the chain's L2 Bridgehub, and needs neither chain to have interop.
    function test_setInteropPeer_revoke_clearsPeer() public {
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        _setInteropPeer(true);

        Vm.Log[] memory logs = _setInteropPeer(false);

        assertEq(_priorityTxCalldata(logs, chainId), _clearCalldata(peerChainId));
    }

    function test_setInteropPeer_revoke_withoutInterop() public {
        assertFalse(messageRoot.isInteropEnabled(chainId));

        Vm.Log[] memory logs = _setInteropPeer(false);

        assertEq(_priorityTxCalldata(logs, chainId), _clearCalldata(peerChainId));
    }

    function test_setInteropPeer_revertWhen_notChainAdmin() public {
        address notAdmin = makeAddr("notAdmin");
        vm.prank(notAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notAdmin));
        addresses.chainRegistrationSender.setInteropPeer(chainId, peerChainId, false);
    }

    /// @notice The admin of the peer cannot write the chain's whitelist. The harness deploys both chains
    /// with the same admin, so the peer gets its own admin first.
    function test_setInteropPeer_revertWhen_peerAdmin() public {
        address peer = getZKChainAddress(peerChainId);
        address peerAdmin = makeAddr("peerAdmin");
        vm.prank(chainAdmin);
        IAdmin(peer).setPendingAdmin(peerAdmin);
        vm.prank(peerAdmin);
        IAdmin(peer).acceptAdmin();
        assertEq(IGetters(peer).getAdmin(), peerAdmin);

        vm.prank(peerAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, peerAdmin));
        addresses.chainRegistrationSender.setInteropPeer(chainId, peerChainId, false);
    }

    function test_setInteropPeer_revertWhen_chainNotRegistered() public {
        vm.expectRevert(ZKChainNotRegistered.selector);
        addresses.chainRegistrationSender.setInteropPeer(UNREGISTERED_CHAIN_ID, peerChainId, false);
    }

    function test_setInteropPeer_revertWhen_peerNotRegistered() public {
        vm.prank(chainAdmin);
        vm.expectRevert(ZKChainNotRegistered.selector);
        addresses.chainRegistrationSender.setInteropPeer(chainId, UNREGISTERED_CHAIN_ID, false);
    }

    function test_setInteropPeer_revertWhen_peerIsSelf() public {
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropPeer.selector, chainId, chainId));
        addresses.chainRegistrationSender.setInteropPeer(chainId, chainId, false);
    }

    function test_setInteropPeer_revertWhen_peerIsL1() public {
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropPeer.selector, chainId, block.chainid));
        addresses.chainRegistrationSender.setInteropPeer(chainId, block.chainid, false);
    }

    function test_setInteropPeer_revertWhen_chainNotEnabled() public {
        _enableInterop(peerChainId);
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InteropNotEnabled.selector, chainId));
        addresses.chainRegistrationSender.setInteropPeer(chainId, peerChainId, true);
    }

    function test_setInteropPeer_revertWhen_peerNotEnabled() public {
        _enableInterop(chainId);
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InteropNotEnabled.selector, peerChainId));
        addresses.chainRegistrationSender.setInteropPeer(chainId, peerChainId, true);
    }

    /// @notice Revoking is rejected too while one of the chains settles elsewhere. The settlement layer is
    /// mocked to isolate this check from the separately-tested migration machinery.
    function test_setInteropPeer_revertWhen_chainNotSettlingOnL1() public {
        _mockSettlementLayer(chainId, GATEWAY_CHAIN_ID);
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainNotSettlingOnL1.selector, chainId, GATEWAY_CHAIN_ID));
        addresses.chainRegistrationSender.setInteropPeer(chainId, peerChainId, false);
    }

    /// @dev See `test_setInteropPeer_revertWhen_chainNotSettlingOnL1` for why the settlement layer is mocked.
    function test_setInteropPeer_revertWhen_peerNotSettlingOnL1() public {
        _mockSettlementLayer(peerChainId, GATEWAY_CHAIN_ID);
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainNotSettlingOnL1.selector, peerChainId, GATEWAY_CHAIN_ID));
        addresses.chainRegistrationSender.setInteropPeer(chainId, peerChainId, false);
    }

    /// @notice A peer with an empty tree in the MessageRoot cannot be registered (see
    /// {protocol-docs/chain-lifecycle.md#interop-registration-chainregistrationsender}). Fresh chains have a
    /// seeded genesis leaf; this test mocks the invalid empty-tree state.
    function test_setInteropPeer_revertWhen_peerHasNoBatchesInMessageRoot() public {
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        vm.mockCall(
            address(messageRoot),
            abi.encodeWithSelector(IMessageRootBase.chainTreeLeafCount.selector, peerChainId),
            abi.encode(uint256(0))
        );

        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(ChainHasNoBatchesInMessageRoot.selector, peerChainId));
        addresses.chainRegistrationSender.setInteropPeer(chainId, peerChainId, true);
    }

    /// @notice The empty-tree check guards registrations only: clearing a peer never needs its batches.
    /// See `test_setInteropPeer_revertWhen_peerHasNoBatchesInMessageRoot` for why the leaf count is mocked.
    function test_setInteropPeer_revoke_ignoresEmptyMessageRootTree() public {
        vm.mockCall(
            address(messageRoot),
            abi.encodeWithSelector(IMessageRootBase.chainTreeLeafCount.selector, peerChainId),
            abi.encode(uint256(0))
        );

        Vm.Log[] memory logs = _setInteropPeer(false);

        assertEq(_priorityTxCalldata(logs, chainId), _clearCalldata(peerChainId));
    }

    function test_deregisterLegacyPairs_clearsEveryPair() public {
        uint256[] memory chainsRegisteredOn = new uint256[](2);
        uint256[] memory chainsToDeregister = new uint256[](2);
        (chainsRegisteredOn[0], chainsToDeregister[0]) = (chainId, peerChainId);
        (chainsRegisteredOn[1], chainsToDeregister[1]) = (peerChainId, chainId);

        vm.expectEmit(true, true, false, true, address(addresses.chainRegistrationSender));
        emit IChainRegistrationSender.LegacyPairDeregistered(chainId, peerChainId);
        vm.expectEmit(true, true, false, true, address(addresses.chainRegistrationSender));
        emit IChainRegistrationSender.LegacyPairDeregistered(peerChainId, chainId);
        vm.recordLogs();
        vm.prank(addresses.chainRegistrationSender.owner());
        addresses.chainRegistrationSender.deregisterLegacyPairs(chainsRegisteredOn, chainsToDeregister);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_priorityTxCalldata(logs, chainId), _clearCalldata(peerChainId));
        assertEq(_priorityTxCalldata(logs, peerChainId), _clearCalldata(chainId));
    }

    function test_deregisterLegacyPairs_revertWhen_notOwner() public {
        uint256[] memory pairs = new uint256[](1);
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert("Ownable: caller is not the owner");
        addresses.chainRegistrationSender.deregisterLegacyPairs(pairs, pairs);
    }

    function test_deregisterLegacyPairs_revertWhen_lengthMismatch() public {
        address owner = addresses.chainRegistrationSender.owner();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ArrayLengthMismatch.selector, 1, 2));
        addresses.chainRegistrationSender.deregisterLegacyPairs(new uint256[](1), new uint256[](2));
    }

    function test_deregisterLegacyPairs_revertWhen_pairIsSelf() public {
        uint256[] memory pairs = new uint256[](1);
        pairs[0] = chainId;
        address owner = addresses.chainRegistrationSender.owner();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropPeer.selector, chainId, chainId));
        addresses.chainRegistrationSender.deregisterLegacyPairs(pairs, pairs);
    }

    function test_deregisterLegacyPairs_revertWhen_chainNotRegistered() public {
        uint256[] memory chainsRegisteredOn = new uint256[](1);
        uint256[] memory chainsToDeregister = new uint256[](1);
        (chainsRegisteredOn[0], chainsToDeregister[0]) = (UNREGISTERED_CHAIN_ID, chainId);
        address owner = addresses.chainRegistrationSender.owner();
        vm.prank(owner);
        vm.expectRevert(ZKChainNotRegistered.selector);
        addresses.chainRegistrationSender.deregisterLegacyPairs(chainsRegisteredOn, chainsToDeregister);
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
        _setInteropPeer(true);

        Vm.Log[] memory logs = _resubmit(
            bytes.concat(CHAIN_REGISTRATION_SENDER_RESUBMISSION_ENCODING_VERSION, abi.encode(peerChainId))
        );

        assertEq(_priorityTxCalldata(logs, chainId), _registrationCalldata(peerChainId));
    }

    /// @notice A resubmission for a pair that was never allowed, or was revoked, clears the peer.
    function test_resubmission_disallowedPeer_clearsPeer() public {
        Vm.Log[] memory logs = _resubmit(
            bytes.concat(CHAIN_REGISTRATION_SENDER_RESUBMISSION_ENCODING_VERSION, abi.encode(peerChainId))
        );

        assertEq(_priorityTxCalldata(logs, chainId), _clearCalldata(peerChainId));
    }

    /// @notice A resubmission queued before a newer decision is processed first on L2, so the pair ends in the
    /// newer state; a later resubmission re-sends that state.
    function test_resubmission_staleThenNewerDecision_endsInNewerState() public {
        _enableInterop(chainId);
        _enableInterop(peerChainId);
        _setInteropPeer(true);
        bytes memory resubmission = bytes.concat(
            CHAIN_REGISTRATION_SENDER_RESUBMISSION_ENCODING_VERSION,
            abi.encode(peerChainId)
        );

        (uint256 staleTxId, bytes memory staleCalldata) = _priorityTx(_resubmit(resubmission), chainId);
        (uint256 revokeTxId, bytes memory revokeCalldata) = _priorityTx(_setInteropPeer(false), chainId);

        assertEq(staleCalldata, _registrationCalldata(peerChainId));
        assertEq(revokeCalldata, _clearCalldata(peerChainId));
        assertGt(revokeTxId, staleTxId, "the newer decision is processed last");
        assertEq(_priorityTxCalldata(_resubmit(resubmission), chainId), _clearCalldata(peerChainId));
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
            abi.encodeWithSelector(InvalidInteropPeer.selector, chainId, chainId)
        );
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
