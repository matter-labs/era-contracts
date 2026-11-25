// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetTracker} from "contracts/bridge/asset-tracker/L2AssetTracker.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {
    ETH_TOKEN_ADDRESS,
    INTEROP_ROOT_WRITERS_FEATURE,
    L1_TO_L2_INTEROP_FEATURE,
    L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH,
    SERVICE_TRANSACTION_SENDER
} from "contracts/common/Config.sol";
import {InsufficientChainBalance, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {
    BundleStatus,
    InteropBundle,
    InteropCallStarter,
    InteropCounterparts,
    InteropRoot,
    L2CanonicalTransaction,
    L2Message,
    MessageInclusionProof,
    StoredInteropRoot
} from "contracts/common/Messaging.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_TRACKER_ADDR,
    L2_BOOTLOADER_ADDRESS,
    L2_BRIDGEHUB_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_INTEROP_ROOT_STORAGE_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {IL2Bridgehub} from "contracts/core/bridgehub/IL2Bridgehub.sol";
import {INTEROP_COUNTERPARTS_MIN_PROTOCOL_VERSION} from "contracts/core/chain-registration/ChainRegistrationSender.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteropCenter} from "contracts/interop/InteropCenter.sol";
import {L2InteropRootStorage} from "contracts/interop/L2InteropRootStorage.sol";
import {L2InteropHandler} from "contracts/interop/interop-handler/L2InteropHandler.sol";
import {
    BundleAlreadyProcessed,
    ChainFeatureNotEnabled,
    InteropCounterpartsNotSet,
    MessageNotIncluded,
    WrongDestinationChainId
} from "contracts/interop/InteropErrors.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

import {OneWayBundlesDeployer} from "./_SharedOneWayBundlesDeployer.t.sol";
import {SystemContractsArgs} from "./l2-tests-abstract/Utils.sol";
import {L2UtilsBase} from "./l2-tests-in-l1-context/L2UtilsBase.sol";

import {LogFinder} from "test-utils/LogFinder.sol";
import {OneWayBundleProofBuilder} from "test-utils/OneWayBundleProofBuilder.sol";
import {NEW_PRIORITY_REQUEST_SIGNATURE} from "test/foundry/TestConstants.sol";

/// @dev Stands in for the L2->L1 messenger, a ZKsync OS system contract: records what a batch would publish.
contract RecordingL2ToL1Messenger {
    bytes[] public messages;

    function sendToL1(bytes calldata _message) external returns (bytes32) {
        messages.push(_message);
        return keccak256(_message);
    }

    function lastMessage() external view returns (bytes memory) {
        return messages[messages.length - 1];
    }
}

/// @dev A chain contract that is not a diamond: the getters `registerAlreadyDeployedZKChain` reads, and a way to
/// append the chain's batch roots to the message root as the chain itself. It stands in for a contract that follows
/// a chain settling elsewhere; how such a contract checks the batches it appends is out of scope here.
contract AlreadyDeployedChainStandIn {
    uint256 internal immutable CHAIN_ID;
    address internal immutable BRIDGE_HUB;
    bytes32 internal immutable BASE_TOKEN_ASSET_ID;
    address internal immutable ADMIN;

    constructor(uint256 _chainId, address _bridgehub, bytes32 _baseTokenAssetId, address _admin) {
        CHAIN_ID = _chainId;
        BRIDGE_HUB = _bridgehub;
        BASE_TOKEN_ASSET_ID = _baseTokenAssetId;
        ADMIN = _admin;
    }

    function getChainId() external view returns (uint256) {
        return CHAIN_ID;
    }

    function getChainTypeManager() external view returns (address) {
        return address(this);
    }

    function getAdmin() external view returns (address) {
        return ADMIN;
    }

    function getBaseTokenAssetId() external view returns (bytes32) {
        return BASE_TOKEN_ASSET_ID;
    }

    function getBridgehub() external view returns (address) {
        return BRIDGE_HUB;
    }

    function getTotalBatchesExecuted() external pure returns (uint256) {
        return 0;
    }

    function appendBatchRoot(IMessageRootBase _messageRoot, uint256 _batchNumber, bytes32 _chainBatchRoot) external {
        _messageRoot.addChainBatchRootV32(CHAIN_ID, _batchNumber, _chainBatchRoot);
    }
}

/// @notice One-way bundles in both directions between a real L1 ecosystem and the built-ins of one of its chains,
/// deployed in the same EVM: a transfer from L1 is sent by `L1InteropCenter`, proven on the chain against a root in
/// `L2InteropRootStorage` and minted; the way back is sent by the chain's `InteropCenter`, proven on L1 against the
/// chain's batch root in `L1MessageRoot` and released from the vault. Every proof is built from the real trees and
/// checked by the real contracts. Two things are stood in for, in both variants: the chain's node, which would bring
/// the roots and seal the batches, and the ZKsync OS system contracts.
/// See {protocol-docs/interop.md#one-way-bundles-from-an-l1}.
abstract contract OneWayBundlesEndToEndBase is OneWayBundlesDeployer {
    using LogFinder for Vm.Log[];

    uint256 internal constant AMOUNT = 1000;

    /// @dev The chain id of the L1 the ecosystem is deployed on, and of every L1 contract's `block.chainid`.
    uint256 internal l1ChainId;

    L2InteropHandler internal l2InteropHandler = L2InteropHandler(payable(L2_INTEROP_HANDLER_ADDR));
    InteropCenter internal l2InteropCenter = InteropCenter(L2_INTEROP_CENTER_ADDR);
    L2InteropRootStorage internal l2RootStorage = L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR);
    L2NativeTokenVault internal l2Vault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
    IL2Bridgehub internal l2Bridgehub = IL2Bridgehub(L2_BRIDGEHUB_ADDR);
    RecordingL2ToL1Messenger internal l2Messenger = RecordingL2ToL1Messenger(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR);

    address internal l1Receiver = makeAddr("l1Receiver");
    address internal l2Owner = makeAddr("l2Owner");

    /*//////////////////////////////////////////////////////////////
                        What the two variants define
    //////////////////////////////////////////////////////////////*/

    /// @notice The chain id of the L1 the chain's built-ins are initialized with.
    function _l1ChainIdOfTheChain() internal view virtual returns (uint256);

    /// @notice The L1 asset router the chain's built-ins are initialized with.
    function _l1AssetRouterOfTheChain() internal view virtual returns (address);

    /// @notice Registers the destination chain on L1, if the fixture's chain does not serve.
    function _registerChainOnL1() internal virtual {}

    /// @notice Gives the chain what it needs to execute the L1's bundles and to send bundles back.
    function _configureChain() internal virtual;

    /// @notice Stores the L1's root of `_blockNumber` on the chain.
    function _bringRootToTheChain(uint256 _blockNumber) internal virtual;

    /// @notice Records `_chainBatchRoot` as the chain's next batch in the L1 message root.
    function _settleBatchOnL1(uint256 _batchNumber, bytes32 _chainBatchRoot) internal virtual;

    /*//////////////////////////////////////////////////////////////
                                Setup
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        _deployOneWayBundlesEcosystem();
        l1ChainId = block.chainid;
        _registerChainOnL1();
        _enableDestination(chainId);
        _deployChainBuiltIns();
        _configureChain();
    }

    function _onL1() internal {
        vm.chainId(l1ChainId);
    }

    function _onChain() internal {
        vm.chainId(chainId);
    }

    /// @dev Deploys the chain's built-ins at their fixed addresses, next to the L1 contracts.
    function _deployChainBuiltIns() internal {
        _onChain();
        L2UtilsBase.initSystemContracts(
            SystemContractsArgs({
                broadcast: false,
                l1ChainId: _l1ChainIdOfTheChain(),
                eraChainId: zkChainIds[0],
                l1AssetRouter: _l1AssetRouterOfTheChain(),
                l2TokenBeacon: address(new UpgradeableBeacon(address(new BridgedStandardERC20()))),
                aliasedOwner: l2Owner,
                contractsDeployedAlready: false,
                l1CtmDeployer: makeAddr("l1CtmDeployer"),
                maxNumberOfZKChains: 100,
                wethToken: makeAddr("l2Weth")
            })
        );
        // The harness deploys a stand-in without the writers; the flow needs the production contract.
        vm.etch(L2_INTEROP_ROOT_STORAGE_ADDR, address(new L2InteropRootStorage()).code);
        vm.etch(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, address(new RecordingL2ToL1Messenger()).code);
        // Mock justification: the system context is a ZKsync OS system contract, not deployed here.
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(_l1ChainIdOfTheChain())
        );
        _onL1();
    }

    function _serviceTransaction(address _target, bytes memory _data) internal {
        vm.prank(SERVICE_TRANSACTION_SENDER);
        (bool success, bytes memory returnData) = _target.call(_data);
        assertTrue(success, string(returnData));
    }

    /*//////////////////////////////////////////////////////////////
                                The flow
    //////////////////////////////////////////////////////////////*/

    /// @notice Sends a transfer from L1 in its own block and returns it with its proof against that block's root.
    function _sendFromL1(
        bytes32 _salt
    ) internal returns (SentBundle memory sent, MessageInclusionProof memory proof, uint256 rootBlock) {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        sent = _sendTransfer(AMOUNT, _salt);
        rootBlock = block.number;
        proof = _proofOfL1Bundle(sent, rootBlock);
    }

    function _proofOfL1Bundle(
        SentBundle memory _sent,
        uint256 _rootBlock
    ) internal view returns (MessageInclusionProof memory) {
        return
            MessageInclusionProof({
                chainId: l1ChainId,
                l1BatchNumber: _sent.batchNumber,
                l2MessageIndex: 0,
                message: L2Message({txNumberInBatch: 0, sender: address(l1InteropCenter), data: ""}),
                proof: OneWayBundleProofBuilder.localMessageProof(messageRoot, _sent.batchNumber, _rootBlock)
            });
    }

    function _interopRootOfL1(uint256 _blockNumber) internal view returns (InteropRoot memory) {
        StoredInteropRoot memory recorded = messageRoot.historicalRoot(_blockNumber);
        bytes32[] memory sides = new bytes32[](1);
        sides[0] = recorded.root;
        return
            InteropRoot({
                chainId: l1ChainId,
                blockOrBatchNumber: _blockNumber,
                timestamp: recorded.timestamp,
                sides: sides
            });
    }

    /// @notice Sends `_amount` of the bridged token from `l2Receiver` on the chain back to `l1Receiver` on L1.
    /// @return bundle The encoded bundle the chain's interop center published.
    function _sendFromChain(uint256 _amount, bytes32 _salt) internal returns (bytes memory bundle) {
        bytes[] memory callAttributes = new bytes[](1);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));
        InteropCallStarter[] memory starters = new InteropCallStarter[](1);
        starters[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(L2_ASSET_ROUTER_ADDR),
            data: DataEncoding.encodeAssetRouterBridgehubDepositData(
                assetId,
                DataEncoding.encodeBridgeBurnData(_amount, l1Receiver, address(0))
            ),
            callAttributes: callAttributes
        });

        vm.recordLogs();
        vm.prank(l2Receiver);
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(l1ChainId), starters, _saltAttribute(_salt));
        Vm.Log memory bundleLog = vm.getRecordedLogs().requireOneFrom(
            "InteropBundleSent(bytes32,bytes32,(bytes1,uint256,uint256,bytes32,bytes32,(bytes1,bool,address,address,uint256,bytes)[],(bytes,bytes,bool,bytes32)))",
            L2_INTEROP_CENTER_ADDR
        );
        (, , InteropBundle memory interopBundle) = abi.decode(bundleLog.data, (bytes32, bytes32, InteropBundle));
        bundle = abi.encode(interopBundle);
        assertEq(l2Messenger.lastMessage(), bytes.concat(bytes1(0x01), bundle), "the bundle left as an L2->L1 message");
    }

    /// @notice Seals a batch of the chain whose logs are another log and the message `_message` of the chain's
    /// interop center, settles it on L1 and returns the proof of the message against the batch root.
    function _settleMessageOnL1(bytes memory _message) internal returns (MessageInclusionProof memory proof) {
        bytes32[] memory logs = new bytes32[](2);
        logs[0] = keccak256("another log of the batch");
        logs[1] = OneWayBundleProofBuilder.messageLeaf(L2_INTEROP_CENTER_ADDR, _message);
        uint256 logsTreeDepth = 2;
        bytes32 logsRoot = OneWayBundleProofBuilder.logsRoot(logs, logsTreeDepth);

        uint256 batchNumber = messageRoot.currentChainBatchNumber(chainId) + 1;
        _settleBatchOnL1(batchNumber, OneWayBundleProofBuilder.chainBatchRoot(logsRoot));

        proof = MessageInclusionProof({
            chainId: chainId,
            l1BatchNumber: batchNumber,
            l2MessageIndex: 1,
            message: L2Message({txNumberInBatch: 0, sender: L2_INTEROP_CENTER_ADDR, data: ""}),
            proof: OneWayBundleProofBuilder.finalProof(
                OneWayBundleProofBuilder.merklePath(logs, 1, L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, logsTreeDepth)
            )
        });
    }

    /*//////////////////////////////////////////////////////////////
                                Tests
    //////////////////////////////////////////////////////////////*/

    /// @notice A token goes from L1 to the chain and back: locked in the L1 vault and minted on the chain, then
    /// burned on the chain and released by the L1 vault, with the accounting of a deposit and a withdrawal.
    function test_transferToTheChainAndBack() public {
        (SentBundle memory sent, MessageInclusionProof memory proof, uint256 rootBlock) = _sendFromL1("salt");
        assertEq(token.balanceOf(user), 0);
        assertEq(addresses.l1NativeTokenVault.chainTotalDeposited(chainId, assetId), AMOUNT);
        assertEq(addresses.l1NativeTokenVault.bridgedOut(assetId), AMOUNT);

        _onChain();
        _bringRootToTheChain(rootBlock);
        vm.prank(makeAddr("anyone"));
        l2InteropHandler.executeBundle(sent.encodedBundle, proof);

        address bridgedToken = l2Vault.tokenAddress(assetId);
        assertEq(bridgedToken, l2Vault.calculateCreate2TokenAddress(l1ChainId, address(token)));
        assertEq(l2Vault.originChainId(assetId), l1ChainId);
        assertEq(IERC20(bridgedToken).balanceOf(l2Receiver), AMOUNT);
        assertTrue(l2InteropHandler.bundleStatus(sent.bundleHash) == BundleStatus.FullyExecuted);
        (, uint256 depositsFromL1) = L2AssetTracker(L2_ASSET_TRACKER_ADDR).interopInfo(assetId);
        assertEq(depositsFromL1, _l1ChainIdOfTheChain() == l1ChainId ? AMOUNT : 0);

        bytes memory exitBundle = _sendFromChain(AMOUNT, "exit salt");
        assertEq(IERC20(bridgedToken).totalSupply(), 0, "burned on the chain");

        _onL1();
        MessageInclusionProof memory exitProof = _settleMessageOnL1(bytes.concat(bytes1(0x01), exitBundle));
        vm.prank(makeAddr("anyone"));
        addresses.l1InteropHandler.executeBundle(exitBundle, exitProof);

        assertEq(token.balanceOf(l1Receiver), AMOUNT);
        assertEq(addresses.l1NativeTokenVault.bridgedOut(assetId), 0);
        assertEq(addresses.l1NativeTokenVault.chainTotalWithdrawn(chainId, assetId), AMOUNT);
        assertTrue(addresses.l1InteropHandler.bundleStatus(keccak256(exitBundle)) == BundleStatus.FullyExecuted);
    }

    /// @notice A bundle is proven against any root recorded after it was sent: the chain needs only one of them.
    function test_transferToTheChain_provenAgainstALaterRoot() public {
        (SentBundle memory first, , ) = _sendFromL1("first");
        (SentBundle memory second, MessageInclusionProof memory secondProof, uint256 rootBlock) = _sendFromL1("second");
        // The proofs are built now, from the trees as the later root sees them.
        MessageInclusionProof memory firstProof = _proofOfL1Bundle(first, rootBlock);

        _onChain();
        _bringRootToTheChain(rootBlock);
        l2InteropHandler.executeBundle(first.encodedBundle, firstProof);
        l2InteropHandler.executeBundle(second.encodedBundle, secondProof);
        assertEq(IERC20(l2Vault.tokenAddress(assetId)).balanceOf(l2Receiver), 2 * AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(BundleAlreadyProcessed.selector, first.bundleHash));
        l2InteropHandler.executeBundle(first.encodedBundle, firstProof);
    }

    /// @notice Until a root that holds the bundle is on the chain, the bundle waits.
    function test_transferToTheChain_revertWhen_rootNotOnTheChain() public {
        (SentBundle memory sent, MessageInclusionProof memory proof, uint256 rootBlock) = _sendFromL1("salt");

        _onChain();
        vm.expectRevert(MessageNotIncluded.selector);
        l2InteropHandler.executeBundle(sent.encodedBundle, proof);

        _bringRootToTheChain(rootBlock);
        l2InteropHandler.executeBundle(sent.encodedBundle, proof);
    }

    /// @notice The bundle is for the chain: L1's own interop handler does not take it.
    function test_bundleOfL1_notExecutableOnL1() public {
        (SentBundle memory sent, MessageInclusionProof memory proof, ) = _sendFromL1("salt");
        proof.proof = OneWayBundleProofBuilder.finalProof(new bytes32[](0));

        vm.expectRevert(abi.encodeWithSelector(WrongDestinationChainId.selector, sent.bundleHash, chainId, l1ChainId));
        addresses.l1InteropHandler.executeBundle(sent.encodedBundle, proof);
    }

    /// @notice What comes back from the chain is bounded by what went to it: a batch that claims more, however it
    /// got into the message root, releases nothing.
    function test_transferBack_revertWhen_moreThanWentToTheChain() public {
        (SentBundle memory sent, MessageInclusionProof memory proof, uint256 rootBlock) = _sendFromL1("salt");
        _onChain();
        _bringRootToTheChain(rootBlock);
        l2InteropHandler.executeBundle(sent.encodedBundle, proof);
        bytes memory exitBundle = _sendFromChain(AMOUNT, "exit salt");

        // The same bundle with a larger amount, as a made-up batch would carry it.
        InteropBundle memory forged = abi.decode(exitBundle, (InteropBundle));
        forged.calls[0].data = abi.encodeWithSelector(
            bytes4(forged.calls[0].data),
            chainId,
            assetId,
            DataEncoding.encodeBridgeMintData({
                _originalCaller: l2Receiver,
                _remoteReceiver: l1Receiver,
                _originToken: address(token),
                _amount: AMOUNT + 1,
                _erc20Metadata: addresses.l1NativeTokenVault.getERC20Getters(address(token), l1ChainId)
            })
        );
        bytes memory forgedBundle = abi.encode(forged);

        _onL1();
        MessageInclusionProof memory forgedProof = _settleMessageOnL1(bytes.concat(bytes1(0x01), forgedBundle));
        vm.expectRevert(abi.encodeWithSelector(InsufficientChainBalance.selector, chainId, assetId, AMOUNT + 1));
        addresses.l1InteropHandler.executeBundle(forgedBundle, forgedProof);
        assertEq(token.balanceOf(l1Receiver), 0);
    }
}

