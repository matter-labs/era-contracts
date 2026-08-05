// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {BridgedOutPopulationLib} from "deploy-scripts/upgrade/default-upgrade/BridgedOutPopulationLib.sol";

import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1Nullifier, L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {ILegacyL1AssetTracker} from "contracts/bridge/asset-tracker/ILegacyL1AssetTracker.sol";
import {MAX_TOKEN_BALANCE} from "contracts/common/Config.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

/// @dev Exposes a setter for the pre-upgrade accounting that the population reads. There is no production
/// writer for it anymore (the v31 asset tracker was removed), so it has to be seeded from the test.
contract L1NativeTokenVaultWithLegacyState is L1NativeTokenVault {
    constructor(
        address _wethToken,
        address _assetRouter,
        IL1Nullifier _l1Nullifier
    ) L1NativeTokenVault(_wethToken, _assetRouter, _l1Nullifier) {}

    function setDeprecatedChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _balance) external {
        DEPRECATED_chainBalance[_chainId][_assetId] = _balance;
    }

    function setLegacyAssetTracker(address _tracker) external {
        __DEPRECATED_l1AssetTracker = _tracker;
    }

    /// @dev Registers an asset native to another chain, including in the `bridgedTokens` enumeration the
    /// population iterates over. Reaching this state through `bridgeMint` would need a full withdrawal flow.
    function registerRemoteAsset(bytes32 _assetId, address _token, uint256 _originChainId) external {
        _setNewTokenStorage(_assetId, _token, _originChainId);
    }

    function test() internal virtual {}
}

/// @dev Makes the library callable externally so that reverts can be asserted with `vm.expectRevert`.
contract BridgedOutPopulationRunner {
    function run(address _bridgehub) external returns (bytes32[] memory, uint256[] memory) {
        return BridgedOutPopulationLib.populateBridgedOutForAllAssets(_bridgehub);
    }

    function runWithBatchSize(
        address _bridgehub,
        uint256 _assetsPerCall
    ) external returns (bytes32[] memory, uint256[] memory) {
        return BridgedOutPopulationLib.populateBridgedOutForAllAssets(_bridgehub, _assetsPerCall);
    }

    function test() internal virtual {}
}

/// @dev Stand-in for the removed v31 `L1AssetTracker`. Only the two views the population reads are needed.
contract LegacyL1AssetTrackerStub is ILegacyL1AssetTracker {
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) public chainBalance;
    mapping(bytes32 assetId => bool) public isAssetRegistered;

    function setChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _balance) external {
        chainBalance[_chainId][_assetId] = _balance;
        isAssetRegistered[_assetId] = true;
    }
}

