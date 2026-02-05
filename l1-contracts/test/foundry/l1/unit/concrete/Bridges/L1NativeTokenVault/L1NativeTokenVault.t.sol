// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {NativeTokenVaultBase} from "contracts/bridge/ntv/NativeTokenVaultBase.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IL1Nullifier, L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {L1AssetTracker} from "contracts/bridge/asset-tracker/L1AssetTracker.sol";
import {IAssetTrackerBase} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {IL1AssetHandler} from "contracts/bridge/interfaces/IL1AssetHandler.sol";
import {IBridgedStandardToken} from "contracts/bridge/interfaces/IBridgedStandardToken.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {TxStatus} from "contracts/common/Messaging.sol";
import {OriginChainIdNotFound, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {OnlyFailureStatusAllowed} from "contracts/bridge/L1BridgeContractErrors.sol";

/// @dev Test helper contract that exposes internal functions
contract L1NativeTokenVaultTestHelper is L1NativeTokenVault {
    constructor(
        address _wethToken,
        address _assetRouter,
        IL1Nullifier _l1Nullifier
    ) L1NativeTokenVault(_wethToken, _assetRouter, _l1Nullifier) {}

    function getOriginChainIdPublic(bytes32 _assetId) external view returns (uint256) {
        return _getOriginChainId(_assetId);
    }

    function registerTokenIfBridgedLegacyPublic(address _token) external returns (bytes32) {
        return _registerTokenIfBridgedLegacy(_token);
    }

    // Expose internal state setters for testing
    function setOriginChainId(bytes32 _assetId, uint256 _chainId) external {
        originChainId[_assetId] = _chainId;
    }

    function setTokenAddress(bytes32 _assetId, address _token) external {
        tokenAddress[_assetId] = _token;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}

contract L1NativeTokenVaultTest is Test {
    using stdStorage for StdStorage;

    L1NativeTokenVaultTestHelper public nativeTokenVault;
    L1AssetRouter public assetRouter;
    L1Nullifier public l1Nullifier;
    L1AssetTracker public l1AssetTracker;
    TestnetERC20Token public testToken;

    address public owner;
    address public proxyAdmin;
    address public bridgehubAddress;
    address public messageRootAddress;
    address public interopCenterAddress;
    address public chainAssetHandler;
    address public l1WethAddress;
    address public tokenBeacon;

    uint256 public chainId;
    uint256 public eraChainId;
    address public eraDiamondProxy;

    bytes32 public tokenAssetId;
    bytes32 public ETH_TOKEN_ASSET_ID;

    function setUp() public {
        owner = makeAddr("owner");
        proxyAdmin = makeAddr("proxyAdmin");
        bridgehubAddress = makeAddr("bridgehub");
        messageRootAddress = makeAddr("messageRoot");
        interopCenterAddress = makeAddr("interopCenter");
        chainAssetHandler = makeAddr("chainAssetHandler");
        l1WethAddress = makeAddr("weth");
        tokenBeacon = makeAddr("tokenBeacon");

        chainId = 1;
        eraChainId = 9;
        eraDiamondProxy = makeAddr("eraDiamondProxy");

        // Deploy L1Nullifier
        L1NullifierDev l1NullifierImpl = new L1NullifierDev({
            _bridgehub: IL1Bridgehub(bridgehubAddress),
            _messageRoot: IMessageRootBase(messageRootAddress),
            _interopCenter: IInteropCenter(interopCenterAddress),
            _eraChainId: eraChainId,
            _eraDiamondProxy: eraDiamondProxy
        });
        TransparentUpgradeableProxy l1NullifierProxy = new TransparentUpgradeableProxy(
            address(l1NullifierImpl),
            proxyAdmin,
            abi.encodeWithSelector(L1Nullifier.initialize.selector, owner, 1, 1, 1, 0)
        );
        l1Nullifier = L1Nullifier(payable(l1NullifierProxy));

        // Deploy L1AssetRouter
        L1AssetRouter assetRouterImpl = new L1AssetRouter({
            _l1WethToken: l1WethAddress,
            _bridgehub: bridgehubAddress,
            _l1Nullifier: address(l1Nullifier),
            _eraChainId: eraChainId,
            _eraDiamondProxy: eraDiamondProxy
        });
        TransparentUpgradeableProxy assetRouterProxy = new TransparentUpgradeableProxy(
            address(assetRouterImpl),
            proxyAdmin,
            abi.encodeWithSelector(L1AssetRouter.initialize.selector, owner)
        );
        assetRouter = L1AssetRouter(payable(assetRouterProxy));

        // Deploy L1NativeTokenVault test helper
        L1NativeTokenVaultTestHelper nativeTokenVaultImpl = new L1NativeTokenVaultTestHelper({
            _wethToken: l1WethAddress,
            _assetRouter: address(assetRouter),
            _l1Nullifier: l1Nullifier
        });
        TransparentUpgradeableProxy nativeTokenVaultProxy = new TransparentUpgradeableProxy(
            address(nativeTokenVaultImpl),
            proxyAdmin,
            abi.encodeWithSelector(L1NativeTokenVault.initialize.selector, owner, tokenBeacon)
        );
        nativeTokenVault = L1NativeTokenVaultTestHelper(payable(nativeTokenVaultProxy));

        // Setup mocks
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(address(chainAssetHandler))
        );
        vm.mockCall(
            chainAssetHandler,
            abi.encodeWithSelector(IChainAssetHandlerBase.migrationNumber.selector),
            abi.encode(0)
        );

        // Deploy L1AssetTracker
        l1AssetTracker = new L1AssetTracker(bridgehubAddress, address(nativeTokenVault), messageRootAddress);

        // Set asset tracker
        vm.prank(owner);
        nativeTokenVault.setAssetTracker(address(l1AssetTracker));

        // Setup L1Nullifier
        vm.prank(owner);
        l1Nullifier.setL1AssetRouter(address(assetRouter));
        vm.prank(owner);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(address(nativeTokenVault)));

        // Deploy and setup test token
        testToken = new TestnetERC20Token("Test Token", "TST", 18);
        tokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, address(testToken));
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);

        // Set NTV in asset router
        vm.prank(owner);
        assetRouter.setNativeTokenVault(INativeTokenVaultBase(address(nativeTokenVault)));

        // Register tokens
        vm.prank(address(nativeTokenVault));
        nativeTokenVault.registerToken(address(testToken));
        nativeTokenVault.registerEthToken();
    }

    /*//////////////////////////////////////////////////////////////
                        _getOriginChainId Tests
    //////////////////////////////////////////////////////////////*/

    function test_getOriginChainId_ReturnsStoredChainId() public {
        // When originChainId is already stored, it should return that value
        uint256 storedChainId = 42;
        nativeTokenVault.setOriginChainId(tokenAssetId, storedChainId);

        uint256 result = nativeTokenVault.getOriginChainIdPublic(tokenAssetId);
        assertEq(result, storedChainId);
    }

    function test_getOriginChainId_ReturnsBlockChainIdForETH() public {
        // When token is ETH_TOKEN_ADDRESS, should return block.chainid
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        nativeTokenVault.setTokenAddress(ethAssetId, ETH_TOKEN_ADDRESS);

        uint256 result = nativeTokenVault.getOriginChainIdPublic(ethAssetId);
        assertEq(result, block.chainid);
    }

    function test_getOriginChainId_ReturnsBlockChainIdWhenNTVHasBalance() public {
        // When NTV has balance of the token, should return block.chainid
        testToken.mint(address(nativeTokenVault), 1000);
        nativeTokenVault.setTokenAddress(tokenAssetId, address(testToken));

        uint256 result = nativeTokenVault.getOriginChainIdPublic(tokenAssetId);
        assertEq(result, block.chainid);
    }

    function test_getOriginChainId_ReturnsBlockChainIdWhenNullifierHasBalance() public {
        // When L1Nullifier has balance of the token, should return block.chainid
        TestnetERC20Token token2 = new TestnetERC20Token("Test2", "TST2", 18);
        token2.mint(address(l1Nullifier), 1000);

        bytes32 token2AssetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token2));
        nativeTokenVault.setTokenAddress(token2AssetId, address(token2));

        uint256 result = nativeTokenVault.getOriginChainIdPublic(token2AssetId);
        assertEq(result, block.chainid);
    }

    function test_getOriginChainId_ReturnsZeroWhenNoBalance() public {
        // When neither NTV nor Nullifier has balance and origin not stored, should return 0
        TestnetERC20Token token3 = new TestnetERC20Token("Test3", "TST3", 18);
        // Don't mint any tokens

        bytes32 token3AssetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token3));
        nativeTokenVault.setTokenAddress(token3AssetId, address(token3));

        uint256 result = nativeTokenVault.getOriginChainIdPublic(token3AssetId);
        assertEq(result, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    _registerTokenIfBridgedLegacy Tests
    //////////////////////////////////////////////////////////////*/

    function test_registerTokenIfBridgedLegacy_ReturnsZero() public {
        // On L1, there are no legacy tokens, so this should always return bytes32(0)
        bytes32 result = nativeTokenVault.registerTokenIfBridgedLegacyPublic(address(testToken));
        assertEq(result, bytes32(0));
    }

    function test_registerTokenIfBridgedLegacy_ReturnsZeroForAnyToken() public {
        // Test with a random address
        address randomToken = makeAddr("randomToken");
        bytes32 result = nativeTokenVault.registerTokenIfBridgedLegacyPublic(randomToken);
        assertEq(result, bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                    bridgeConfirmTransferResult Tests
    //////////////////////////////////////////////////////////////*/

    function test_bridgeConfirmTransferResult_RevertWhen_NotFailure() public {
        bytes memory data = abi.encode(100, address(0), bytes(""));

        vm.prank(address(assetRouter));
        vm.expectRevert(OnlyFailureStatusAllowed.selector);
        nativeTokenVault.bridgeConfirmTransferResult(
            chainId,
            TxStatus.Success, // Should revert for non-Failure status
            tokenAssetId,
            owner,
            data
        );
    }

    function test_bridgeConfirmTransferResult_RevertWhen_OriginChainNotFound() public {
        // To test OriginChainIdNotFound, we need a token where:
        // 1. tokenAddress[_assetId] is not ETH_TOKEN_ADDRESS
        // 2. originChainId[_assetId] is 0 (not set)
        // 3. _getOriginChainId returns 0 (no balance in NTV or Nullifier)

        // Create a custom assetId and token that is set up manually (not through registerToken)
        TestnetERC20Token unknownToken = new TestnetERC20Token("Unknown", "UNK", 18);
        bytes32 unknownAssetId = keccak256("unknownAssetWithNoOrigin");

        // Set token address mapping but DO NOT set originChainId (so it remains 0)
        nativeTokenVault.setTokenAddress(unknownAssetId, address(unknownToken));
        // Don't mint any tokens to NTV or Nullifier (so _getOriginChainId returns 0)

        // Create bridge burn data
        bytes memory data = DataEncoding.encodeBridgeBurnData(100, owner, address(0));

        // Mock the asset tracker call
        vm.mockCall(
            address(l1AssetTracker),
            abi.encodeWithSelector(L1AssetTracker.handleChainBalanceDecreaseOnL1.selector),
            abi.encode()
        );

        vm.prank(address(assetRouter));
        vm.expectRevert(OriginChainIdNotFound.selector);
        nativeTokenVault.bridgeConfirmTransferResult(chainId, TxStatus.Failure, unknownAssetId, owner, data);
    }

    function test_bridgeConfirmTransferResult_BridgeMintPath() public {
        // Test the path where originChainId != block.chainid but != 0
        // This triggers IBridgedStandardToken.bridgeMint

        // Create a mock bridged token
        address mockBridgedToken = makeAddr("mockBridgedToken");
        bytes32 bridgedAssetId = keccak256(abi.encode("bridgedAsset"));
        uint256 otherChainId = 999;

        // Set up the token mapping
        nativeTokenVault.setTokenAddress(bridgedAssetId, mockBridgedToken);
        nativeTokenVault.setOriginChainId(bridgedAssetId, otherChainId);

        uint256 amount = 100;
        bytes memory data = DataEncoding.encodeBridgeBurnData(amount, owner, address(0));

        // Mock the asset tracker call
        vm.mockCall(
            address(l1AssetTracker),
            abi.encodeWithSelector(L1AssetTracker.handleChainBalanceDecreaseOnL1.selector),
            abi.encode()
        );

        // Mock the bridgeMint call
        vm.mockCall(
            mockBridgedToken,
            abi.encodeWithSelector(IBridgedStandardToken.bridgeMint.selector, owner, amount),
            abi.encode()
        );

        vm.prank(address(assetRouter));
        nativeTokenVault.bridgeConfirmTransferResult(chainId, TxStatus.Failure, bridgedAssetId, owner, data);
    }

    /*//////////////////////////////////////////////////////////////
                        onlyAssetTracker modifier Tests
    //////////////////////////////////////////////////////////////*/

    function test_migrateTokenBalanceToAssetTracker_RevertWhen_NotAssetTracker() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        nativeTokenVault.migrateTokenBalanceToAssetTracker(chainId, tokenAssetId);
    }

    function test_migrateTokenBalanceToAssetTracker_Success() public {
        // This should work when called by asset tracker
        vm.prank(address(l1AssetTracker));
        uint256 result = nativeTokenVault.migrateTokenBalanceToAssetTracker(chainId, tokenAssetId);
        assertEq(result, 0); // No deprecated balance set
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