/// @notice The chain is a chain of the L1 ecosystem that settles on it. Its bootloader imports L1's roots, and its
/// counterparts and chain feature arrive as the service transactions the real `ChainRegistrationSender` queues.
contract OneWayBundlesWithL1EndToEndTest is OneWayBundlesEndToEndBase {
    using LogFinder for Vm.Log[];

    function _l1ChainIdOfTheChain() internal view override returns (uint256) {
        return l1ChainId;
    }

    function _l1AssetRouterOfTheChain() internal view override returns (address) {
        return address(addresses.sharedBridge);
    }

    function _configureChain() internal override {
        _relayToChain(_enableFeatureOnL1());
        _relayToChain(_setCounterpartsOnL1(true));
    }

    /// @dev The bootloader imports the root L1 recorded, from L1's `NewInteropRoot` events.
    function _bringRootToTheChain(uint256 _blockNumber) internal override {
        InteropRoot memory root = _interopRootOfL1(_blockNumber);
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2RootStorage.addSingleInteropRoot(root);
    }

    /// @dev The chain's diamond is pranked for the call its executor makes when it executes a batch: committing and
    /// proving a batch is out of scope here.
    function _settleBatchOnL1(uint256 _batchNumber, bytes32 _chainBatchRoot) internal override {
        vm.prank(zkChain);
        messageRoot.addChainBatchRootV32(chainId, _batchNumber, _chainBatchRoot);
    }

    /// @dev Mock justification: the chains of this fixture are created at the release this branch is based on, while
    /// the built-ins deployed for the chain are the ones with the counterparts.
    function _mockChainProtocolVersion() internal {
        vm.mockCall(
            zkChain,
            abi.encodeCall(IGetters.getProtocolVersion, ()),
            abi.encode(INTEROP_COUNTERPARTS_MIN_PROTOCOL_VERSION)
        );
    }

    function _enableFeatureOnL1() internal returns (Vm.Log[] memory logs) {
        _mockChainProtocolVersion();
        vm.recordLogs();
        vm.prank(addresses.chainRegistrationSender.owner());
        addresses.chainRegistrationSender.setChainFeatureEnabled(chainId, L1_TO_L2_INTEROP_FEATURE, true);
        logs = vm.getRecordedLogs();
    }

    function _setCounterpartsOnL1(bool _set) internal returns (Vm.Log[] memory logs) {
        _mockChainProtocolVersion();
        vm.recordLogs();
        vm.prank(IGetters(zkChain).getAdmin());
        addresses.chainRegistrationSender.setL1InteropCounterparts(chainId, _set);
        logs = vm.getRecordedLogs();
    }

    /// @dev Executes on the chain the priority transaction the chain's diamond queued in `_logs`, as the chain's
    /// node would.
    function _relayToChain(Vm.Log[] memory _logs) internal {
        Vm.Log memory request = _logs.requireOneFrom(NEW_PRIORITY_REQUEST_SIGNATURE, zkChain);
        (, , , L2CanonicalTransaction memory transaction, ) = abi.decode(
            request.data,
            (uint256, bytes32, uint64, L2CanonicalTransaction, bytes[])
        );
        assertEq(address(uint160(transaction.from)), SERVICE_TRANSACTION_SENDER);
        _onChain();
        vm.prank(address(uint160(transaction.from)));
        (bool success, bytes memory returnData) = address(uint160(transaction.to)).call(transaction.data);
        assertTrue(success, string(returnData));
        _onL1();
    }

    /// @notice The counterparts the chain got are L1's real interop center and asset router.
    function test_counterpartsAreTheRealL1Contracts() public {
        _onChain();
        InteropCounterparts memory onChain = l2Bridgehub.interopCounterparts(l1ChainId);
        assertEq(onChain.interopCenter, address(l1InteropCenter));
        assertEq(onChain.assetRouter, address(addresses.sharedBridge));
        assertTrue(l2Bridgehub.isChainFeatureEnabled(L1_TO_L2_INTEROP_FEATURE));
    }

    /// @notice Both the ecosystem and the chain admin can stop the chain from executing L1's bundles, each with
    /// its own switch, and a bundle sent meanwhile executes once the switch is back.
    function test_transferToTheChain_revertWhile_switchedOffOnL1() public {
        (SentBundle memory sent, MessageInclusionProof memory proof, uint256 rootBlock) = _sendFromL1("salt");
        _onChain();
        _bringRootToTheChain(rootBlock);
        _onL1();

        _relayToChain(_setCounterpartsOnL1(false));
        _onChain();
        vm.expectRevert(abi.encodeWithSelector(InteropCounterpartsNotSet.selector, l1ChainId));
        l2InteropHandler.executeBundle(sent.encodedBundle, proof);
        _onL1();
        _relayToChain(_setCounterpartsOnL1(true));

        vm.recordLogs();
        vm.prank(addresses.chainRegistrationSender.owner());
        addresses.chainRegistrationSender.setChainFeatureEnabled(chainId, L1_TO_L2_INTEROP_FEATURE, false);
        _relayToChain(vm.getRecordedLogs());
        _onChain();
        vm.expectRevert(abi.encodeWithSelector(ChainFeatureNotEnabled.selector, L1_TO_L2_INTEROP_FEATURE));
        l2InteropHandler.executeBundle(sent.encodedBundle, proof);
        _onL1();
        _relayToChain(_enableFeatureOnL1());

        _onChain();
        l2InteropHandler.executeBundle(sent.encodedBundle, proof);
        assertEq(IERC20(l2Vault.tokenAddress(assetId)).balanceOf(l2Receiver), AMOUNT);
    }
}

