// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {AssetHandlerNotAllowed, ChainNotSettlingOnThisChain} from "contracts/bridge/L1BridgeContractErrors.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {
    AssetIdNotSupported,
    Unauthorized,
    UnsupportedEncodingVersion,
    ValueMismatch,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    InteropCall,
    InteropCallStarter
} from "contracts/common/Messaging.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1ChainAssetHandler} from "contracts/core/chain-asset-handler/IL1ChainAssetHandler.sol";
import {AtomicFlowPreimage} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {IL1InteropCenter} from "contracts/interop/IL1InteropCenter.sol";
import {L1InteropCenter} from "contracts/interop/L1InteropCenter.sol";
import {
    AttributeAlreadySet,
    DestinationChainNotAllowed,
    DestinationChainNotRegistered,
    InteropBundleSaltAlreadyUsed,
    InteropToSelfNotSupported,
    InteroperableAddressChainReferenceNotEmpty,
    InteroperableAddressNotEmpty,
    OneWayBundleAttributeNotSupported,
    OneWayBundleNotSingleCall,
    OneWayCallNotIndirect,
    OneWayCallNotToAssetRouter,
    OneWayCallValueNotZero
} from "contracts/interop/InteropErrors.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

import {OneWayBundlesDeployer} from "./_SharedOneWayBundlesDeployer.t.sol";

import {OneWayBundleProofBuilder} from "test-utils/OneWayBundleProofBuilder.sol";

