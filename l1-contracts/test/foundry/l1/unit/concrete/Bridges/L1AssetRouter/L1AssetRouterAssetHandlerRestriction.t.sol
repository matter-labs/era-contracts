// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {TxStatus} from "contracts/common/Messaging.sol";
import {AssetHandlerNotAllowed} from "contracts/bridge/L1BridgeContractErrors.sol";

/// @dev Counts the calls the router routes to it. Stands in for the native token vault, the chain asset handler
/// and a custom asset handler alike: these tests are about which handler the router lets through, not about
/// what the handlers do.
contract RecordingAssetHandler {
    uint256 public calls;

    function bridgeBurn(uint256, uint256, bytes32, address, bytes calldata) external payable returns (bytes memory) {
        ++calls;
        return hex"";
    }

    function bridgeMint(uint256, bytes32, bytes calldata) external payable {
        ++calls;
    }

    function bridgeConfirmTransferResult(uint256, TxStatus, bytes32, address, bytes calldata) external payable {
        ++calls;
    }

    function tryRegisterTokenFromBurnData(bytes calldata, bytes32) external {}
}

/// @notice The L1 asset router lets chains without interop use only the native token vault and the chain asset
/// handler. See {protocol-docs/interop-gating.md#asset-handler-restriction}.
/// @dev The router is isolated from the Bridgehub and the message root: it only reads the chain asset handler,
/// the chain's base token and the chain's interop flag from them, which are mocked.
contract L1AssetRouterAssetHandlerRestrictionTest is Test {
    enum EntryPoint {
        BridgehubDepositBaseToken,
        BridgehubDeposit,
        FinalizeDeposit,
        BridgeConfirmTransferResult
    }

    uint256 internal constant ENTRY_POINTS = 4;
    uint256 internal constant CHAIN_ID = 271;
    uint256 internal constant OTHER_CHAIN_ID = 272;

    L1AssetRouter internal router;
    RecordingAssetHandler internal nativeTokenVault;
    RecordingAssetHandler internal chainAssetHandler;
    RecordingAssetHandler internal customHandler;

    address internal owner = makeAddr("owner");
    address internal bridgehub = makeAddr("bridgehub");
    address internal nullifier = makeAddr("nullifier");
    address internal messageRoot = makeAddr("messageRoot");
    address internal depositor = makeAddr("depositor");

    bytes32 internal nativeTokenVaultAssetId;
    bytes32 internal chainAssetId;
    bytes32 internal customAssetId;

    function setUp() public {
        L1AssetRouter impl = new L1AssetRouter(makeAddr("weth"), bridgehub, nullifier);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            makeAddr("proxyAdmin"),
            abi.encodeCall(L1AssetRouter.initialize, (owner))
        );
        router = L1AssetRouter(address(proxy));

        nativeTokenVault = new RecordingAssetHandler();
        chainAssetHandler = new RecordingAssetHandler();
        customHandler = new RecordingAssetHandler();

        vm.prank(owner);
        router.setNativeTokenVault(INativeTokenVaultBase(address(nativeTokenVault)));
        nativeTokenVaultAssetId = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        chainAssetId = _registerAssetHandler("chainAsset", address(chainAssetHandler));
        customAssetId = _registerAssetHandler("customAsset", address(customHandler));

        vm.mockCall(
            bridgehub,
            abi.encodeCall(IBridgehubBase.chainAssetHandler, ()),
            abi.encode(address(chainAssetHandler))
        );
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.messageRoot, ()), abi.encode(messageRoot));
        // None of the assets moved here is the chains' base token, which `bridgehubDeposit` rejects.
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector),
            abi.encode(keccak256("baseToken"))
        );
        _mockInteropEnabled(CHAIN_ID, false);
        _mockInteropEnabled(OTHER_CHAIN_ID, false);
    }

    function test_customHandler_revertWhen_interopDisabled() public {
        for (uint256 i = 0; i < ENTRY_POINTS; ++i) {
            _expectNotAllowed(EntryPoint(i), CHAIN_ID, customAssetId, address(customHandler));
        }
        assertEq(customHandler.calls(), 0, "never reached");
    }

    function test_customHandler_allowedWhenInteropEnabled() public {
        _mockInteropEnabled(CHAIN_ID, true);

        for (uint256 i = 0; i < ENTRY_POINTS; ++i) {
            _call(EntryPoint(i), CHAIN_ID, customAssetId);
        }
        assertEq(customHandler.calls(), ENTRY_POINTS, "reached from every entry point");

        // Only the chain the transfer goes to or comes from counts.
        for (uint256 i = 0; i < ENTRY_POINTS; ++i) {
            _expectNotAllowed(EntryPoint(i), OTHER_CHAIN_ID, customAssetId, address(customHandler));
        }
    }

    function test_nativeTokenVault_allowedWhenInteropDisabled() public {
        for (uint256 i = 0; i < ENTRY_POINTS; ++i) {
            _call(EntryPoint(i), CHAIN_ID, nativeTokenVaultAssetId);
        }
        assertEq(nativeTokenVault.calls(), ENTRY_POINTS, "reached from every entry point");
    }

    function test_chainAssetHandler_allowedWhenInteropDisabled() public {
        for (uint256 i = 0; i < ENTRY_POINTS; ++i) {
            _call(EntryPoint(i), CHAIN_ID, chainAssetId);
        }
        assertEq(chainAssetHandler.calls(), ENTRY_POINTS, "reached from every entry point");
    }

    function test_unsetHandler_resolvesToNativeTokenVault() public {
        // The entry points that route an asset without a handler: the base-token deposit and the failed-deposit
        // claim require a registered one.
        bytes32 unsetAssetId = keccak256("unsetAsset");
        _call(EntryPoint.BridgehubDeposit, CHAIN_ID, unsetAssetId);
        _call(EntryPoint.FinalizeDeposit, CHAIN_ID, unsetAssetId);

        assertEq(nativeTokenVault.calls(), 2, "routed to the native token vault");
        assertEq(router.assetHandlerAddress(unsetAssetId), address(nativeTokenVault), "registered on finalization");
    }

    function _registerAssetHandler(bytes32 _assetData, address _handler) internal returns (bytes32 assetId) {
        address tracker = makeAddr(string(abi.encodePacked("tracker", _assetData)));
        vm.prank(owner);
        router.setAssetDeploymentTracker(_assetData, tracker);
        vm.prank(tracker);
        router.setAssetHandlerAddressThisChain(_assetData, _handler);
        assetId = DataEncoding.encodeAssetId(block.chainid, _assetData, tracker);
        assertEq(router.assetHandlerAddress(assetId), _handler);
    }

    function _mockInteropEnabled(uint256 _chainId, bool _enabled) internal {
        vm.mockCall(messageRoot, abi.encodeCall(IL1MessageRoot.isInteropEnabled, (_chainId)), abi.encode(_enabled));
    }

    function _expectNotAllowed(EntryPoint _entryPoint, uint256 _chainId, bytes32 _assetId, address _handler) internal {
        vm.expectRevert(abi.encodeWithSelector(AssetHandlerNotAllowed.selector, _chainId, _assetId, _handler));
        _call(_entryPoint, _chainId, _assetId);
    }

    /// @dev Moves `_assetId` to or from `_chainId` through `_entryPoint`, as its only caller would.
    function _call(EntryPoint _entryPoint, uint256 _chainId, bytes32 _assetId) internal {
        bytes memory transferData = DataEncoding.encodeBridgeBurnData(1, depositor, address(0));
        if (_entryPoint == EntryPoint.BridgehubDepositBaseToken) {
            vm.prank(bridgehub);
            router.bridgehubDepositBaseToken(_chainId, _assetId, depositor, 1);
        } else if (_entryPoint == EntryPoint.BridgehubDeposit) {
            vm.prank(bridgehub);
            router.bridgehubDeposit(
                _chainId,
                depositor,
                0,
                bytes.concat(NEW_ENCODING_VERSION, abi.encode(_assetId, transferData))
            );
        } else if (_entryPoint == EntryPoint.FinalizeDeposit) {
            vm.prank(address(router));
            router.finalizeDeposit(_chainId, _assetId, transferData);
        } else {
            vm.prank(nullifier);
            router.bridgeConfirmTransferResult(_chainId, TxStatus.Failure, depositor, _assetId, transferData);
        }
    }
}