/// @notice The chain settles on another L1 and has the L1 of this ecosystem as a writer source: the chain's contract
/// in this L1's Bridgehub is not a diamond, and a writer brings this L1's roots to the chain. The chain's settings
/// are written as the service transactions of its own L1's `ChainRegistrationSender`, whose checks are covered by
/// its unit test: no second L1 ecosystem is deployed here.
contract OneWayBundlesWithWriterSourceEndToEndTest is OneWayBundlesEndToEndBase {
    /// @dev The chain and the L1 it settles on, both outside this ecosystem.
    uint256 internal constant CHAIN_ID = 4242;
    uint256 internal constant SETTLEMENT_L1_CHAIN_ID = 555001;

    address internal writer = makeAddr("writer");
    address internal settlementL1AssetRouter = makeAddr("assetRouterOfTheSettlementL1");
    AlreadyDeployedChainStandIn internal chainStandIn;

    function _l1ChainIdOfTheChain() internal pure override returns (uint256) {
        return SETTLEMENT_L1_CHAIN_ID;
    }

    function _l1AssetRouterOfTheChain() internal view override returns (address) {
        return settlementL1AssetRouter;
    }

    function _registerChainOnL1() internal override {
        bytes32 chainBaseTokenAssetId = DataEncoding.encodeNTVAssetId(SETTLEMENT_L1_CHAIN_ID, ETH_TOKEN_ADDRESS);
        chainStandIn = new AlreadyDeployedChainStandIn(
            CHAIN_ID,
            address(addresses.bridgehub),
            chainBaseTokenAssetId,
            makeAddr("chainAdmin")
        );
        vm.startPrank(addresses.bridgehub.owner());
        addresses.bridgehub.addChainTypeManager(address(chainStandIn));
        addresses.bridgehub.addTokenAssetId(chainBaseTokenAssetId);
        addresses.bridgehub.registerAlreadyDeployedZKChain(CHAIN_ID, address(chainStandIn));
        vm.stopPrank();

        chainId = CHAIN_ID;
        zkChain = address(chainStandIn);
    }

    function _configureChain() internal override {
        _onChain();
        _serviceTransaction(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IL2Bridgehub.setChainFeatureEnabled, (INTEROP_ROOT_WRITERS_FEATURE, true))
        );
        _serviceTransaction(
            L2_INTEROP_ROOT_STORAGE_ADDR,
            abi.encodeCall(L2InteropRootStorage.setInteropRootWriter, (l1ChainId, writer))
        );
        _serviceTransaction(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(
                IL2Bridgehub.setInteropCounterparts,
                (l1ChainId, address(l1InteropCenter), address(addresses.sharedBridge))
            )
        );
        _onL1();
    }

    /// @dev The writer reads the root L1 recorded and writes it on the chain.
    function _bringRootToTheChain(uint256 _blockNumber) internal override {
        InteropRoot memory root = _interopRootOfL1(_blockNumber);
        vm.prank(writer);
        l2RootStorage.addInteropRootFromWriter(root);
    }

    function _settleBatchOnL1(uint256 _batchNumber, bytes32 _chainBatchRoot) internal override {
        chainStandIn.appendBatchRoot(messageRoot, _batchNumber, _chainBatchRoot);
    }

    /// @notice Only the writer brings the L1's roots: the chain does not settle on this L1, so nothing else does.
    function test_bringRoot_revertWhen_notTheWriter() public {
        (, , uint256 rootBlock) = _sendFromL1("salt");
        InteropRoot memory root = _interopRootOfL1(rootBlock);
        _onChain();

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        l2RootStorage.addInteropRootFromWriter(root);
    }
}
