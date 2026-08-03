// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {NativeTokenVaultBase} from "contracts/bridge/ntv/NativeTokenVaultBase.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";

import {IL1Nullifier, L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";

import {IBridgedStandardToken} from "contracts/bridge/interfaces/IBridgedStandardToken.sol";
import {BridgeHelper} from "contracts/bridge/BridgeHelper.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {TxStatus} from "contracts/common/Messaging.sol";
import {InvalidChainId, OriginChainIdNotFound, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {AssetNotNativeToL1, OnlyFailureStatusAllowed} from "contracts/bridge/L1BridgeContractErrors.sol";
import {InsufficientChainBalance} from "contracts/bridge/asset-tracker/AssetTrackerErrors.sol";
import {ILegacyL1AssetTracker} from "contracts/bridge/asset-tracker/ILegacyL1AssetTracker.sol";

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

    /// @dev Stands in for the pre-v31 per-chain accounting that an already-deployed vault carries into the
    /// upgrade. There is no production writer for it anymore, so the population tests have to seed it here.
    function setDeprecatedChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _balance) external {
        DEPRECATED_chainBalance[_chainId][_assetId] = _balance;
    }

    /// @dev Stands in for the v31 upgrade having pointed the vault at an `L1AssetTracker`.
    function setLegacyAssetTracker(address _tracker) external {
        __DEPRECATED_l1AssetTracker = _tracker;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}

contract L1NativeTokenVaultTest is Test {
    using stdStorage for StdStorage;

    L1NativeTokenVaultTestHelper public nativeTokenVault;
    L1AssetRouter public assetRouter;
    L1Nullifier public l1Nullifier;
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
    /// @dev A second chain, used to check that per-chain legacy amounts accumulate.
    uint256 public constant SECOND_CHAIN_ID = 271;
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
                    bridgedOut net flow accounting
    //////////////////////////////////////////////////////////////*/

    /// @dev Deposits `_amount` of the native test token through the real
    /// assetRouter->bridgeBurn path and returns the burn data used.
    function _depositNativeTestToken(uint256 _amount) internal returns (bytes memory data) {
        testToken.mint(owner, _amount);
        vm.prank(owner);
        testToken.approve(address(nativeTokenVault), _amount);

        data = DataEncoding.encodeBridgeBurnData(_amount, owner, address(testToken));
        vm.prank(address(assetRouter));
        nativeTokenVault.bridgeBurn(chainId, 0, tokenAssetId, owner, data);
    }

    function test_bridgedOut_IncreasesOnNativeDeposit() public {
        uint256 amount = 100;
        assertEq(nativeTokenVault.bridgedOut(tokenAssetId), 0);

        _depositNativeTestToken(amount);

        assertEq(nativeTokenVault.bridgedOut(tokenAssetId), amount, "outbound flow recorded");

        // Direct transfers into the vault (donations) must not affect the accounting,
        // unlike the vault's raw balanceOf.
        testToken.mint(address(this), 999);
        testToken.transfer(address(nativeTokenVault), 999);
        assertEq(nativeTokenVault.bridgedOut(tokenAssetId), amount, "donation ignored");
    }

    function test_bridgedOut_DecreasesOnNativeWithdrawal() public {
        uint256 amount = 100;
        _depositNativeTestToken(amount);

        bytes memory mintData = DataEncoding.encodeBridgeMintData({
            _originalCaller: owner,
            _remoteReceiver: owner,
            _originToken: address(testToken),
            _amount: amount,
            _erc20Metadata: BridgeHelper.getERC20Getters(address(testToken), block.chainid)
        });
        vm.prank(address(assetRouter));
        nativeTokenVault.bridgeMint(chainId, tokenAssetId, mintData);

        assertEq(nativeTokenVault.bridgedOut(tokenAssetId), 0, "net bridged-out back to zero after round trip");
    }

    function test_bridgedOut_DecreasesOnFailedDepositRefund() public {
        uint256 amount = 100;
        bytes memory data = _depositNativeTestToken(amount);

        vm.prank(address(assetRouter));
        nativeTokenVault.bridgeConfirmTransferResult(chainId, TxStatus.Failure, tokenAssetId, owner, data);

        assertEq(nativeTokenVault.bridgedOut(tokenAssetId), 0, "refund cancels the outbound flow");
    }

    function test_bridgedOut_RevertsWhenInboundExceedsOutstanding() public {
        // More of an L1-native asset coming back than is currently bridged out means bridged
        // representations were forged upstream; the transfer must be blocked, not recorded.
        uint256 amount = 100;
        _depositNativeTestToken(amount);

        bytes memory mintData = DataEncoding.encodeBridgeMintData({
            _originalCaller: owner,
            _remoteReceiver: owner,
            _originToken: address(testToken),
            _amount: amount + 1,
            _erc20Metadata: BridgeHelper.getERC20Getters(address(testToken), block.chainid)
        });
        vm.prank(address(assetRouter));
        vm.expectRevert(abi.encodeWithSelector(InsufficientChainBalance.selector, chainId, tokenAssetId, amount + 1));
        nativeTokenVault.bridgeMint(chainId, tokenAssetId, mintData);
    }

    function test_bridgedOut_UntouchedForNonNativeToken() public {
        // A bridged (non-L1-native) token: originChainId != block.chainid.
        address mockBridgedToken = makeAddr("mockBridgedToken");
        bytes32 bridgedAssetId = keccak256(abi.encode("bridgedAsset"));
        nativeTokenVault.setTokenAddress(bridgedAssetId, mockBridgedToken);
        nativeTokenVault.setOriginChainId(bridgedAssetId, 999);

        uint256 amount = 100;
        bytes memory data = DataEncoding.encodeBridgeBurnData(amount, owner, address(0));
        vm.mockCall(
            mockBridgedToken,
            abi.encodeWithSelector(IBridgedStandardToken.bridgeMint.selector, owner, amount),
            abi.encode()
        );

        vm.prank(address(assetRouter));
        nativeTokenVault.bridgeConfirmTransferResult(chainId, TxStatus.Failure, bridgedAssetId, owner, data);

        assertEq(nativeTokenVault.bridgedOut(bridgedAssetId), 0, "no accounting for a non-L1-native token");
    }

    /*//////////////////////////////////////////////////////////////
                        bridgedOut population
    //////////////////////////////////////////////////////////////*/

    function _assetIdArray(bytes32 _assetId) internal pure returns (bytes32[] memory assetIds) {
        assetIds = new bytes32[](1);
        assetIds[0] = _assetId;
    }

    function test_populateBridgedOut_FromDeprecatedChainBalance() public {
        nativeTokenVault.setDeprecatedChainBalance(chainId, tokenAssetId, 100);
        nativeTokenVault.setDeprecatedChainBalance(SECOND_CHAIN_ID, tokenAssetId, 40);

        vm.expectEmit(true, true, false, true, address(nativeTokenVault));
        emit IL1NativeTokenVault.BridgedOutPopulated(chainId, tokenAssetId, 100);
        uint256[] memory populated = nativeTokenVault.populateBridgedOut(chainId, _assetIdArray(tokenAssetId));

        assertEq(populated.length, 1, "one amount per requested asset");
        assertEq(populated[0], 100, "first chain's legacy amount returned");
        assertEq(nativeTokenVault.bridgedOut(tokenAssetId), 100, "first chain's legacy amount folded in");
        assertTrue(nativeTokenVault.bridgedOutPopulated(chainId, tokenAssetId), "pair marked as populated");
        assertFalse(
            nativeTokenVault.bridgedOutPopulated(SECOND_CHAIN_ID, tokenAssetId),
            "other chains stay unpopulated"
        );

        nativeTokenVault.populateBridgedOut(SECOND_CHAIN_ID, _assetIdArray(tokenAssetId));
        assertEq(nativeTokenVault.bridgedOut(tokenAssetId), 140, "amounts accumulate across chains");
    }

    function test_populateBridgedOut_SumsBothLegacySources() public {
        // A vault upgraded from v31 has its own mapping zeroed for assets the tracker took over, but the
        // two sources are summed so that assets the tracker never registered are not lost.
        MockLegacyL1AssetTracker tracker = new MockLegacyL1AssetTracker();
        tracker.setChainBalance(chainId, tokenAssetId, 60);
        nativeTokenVault.setLegacyAssetTracker(address(tracker));
        nativeTokenVault.setDeprecatedChainBalance(chainId, tokenAssetId, 5);

        assertEq(nativeTokenVault.legacyL1AssetTracker(), address(tracker), "tracker exposed for the scripts");
        assertEq(nativeTokenVault.legacyBridgedOutForChain(chainId, tokenAssetId), 65, "both sources counted");

        nativeTokenVault.populateBridgedOut(chainId, _assetIdArray(tokenAssetId));
        assertEq(nativeTokenVault.bridgedOut(tokenAssetId), 65);
    }

    function test_populateBridgedOut_IgnoresL1sOwnLegacyEntry() public {
        // In the legacy tracker L1's entry for an L1-native asset is the `MAX_TOKEN_BALANCE` sentinel, not a
        // balance; counting it would make `bridgedOut` meaningless.
        MockLegacyL1AssetTracker tracker = new MockLegacyL1AssetTracker();
        tracker.setChainBalance(block.chainid, tokenAssetId, type(uint256).max);
        nativeTokenVault.setLegacyAssetTracker(address(tracker));

        assertEq(nativeTokenVault.legacyBridgedOutForChain(block.chainid, tokenAssetId), 0, "L1 entry ignored");

        vm.expectRevert(InvalidChainId.selector);
        nativeTokenVault.populateBridgedOut(block.chainid, _assetIdArray(tokenAssetId));
    }

    function test_populateBridgedOut_SkipsAlreadyPopulatedPairs() public {
        nativeTokenVault.setDeprecatedChainBalance(chainId, tokenAssetId, 100);
        nativeTokenVault.populateBridgedOut(chainId, _assetIdArray(tokenAssetId));

        // Re-running a batch (e.g. after a partially mined stage3) must not double count.
        uint256[] memory populated = nativeTokenVault.populateBridgedOut(chainId, _assetIdArray(tokenAssetId));
        assertEq(populated[0], 0, "nothing populated the second time");
        assertEq(nativeTokenVault.bridgedOut(tokenAssetId), 100, "amount not double counted");
    }

    function test_populateBridgedOut_KeepsFlowsThatHappenedBeforeIt() public {
        // The population is additive, so deposits made in the window between the upgrade and stage3 survive.
        _depositNativeTestToken(30);
        nativeTokenVault.setDeprecatedChainBalance(chainId, tokenAssetId, 100);

        nativeTokenVault.populateBridgedOut(chainId, _assetIdArray(tokenAssetId));
        assertEq(nativeTokenVault.bridgedOut(tokenAssetId), 130);
    }

    function test_populateBridgedOut_RevertWhen_AssetNotNativeToL1() public {
        bytes32 bridgedAssetId = keccak256(abi.encode("bridgedAsset"));
        nativeTokenVault.setOriginChainId(bridgedAssetId, 999);

        vm.expectRevert(abi.encodeWithSelector(AssetNotNativeToL1.selector, bridgedAssetId, 999));
        nativeTokenVault.populateBridgedOut(chainId, _assetIdArray(bridgedAssetId));
    }

    function test_populateBridgedOut_UnblocksWithdrawalOfEscrowedFunds() public {
        // The point of the population: an upgraded vault holds pre-upgrade escrow but starts with
        // `bridgedOut == 0`, so every withdrawal of it would be rejected as forged.
        uint256 amount = 100;
        testToken.mint(address(nativeTokenVault), amount);
        nativeTokenVault.setDeprecatedChainBalance(chainId, tokenAssetId, amount);

        bytes memory mintData = DataEncoding.encodeBridgeMintData({
            _originalCaller: owner,
            _remoteReceiver: owner,
            _originToken: address(testToken),
            _amount: amount,
            _erc20Metadata: BridgeHelper.getERC20Getters(address(testToken), block.chainid)
        });

        vm.prank(address(assetRouter));
        vm.expectRevert(abi.encodeWithSelector(InsufficientChainBalance.selector, chainId, tokenAssetId, amount));
        nativeTokenVault.bridgeMint(chainId, tokenAssetId, mintData);

        nativeTokenVault.populateBridgedOut(chainId, _assetIdArray(tokenAssetId));

        uint256 balanceBefore = testToken.balanceOf(owner);
        vm.prank(address(assetRouter));
        nativeTokenVault.bridgeMint(chainId, tokenAssetId, mintData);

        assertEq(testToken.balanceOf(owner) - balanceBefore, amount, "withdrawal paid out");
        assertEq(nativeTokenVault.bridgedOut(tokenAssetId), 0, "withdrawal consumed the populated amount");
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}

/// @dev Read-only stand-in for the v31 `L1AssetTracker`. The contract itself no longer exists in this
/// repository, so its storage — which the population reads on an upgraded ecosystem — has to be mocked.
contract MockLegacyL1AssetTracker is ILegacyL1AssetTracker {
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) public chainBalance;
    mapping(bytes32 assetId => bool) public isAssetRegistered;

    function setChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _balance) external {
        chainBalance[_chainId][_assetId] = _balance;
        isAssetRegistered[_assetId] = true;
    }
}