/// @notice Tests the stage3 driver of the `bridgedOut` population.
/// @dev The bridgehub and its chain list are mocked: the driver only needs them to discover the vault and
/// the registered chains, and a full ecosystem deployment cannot carry pre-upgrade legacy state anyway.
contract BridgedOutPopulationLibTest is Test {
    L1NativeTokenVaultWithLegacyState internal ntv;
    L1AssetRouter internal assetRouter;
    L1Nullifier internal l1Nullifier;
    TestnetERC20Token internal firstToken;
    TestnetERC20Token internal secondToken;
    LegacyL1AssetTrackerStub internal legacyTracker;
    BridgedOutPopulationRunner internal runner;

    address internal owner;
    address internal bridgehub;

    bytes32 internal firstAssetId;
    bytes32 internal secondAssetId;

    uint256 internal constant FIRST_CHAIN_ID = 270;
    uint256 internal constant SECOND_CHAIN_ID = 271;

    function setUp() public {
        owner = makeAddr("owner");
        bridgehub = makeAddr("bridgehub");
        address proxyAdmin = makeAddr("proxyAdmin");
        address eraDiamondProxy = makeAddr("eraDiamondProxy");
        address weth = makeAddr("weth");
        address tokenBeacon = makeAddr("tokenBeacon");
        address chainAssetHandler = makeAddr("chainAssetHandler");
        uint256 eraChainId = 9;

        L1NullifierDev nullifierImpl = new L1NullifierDev({
            _bridgehub: IL1Bridgehub(bridgehub),
            _messageRoot: IMessageRootBase(makeAddr("messageRoot")),
            _eraChainId: eraChainId,
            _eraDiamondProxy: eraDiamondProxy
        });
        l1Nullifier = L1Nullifier(
            payable(
                new TransparentUpgradeableProxy(
                    address(nullifierImpl),
                    proxyAdmin,
                    abi.encodeCall(L1Nullifier.initialize, (owner, 1, 1, 1, 0))
                )
            )
        );

        L1AssetRouter assetRouterImpl = new L1AssetRouter({
            _l1WethToken: weth,
            _bridgehub: bridgehub,
            _l1Nullifier: address(l1Nullifier),
            _eraChainId: eraChainId,
            _eraDiamondProxy: eraDiamondProxy
        });
        assetRouter = L1AssetRouter(
            payable(
                new TransparentUpgradeableProxy(
                    address(assetRouterImpl),
                    proxyAdmin,
                    abi.encodeCall(L1AssetRouter.initialize, (owner))
                )
            )
        );

        L1NativeTokenVaultWithLegacyState ntvImpl = new L1NativeTokenVaultWithLegacyState({
            _wethToken: weth,
            _assetRouter: address(assetRouter),
            _l1Nullifier: l1Nullifier
        });
        ntv = L1NativeTokenVaultWithLegacyState(
            payable(
                new TransparentUpgradeableProxy(
                    address(ntvImpl),
                    proxyAdmin,
                    abi.encodeCall(L1NativeTokenVault.initialize, (owner, tokenBeacon))
                )
            )
        );

        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(chainAssetHandler)
        );
        vm.mockCall(
            chainAssetHandler,
            abi.encodeWithSelector(IChainAssetHandlerBase.migrationNumber.selector),
            abi.encode(0)
        );
        vm.mockCall(bridgehub, abi.encodeWithSelector(IBridgehubBase.assetRouter.selector), abi.encode(assetRouter));
        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = FIRST_CHAIN_ID;
        chainIds[1] = SECOND_CHAIN_ID;
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(chainIds)
        );

        vm.prank(owner);
        assetRouter.setNativeTokenVault(INativeTokenVaultBase(address(ntv)));

        firstToken = new TestnetERC20Token("First", "FST", 18);
        secondToken = new TestnetERC20Token("Second", "SND", 18);
        vm.startPrank(address(ntv));
        ntv.registerToken(address(firstToken));
        ntv.registerToken(address(secondToken));
        vm.stopPrank();
        ntv.registerEthToken();

        firstAssetId = DataEncoding.encodeNTVAssetId(block.chainid, address(firstToken));
        secondAssetId = DataEncoding.encodeNTVAssetId(block.chainid, address(secondToken));

        legacyTracker = new LegacyL1AssetTrackerStub();
        runner = new BridgedOutPopulationRunner();
    }

    function _populate() internal returns (bytes32[] memory assetIds, uint256[] memory populatedPerAsset) {
        return runner.run(bridgehub);
    }

    /// @dev The amount the run folded into `_assetId`'s `bridgedOut`, across all chains.
    function _populatedFor(
        bytes32[] memory _assetIds,
        uint256[] memory _amounts,
        bytes32 _assetId
    ) internal pure returns (uint256) {
        for (uint256 i = 0; i < _assetIds.length; ++i) {
            if (_assetIds[i] == _assetId) {
                return _amounts[i];
            }
        }
        revert("asset not considered by the run");
    }

    function test_populatesEveryAsset() public {
        // L1's bulkhead is the complement of everything ever bridged out of L1.
        legacyTracker.setChainBalance(block.chainid, firstAssetId, MAX_TOKEN_BALANCE - 120);
        legacyTracker.setChainBalance(block.chainid, secondAssetId, MAX_TOKEN_BALANCE - 7);
        ntv.setLegacyAssetTracker(address(legacyTracker));

        (bytes32[] memory assetIds, uint256[] memory populated) = _populate();

        assertEq(_populatedFor(assetIds, populated, firstAssetId), 120, "first asset reported per asset");
        assertEq(_populatedFor(assetIds, populated, secondAssetId), 7, "second asset reported per asset");
        assertEq(ntv.bridgedOut(firstAssetId), 120);
        assertEq(ntv.bridgedOut(secondAssetId), 7);
        assertTrue(ntv.bridgedOutPopulated(firstAssetId));
        assertTrue(ntv.bridgedOutPopulated(secondAssetId));

        // Re-running is a no-op, which is what makes an interrupted stage3 safe to resume.
        (assetIds, populated) = _populate();
        assertEq(_populatedFor(assetIds, populated, firstAssetId), 0, "second run populates nothing");
        assertEq(ntv.bridgedOut(firstAssetId), 120, "no double counting");
    }

    function test_isImmuneToLegacyBalancesMovingBetweenChains() public {
        // The tracker's per-chain entries can still be redistributed by its own migration entry points; the
        // population reads L1's bulkhead, which such moves never touch.
        legacyTracker.setChainBalance(block.chainid, firstAssetId, MAX_TOKEN_BALANCE - 50);
        legacyTracker.setChainBalance(FIRST_CHAIN_ID, firstAssetId, 50);
        ntv.setLegacyAssetTracker(address(legacyTracker));

        legacyTracker.setChainBalance(FIRST_CHAIN_ID, firstAssetId, 0);
        legacyTracker.setChainBalance(SECOND_CHAIN_ID, firstAssetId, 50);

        (bytes32[] memory assetIds, uint256[] memory populated) = _populate();
        assertEq(_populatedFor(assetIds, populated, firstAssetId), 50, "unchanged by the redistribution");
    }

    function test_readsTheVaultsOwnLegacyMappingWithoutATracker() public {
        // Pre-v31 ecosystems never had a tracker; the amounts sit in the vault itself, per chain, and the
        // vault sums them over the chains the bridgehub reports.
        ntv.setDeprecatedChainBalance(FIRST_CHAIN_ID, firstAssetId, 55);
        ntv.setDeprecatedChainBalance(SECOND_CHAIN_ID, firstAssetId, 5);

        (bytes32[] memory assetIds, uint256[] memory populated) = _populate();
        assertEq(_populatedFor(assetIds, populated, firstAssetId), 60);
        assertEq(ntv.bridgedOut(firstAssetId), 60);
    }

    function test_noopWithoutLegacyState() public {
        // Freshly deployed ecosystems have nothing to populate, and no flags are written for them.
        (bytes32[] memory assetIds, uint256[] memory populated) = _populate();
        assertEq(_populatedFor(assetIds, populated, firstAssetId), 0);
        assertFalse(ntv.bridgedOutPopulated(firstAssetId), "no gas spent on empty assets");
    }

    function test_skipsAssetsNotNativeToL1() public {
        // An L2-native asset bridged to L1: `bridgedOut` does not track it, and passing it to the vault
        // would revert, so the driver must filter it out.
        bytes32 remoteAssetId = DataEncoding.encodeNTVAssetId(SECOND_CHAIN_ID, address(0xdead));
        ntv.registerRemoteAsset(remoteAssetId, makeAddr("remoteTokenOnL1"), SECOND_CHAIN_ID);
        assertEq(ntv.originChainId(remoteAssetId), SECOND_CHAIN_ID, "asset registered as L2-native");

        legacyTracker.setChainBalance(block.chainid, remoteAssetId, MAX_TOKEN_BALANCE - 1234);
        ntv.setLegacyAssetTracker(address(legacyTracker));

        (bytes32[] memory assetIds, uint256[] memory populated) = _populate();
        for (uint256 i = 0; i < populated.length; ++i) {
            assertEq(populated[i], 0, "no L1-native amounts to populate");
        }
        for (uint256 i = 0; i < assetIds.length; ++i) {
            assertTrue(assetIds[i] != remoteAssetId, "non-L1-native asset must not be considered");
        }
        assertEq(ntv.bridgedOut(remoteAssetId), 0, "non-L1-native asset untouched");
    }

    function test_batchesAssetsAcrossCalls() public {
        // With a batch size of one, each asset is populated by its own transaction.
        legacyTracker.setChainBalance(block.chainid, firstAssetId, MAX_TOKEN_BALANCE - 3);
        legacyTracker.setChainBalance(block.chainid, secondAssetId, MAX_TOKEN_BALANCE - 4);
        ntv.setLegacyAssetTracker(address(legacyTracker));

        // Three L1-native assets are registered (two tokens + ETH), but only these two have a legacy
        // amount, so a batch size of one has to produce exactly two calls.
        vm.expectCall(address(ntv), abi.encodeWithSelector(IL1NativeTokenVault.populateBridgedOut.selector), 2);
        (bytes32[] memory assetIds, uint256[] memory populated) = runner.runWithBatchSize(bridgehub, 1);

        assertEq(_populatedFor(assetIds, populated, firstAssetId), 3, "per-asset amounts survive batching");
        assertEq(_populatedFor(assetIds, populated, secondAssetId), 4, "per-asset amounts survive batching");
        assertEq(ntv.bridgedOut(firstAssetId), 3);
        assertEq(ntv.bridgedOut(secondAssetId), 4);
    }

    /// @dev ETH is registered in the vault too; keep it out of the way of the token assertions above.
    function test_ethIsPopulatedLikeAnyOtherL1NativeAsset() public {
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        ntv.setDeprecatedChainBalance(FIRST_CHAIN_ID, ethAssetId, 9 ether);

        (bytes32[] memory assetIds, uint256[] memory populated) = _populate();
        assertEq(_populatedFor(assetIds, populated, ethAssetId), 9 ether);
        assertEq(ntv.bridgedOut(ethAssetId), 9 ether);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