/// @notice `L1InteropCenter` and `L1AssetRouter.initiateIndirectCall` over a real L1 ecosystem.
/// See {protocol-docs/interop.md#one-way-bundles-from-an-l1}.
contract L1InteropCenterTest is OneWayBundlesDeployer {
    uint256 internal constant AMOUNT = 1000;
    bytes32 internal constant SALT = keccak256("salt");
    uint256 internal constant UNREGISTERED_CHAIN_ID = 123456;
    /// @dev A chain id whose deploy config the fixture does not track in git.
    uint256 internal constant ERC20_BASE_TOKEN_CHAIN_ID = 12;

    function setUp() public {
        _deployOneWayBundlesEcosystem();
        _enableDestination(chainId);
        token.mint(user, AMOUNT);
        vm.prank(user);
        token.approve(address(addresses.l1NativeTokenVault), AMOUNT);
    }

    function _send(InteropCallStarter[] memory _callStarters, bytes[] memory _bundleAttributes) internal {
        vm.prank(user);
        l1InteropCenter.sendBundle(_destination(chainId), _callStarters, _bundleAttributes);
    }

    function _starters() internal view returns (InteropCallStarter[] memory) {
        return _transferStarters(address(token), AMOUNT, l2Receiver);
    }

    /*//////////////////////////////////////////////////////////////
                                Deployment
    //////////////////////////////////////////////////////////////*/

    /// @notice The fresh deployment wires the interop center into the asset router and the message root, and
    /// leaves every destination disabled.
    function test_deployment_isWiredAndDormant() public view {
        assertEq(address(l1InteropCenter.BRIDGE_HUB()), address(addresses.bridgehub));
        assertTrue(address(l1InteropCenter.ATTRIBUTE_PARSER()).code.length != 0);
        assertEq(addresses.sharedBridge.l1InteropCenter(), address(l1InteropCenter));
        assertTrue(messageRoot.isLocalMessageSender(address(l1InteropCenter)));
        assertEq(l1InteropCenter.owner(), addresses.bridgehub.owner());
        assertFalse(l1InteropCenter.destinationEnabled(zkChainIds[0]), "no destination is enabled by deployment");
        assertEq(messageRoot.currentChainBatchNumber(block.chainid), 0, "L1 sent no message");
    }

    /*//////////////////////////////////////////////////////////////
                                sendBundle
    //////////////////////////////////////////////////////////////*/

    /// @notice A bundle takes the token into the vault with the accounting of a deposit and becomes the only
    /// message of L1's next batch in the message root, without a call into the destination chain's contract.
    function test_sendBundle_locksTheTokenAndSendsALocalMessage() public {
        // `_sendTransfer` mints and approves its own amount.
        vm.prank(user);
        token.approve(address(addresses.l1NativeTokenVault), 0);
        uint256 vaultBalance = token.balanceOf(address(addresses.l1NativeTokenVault));
        // No call into the chain: the destination may be any chain registered in the Bridgehub.
        vm.expectCall(zkChain, bytes(""), 0);

        SentBundle memory sent = _sendTransfer(AMOUNT, SALT);

        assertEq(token.balanceOf(address(addresses.l1NativeTokenVault)), vaultBalance + AMOUNT);
        assertEq(addresses.l1NativeTokenVault.bridgedOut(assetId), AMOUNT);
        assertEq(addresses.l1NativeTokenVault.chainTotalDeposited(chainId, assetId), AMOUNT);
        assertTrue(l1InteropCenter.isInteropBundleSaltUsed(user, SALT));

        assertEq(sent.bundle.version, INTEROP_BUNDLE_VERSION);
        assertEq(sent.bundle.sourceChainId, block.chainid);
        assertEq(sent.bundle.destinationChainId, chainId);
        assertEq(sent.bundle.destinationBaseTokenAssetId, addresses.bridgehub.baseTokenAssetId(chainId));
        assertEq(
            sent.bundle.interopBundleSalt,
            keccak256(abi.encodePacked(address(l1InteropCenter), user, SALT)),
            "the salt binds the interop center and the sender"
        );
        assertEq(sent.bundle.bundleAttributes.salt, SALT);
        assertEq(sent.bundle.bundleAttributes.executionAddress.length, 0);
        assertEq(sent.bundle.bundleAttributes.unbundlerAddress.length, 0);
        assertFalse(sent.bundle.bundleAttributes.useFixedFee);

        assertEq(sent.bundle.calls.length, 1);
        InteropCall memory interopCall = sent.bundle.calls[0];
        assertEq(interopCall.version, INTEROP_CALL_VERSION);
        assertFalse(interopCall.shadowAccount);
        assertEq(interopCall.to, L2_ASSET_ROUTER_ADDR, "the destination chain's real asset router");
        assertEq(interopCall.from, address(addresses.sharedBridge), "this L1's real asset router");
        assertEq(interopCall.value, 0);
        assertEq(
            interopCall.data,
            abi.encodeCall(
                AssetRouterBase.finalizeDeposit,
                (
                    block.chainid,
                    assetId,
                    DataEncoding.encodeBridgeMintData({
                        _originalCaller: user,
                        _remoteReceiver: l2Receiver,
                        _originToken: address(token),
                        _amount: AMOUNT,
                        _erc20Metadata: addresses.l1NativeTokenVault.getERC20Getters(address(token), block.chainid)
                    })
                )
            ),
            "the call a deposit through the Bridgehub makes"
        );

        assertEq(sent.batchNumber, 1);
        assertEq(messageRoot.currentChainBatchNumber(block.chainid), 1);
        assertEq(
            messageRoot.chainBatchRoots(block.chainid, 1),
            OneWayBundleProofBuilder.chainBatchRoot(
                OneWayBundleProofBuilder.messageLeaf(
                    address(l1InteropCenter),
                    bytes.concat(bytes1(0x01), sent.encodedBundle)
                )
            )
        );
    }

    /// @notice Each bundle is its own batch, and a salt belongs to its sender.
    function test_sendBundle_secondBundleIsTheNextBatch() public {
        vm.prank(user);
        token.approve(address(addresses.l1NativeTokenVault), 0);
        SentBundle memory first = _sendTransfer(AMOUNT, SALT);
        SentBundle memory second = _sendTransfer(AMOUNT, keccak256("other salt"));

        assertEq(first.batchNumber, 1);
        assertEq(second.batchNumber, 2);
        assertNotEq(first.bundleHash, second.bundleHash);
        assertEq(addresses.l1NativeTokenVault.chainTotalDeposited(chainId, assetId), 2 * AMOUNT);
    }

    function test_sendBundle_revertWhen_saltReused() public {
        _send(_starters(), _saltAttribute(SALT));
        vm.expectRevert(abi.encodeWithSelector(InteropBundleSaltAlreadyUsed.selector, user, SALT));
        _send(_starters(), _saltAttribute(SALT));
    }

    function test_sendBundle_revertWhen_paused() public {
        vm.prank(l1InteropCenter.owner());
        l1InteropCenter.pause();
        vm.expectRevert("Pausable: paused");
        _send(_starters(), _saltAttribute(SALT));

        vm.prank(l1InteropCenter.owner());
        l1InteropCenter.unpause();
        _send(_starters(), _saltAttribute(SALT));
    }

    function test_sendBundle_revertWhen_destinationHasAnAddress() public {
        bytes memory destination = InteroperableAddress.formatEvmV1(chainId, makeAddr("someAddress"));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InteroperableAddressNotEmpty.selector, destination));
        l1InteropCenter.sendBundle(destination, _starters(), _saltAttribute(SALT));
    }

    function test_sendBundle_revertWhen_destinationIsThisChain() public {
        vm.prank(user);
        vm.expectRevert(InteropToSelfNotSupported.selector);
        l1InteropCenter.sendBundle(_destination(block.chainid), _starters(), _saltAttribute(SALT));
    }

    function test_sendBundle_revertWhen_destinationNotRegistered() public {
        vm.prank(l1InteropCenter.owner());
        l1InteropCenter.setDestinationEnabled(UNREGISTERED_CHAIN_ID, true);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(DestinationChainNotRegistered.selector, UNREGISTERED_CHAIN_ID));
        l1InteropCenter.sendBundle(_destination(UNREGISTERED_CHAIN_ID), _starters(), _saltAttribute(SALT));
    }

    /// @notice Sending is off for every chain until the owner enables it, and off again once disabled.
    function test_sendBundle_revertWhen_destinationNotEnabled() public {
        uint256 otherChainId = zkChainIds[0];
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(DestinationChainNotAllowed.selector, otherChainId));
        l1InteropCenter.sendBundle(_destination(otherChainId), _starters(), _saltAttribute(SALT));

        vm.prank(l1InteropCenter.owner());
        l1InteropCenter.setDestinationEnabled(chainId, false);
        vm.expectRevert(abi.encodeWithSelector(DestinationChainNotAllowed.selector, chainId));
        _send(_starters(), _saltAttribute(SALT));
    }

    /// @dev Mock justification: moving a chain to another settlement layer needs the whole migration flow, which
    /// is out of scope here; only the Bridgehub's answer matters to the interop center.
    function test_sendBundle_revertWhen_destinationSettlesElsewhere() public {
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeCall(IBridgehubBase.settlementLayer, (chainId)),
            abi.encode(block.chainid + 1)
        );
        vm.expectRevert(abi.encodeWithSelector(ChainNotSettlingOnThisChain.selector, chainId));
        _send(_starters(), _saltAttribute(SALT));
    }

    /// @dev Mock justification: as in {test_sendBundle_revertWhen_destinationSettlesElsewhere}.
    function test_sendBundle_revertWhen_destinationIsMigrating() public {
        vm.mockCall(
            addresses.bridgehub.chainAssetHandler(),
            abi.encodeCall(IL1ChainAssetHandler.isMigrationInProgress, (chainId)),
            abi.encode(true)
        );
        vm.expectRevert(abi.encodeWithSelector(ChainNotSettlingOnThisChain.selector, chainId));
        _send(_starters(), _saltAttribute(SALT));
    }

    function test_sendBundle_revertWhen_notASingleCall() public {
        InteropCallStarter[] memory one = _starters();
        InteropCallStarter[] memory two = new InteropCallStarter[](2);
        two[0] = one[0];
        two[1] = one[0];
        vm.expectRevert(abi.encodeWithSelector(OneWayBundleNotSingleCall.selector, 2));
        _send(two, _saltAttribute(SALT));

        vm.expectRevert(abi.encodeWithSelector(OneWayBundleNotSingleCall.selector, 0));
        _send(new InteropCallStarter[](0), _saltAttribute(SALT));
    }

    function test_sendBundle_revertWhen_callIsDirect() public {
        InteropCallStarter[] memory starters = _starters();
        starters[0].callAttributes = new bytes[](0);
        vm.expectRevert(OneWayCallNotIndirect.selector);
        _send(starters, _saltAttribute(SALT));
    }

    /// @notice A bundle carries no value: neither value for the call on the destination nor value for the asset
    /// router on L1, and `sendBundle` is not payable.
    function test_sendBundle_revertWhen_callCarriesValue() public {
        InteropCallStarter[] memory starters = _starters();
        starters[0].callAttributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (5));
        vm.expectRevert(abi.encodeWithSelector(OneWayCallValueNotZero.selector, 5));
        _send(starters, _saltAttribute(SALT));

        starters[0].callAttributes = new bytes[](2);
        starters[0].callAttributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));
        starters[0].callAttributes[1] = abi.encodeCall(IERC7786Attributes.interopCallValue, (7));
        vm.expectRevert(abi.encodeWithSelector(OneWayCallValueNotZero.selector, 7));
        _send(starters, _saltAttribute(SALT));

        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool success, ) = address(l1InteropCenter).call{value: 1}(
            abi.encodeCall(L1InteropCenter.sendBundle, (_destination(chainId), _starters(), _saltAttribute(SALT)))
        );
        assertFalse(success, "sendBundle takes no value");
    }

    function test_sendBundle_revertWhen_callNotToAssetRouter() public {
        InteropCallStarter[] memory starters = _starters();
        address other = makeAddr("otherContract");
        starters[0].to = InteroperableAddress.formatEvmV1(other);
        vm.expectRevert(abi.encodeWithSelector(OneWayCallNotToAssetRouter.selector, other));
        _send(starters, _saltAttribute(SALT));
    }

    /// @notice The call goes to the bundle's destination: a call starter that names a chain of its own is refused,
    /// as on L2.
    function test_sendBundle_revertWhen_callNamesAChain() public {
        InteropCallStarter[] memory starters = _starters();
        starters[0].to = InteroperableAddress.formatEvmV1(zkChainIds[0], address(addresses.sharedBridge));
        vm.expectRevert(abi.encodeWithSelector(InteroperableAddressChainReferenceNotEmpty.selector, starters[0].to));
        _send(starters, _saltAttribute(SALT));
    }

    /// @notice Only the salt is a bundle attribute of a one-way bundle: nobody is named to execute or unbundle it,
    /// it pays no fee, and it is never a leg of an atomic flow.
    function test_sendBundle_revertWhen_bundleAttributeNotSupported() public {
        bytes memory someAddress = InteroperableAddress.formatEvmV1(chainId, makeAddr("someAddress"));
        AtomicFlowPreimage memory flowPreimage;
        bytes[4] memory unsupported = [
            abi.encodeCall(IERC7786Attributes.executionAddress, (someAddress)),
            abi.encodeCall(IERC7786Attributes.unbundlerAddress, (someAddress)),
            abi.encodeCall(IERC7786Attributes.useFixedFee, (false)),
            abi.encodeCall(IERC7786Attributes.atomicBundle, (flowPreimage, 0))
        ];
        for (uint256 i = 0; i < unsupported.length; ++i) {
            bytes[] memory attributes = new bytes[](2);
            attributes[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (SALT));
            attributes[1] = unsupported[i];
            vm.expectRevert(abi.encodeWithSelector(OneWayBundleAttributeNotSupported.selector, bytes4(unsupported[i])));
            _send(_starters(), attributes);
        }
    }

    function test_sendBundle_revertWhen_saltGivenTwice() public {
        bytes[] memory attributes = new bytes[](2);
        attributes[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (SALT));
        attributes[1] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (keccak256("other salt")));
        vm.expectRevert(
            abi.encodeWithSelector(AttributeAlreadySet.selector, IERC7786Attributes.interopBundleSalt.selector)
        );
        _send(_starters(), attributes);
    }

    /// @notice A bundle has no refund path, so a transfer the destination could never mint is refused when sent.
    function test_sendBundle_revertWhen_receiverIsZero() public {
        vm.expectRevert(ZeroAddress.selector);
        _send(_transferStarters(address(token), AMOUNT, address(0)), _saltAttribute(SALT));
    }

    /// @notice ETH needs value, which a bundle does not carry.
    function test_sendBundle_revertWhen_assetIsEth() public {
        // The second chain of the fixture has a base token other than ETH, so only the missing value stops ETH.
        _deployZKChain(address(token), ERC20_BASE_TOKEN_CHAIN_ID);
        uint256 erc20ChainId = ERC20_BASE_TOKEN_CHAIN_ID;
        _enableDestination(erc20ChainId);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ValueMismatch.selector, AMOUNT, 0));
        l1InteropCenter.sendBundle(
            _destination(erc20ChainId),
            _transferStarters(ETH_TOKEN_ADDRESS, AMOUNT, l2Receiver),
            _saltAttribute(SALT)
        );
    }

    /// @notice The destination's base token is minted by deposits only.
    function test_sendBundle_revertWhen_assetIsTheDestinationBaseToken() public {
        _deployZKChain(address(token), ERC20_BASE_TOKEN_CHAIN_ID);
        uint256 erc20ChainId = ERC20_BASE_TOKEN_CHAIN_ID;
        _enableDestination(erc20ChainId);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AssetIdNotSupported.selector, assetId));
        l1InteropCenter.sendBundle(_destination(erc20ChainId), _starters(), _saltAttribute(SALT));
    }

    /*//////////////////////////////////////////////////////////////
                        setDestinationEnabled
    //////////////////////////////////////////////////////////////*/

    function test_setDestinationEnabled_byOwner() public {
        uint256 otherChainId = zkChainIds[0];
        vm.expectEmit(true, false, false, true, address(l1InteropCenter));
        emit IL1InteropCenter.DestinationEnabledSet(otherChainId, true);
        vm.prank(l1InteropCenter.owner());
        l1InteropCenter.setDestinationEnabled(otherChainId, true);
        assertTrue(l1InteropCenter.destinationEnabled(otherChainId));

        vm.expectEmit(true, false, false, true, address(l1InteropCenter));
        emit IL1InteropCenter.DestinationEnabledSet(otherChainId, false);
        vm.prank(l1InteropCenter.owner());
        l1InteropCenter.setDestinationEnabled(otherChainId, false);
        assertFalse(l1InteropCenter.destinationEnabled(otherChainId));
    }

    function test_setDestinationEnabled_revertWhen_notOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        l1InteropCenter.setDestinationEnabled(chainId, true);
    }

    function test_pause_revertWhen_notOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        l1InteropCenter.pause();
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        l1InteropCenter.unpause();
    }

    /*//////////////////////////////////////////////////////////////
                    L1AssetRouter.initiateIndirectCall
    //////////////////////////////////////////////////////////////*/

    function testFuzz_initiateIndirectCall_revertWhen_notInteropCenter(address _caller) public {
        vm.assume(_caller != address(l1InteropCenter));
        vm.assume(_caller != ecosystemAddresses.shared.transparentProxyAdmin);
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        addresses.sharedBridge.initiateIndirectCall(chainId, user, _starters()[0].data);
    }

    function test_initiateIndirectCall_revertWhen_routerPaused() public {
        vm.prank(addresses.sharedBridge.owner());
        addresses.sharedBridge.pause();
        vm.expectRevert("Pausable: paused");
        _send(_starters(), _saltAttribute(SALT));
    }

    /// @notice The router checks the settlement layer itself, whatever its caller checked.
    /// @dev Mock justification: as in {test_sendBundle_revertWhen_destinationSettlesElsewhere}.
    function test_initiateIndirectCall_revertWhen_chainSettlesElsewhere() public {
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeCall(IBridgehubBase.settlementLayer, (chainId)),
            abi.encode(block.chainid + 1)
        );
        vm.prank(address(l1InteropCenter));
        vm.expectRevert(abi.encodeWithSelector(ChainNotSettlingOnThisChain.selector, chainId));
        addresses.sharedBridge.initiateIndirectCall(chainId, user, _starters()[0].data);
    }

    function test_initiateIndirectCall_revertWhen_legacyEncoding() public {
        bytes memory data = _starters()[0].data;
        data[0] = 0x00;
        vm.prank(address(l1InteropCenter));
        vm.expectRevert(UnsupportedEncodingVersion.selector);
        addresses.sharedBridge.initiateIndirectCall(chainId, user, data);
    }

    /// @notice A chain without interop only receives assets of the native token vault.
    /// See {protocol-docs/interop-gating.md#asset-handler-restriction}.
    function test_initiateIndirectCall_revertWhen_customAssetHandler() public {
        address deploymentTracker = makeAddr("deploymentTracker");
        address customHandler = makeAddr("customHandler");
        bytes32 registrationData = keccak256("customAsset");
        vm.prank(addresses.sharedBridge.owner());
        addresses.sharedBridge.setAssetDeploymentTracker(registrationData, deploymentTracker);
        vm.prank(deploymentTracker);
        addresses.sharedBridge.setAssetHandlerAddressThisChain(registrationData, customHandler);
        bytes32 customAssetId = DataEncoding.encodeAssetId(block.chainid, registrationData, deploymentTracker);

        InteropCallStarter[] memory starters = _starters();
        starters[0].data = DataEncoding.encodeAssetRouterBridgehubDepositData(customAssetId, hex"1234");
        vm.expectRevert(abi.encodeWithSelector(AssetHandlerNotAllowed.selector, chainId, customAssetId, customHandler));
        _send(starters, _saltAttribute(SALT));
    }

    /*//////////////////////////////////////////////////////////////
                    L1AssetRouter.setL1InteropCenter
    //////////////////////////////////////////////////////////////*/

    /// @notice The interop center can be replaced, by the owner or by the upgrade authority: a new address is how
    /// the roots written for the old one are left behind.
    function test_setL1InteropCenter_replacesTheCenter() public {
        address newCenter = makeAddr("newCenter");
        vm.expectEmit(true, false, false, false, address(addresses.sharedBridge));
        emit IL1AssetRouter.L1InteropCenterSet(newCenter);
        vm.prank(addresses.sharedBridge.owner());
        addresses.sharedBridge.setL1InteropCenter(newCenter);
        assertEq(addresses.sharedBridge.l1InteropCenter(), newCenter);

        // The old center no longer reaches the router.
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(l1InteropCenter)));
        _send(_starters(), _saltAttribute(SALT));

        address upgradeAuthority = ProxyAdmin(ecosystemAddresses.shared.transparentProxyAdmin).owner();
        vm.prank(upgradeAuthority);
        addresses.sharedBridge.setL1InteropCenter(address(l1InteropCenter));
        assertEq(addresses.sharedBridge.l1InteropCenter(), address(l1InteropCenter));
    }

    function test_setL1InteropCenter_revertWhen_zeroAddress() public {
        vm.prank(addresses.sharedBridge.owner());
        vm.expectRevert(ZeroAddress.selector);
        addresses.sharedBridge.setL1InteropCenter(address(0));
    }

    function test_setL1InteropCenter_revertWhen_notOwnerNorUpgrader() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, user));
        addresses.sharedBridge.setL1InteropCenter(makeAddr("newCenter"));
    }
}
