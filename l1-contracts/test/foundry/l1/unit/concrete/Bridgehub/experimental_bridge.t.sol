// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {ChainCreationParams} from "contracts/state-transition/IChainTypeManager.sol";
import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {DummyChainTypeManagerWBH} from "contracts/dev-contracts/test/DummyChainTypeManagerWithBridgeHubAddress.sol";
import {DummyZKChain} from "contracts/dev-contracts/test/DummyZKChain.sol";
import {DummySharedBridge} from "contracts/dev-contracts/test/DummySharedBridge.sol";
import {DummyBridgehubSetter} from "contracts/dev-contracts/test/DummyBridgehubSetter.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1Nullifier} from "contracts/bridge/L1Nullifier.sol";

import {L2Message, L2Log, TxStatus, BridgehubL2TransactionRequest} from "contracts/common/Messaging.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {L2TransactionRequestTwoBridgesInner} from "contracts/bridgehub/IBridgehub.sol";
import {ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA, MAX_NEW_FACTORY_DEPS, TWO_BRIDGES_MAGIC_VALUE} from "contracts/common/Config.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {ZeroChainId, AddressTooLow, ChainIdTooBig, WrongMagicValue, SharedBridgeNotSet, TokenNotRegistered, BridgeHubAlreadyRegistered, MsgValueMismatch, SlotOccupied, CTMAlreadyRegistered, TokenAlreadyRegistered, Unauthorized, NonEmptyMsgValue, CTMNotRegistered, InvalidChainId} from "contracts/common/L1ContractErrors.sol";

contract ExperimentalBridgeTest is Test {
    using stdStorage for StdStorage;

    Bridgehub bridgeHub;
    DummyBridgehubSetter dummyBridgehub;
    address public bridgeOwner;
    address public testTokenAddress;
    DummyChainTypeManagerWBH mockCTM;
    DummyZKChain mockChainContract;
    DummySharedBridge mockSharedBridge;
    DummySharedBridge mockSecondSharedBridge;
    L1AssetRouter sharedBridge;
    address sharedBridgeAddress;
    address secondBridgeAddress;
    address l1NullifierAddress;
    L1AssetRouter secondBridge;
    TestnetERC20Token testToken;
    L1NativeTokenVault ntv;
    L1Nullifier l1Nullifier;

    bytes32 tokenAssetId;

    bytes32 private constant LOCK_FLAG_ADDRESS = 0x8e94fed44239eb2314ab7a406345e6c5a8f0ccedf3b600de3d004e672c33abf4;

    bytes32 ETH_TOKEN_ASSET_ID =
        keccak256(abi.encode(block.chainid, L2_NATIVE_TOKEN_VAULT_ADDR, bytes32(uint256(uint160(ETH_TOKEN_ADDRESS)))));

    TestnetERC20Token testToken6;
    TestnetERC20Token testToken8;
    TestnetERC20Token testToken18;

    address mockL2Contract;

    uint256 eraChainId;

    event NewChain(uint256 indexed chainId, address chainTypeManager, address indexed chainGovernance);

    modifier useRandomToken(uint256 randomValue) {
        _setRandomToken(randomValue);

        _;
    }

    function _setRandomToken(uint256 randomValue) internal {
        uint256 tokenIndex = randomValue % 3;
        TestnetERC20Token token;
        if (tokenIndex == 0) {
            testToken = testToken18;
        } else if (tokenIndex == 1) {
            testToken = testToken6;
        } else {
            testToken = testToken8;
        }
    }

    function setUp() public {
        eraChainId = 9;
        uint256 l1ChainId = 1;
        bridgeOwner = makeAddr("BRIDGE_OWNER");
        dummyBridgehub = new DummyBridgehubSetter(l1ChainId, bridgeOwner, type(uint256).max);
        bridgeHub = Bridgehub(address(dummyBridgehub));
        address weth = makeAddr("WETH");
        mockCTM = new DummyChainTypeManagerWBH(address(bridgeHub));
        mockChainContract = new DummyZKChain(address(bridgeHub), eraChainId, block.chainid);

        mockL2Contract = makeAddr("mockL2Contract");
        // mocks to use in bridges instead of using a dummy one
        address mockL1WethAddress = makeAddr("Weth");
        address eraDiamondProxy = makeAddr("eraDiamondProxy");

        mockSharedBridge = new DummySharedBridge(keccak256("0xabc"));
        mockSecondSharedBridge = new DummySharedBridge(keccak256("0xdef"));
        ntv = new L1NativeTokenVault(weth, address(mockSharedBridge), eraChainId, IL1Nullifier(address(0)));
        mockSharedBridge.setNativeTokenVault(ntv);
        mockSecondSharedBridge.setNativeTokenVault(ntv);
        testToken = new TestnetERC20Token("ZKSTT", "ZkSync Test Token", 18);
        testTokenAddress = address(testToken);
        vm.prank(address(ntv));
        // ntv.registerToken(ETH_TOKEN_ADDRESS);
        ntv.registerToken(address(testToken));
        tokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, address(testToken));

        // sharedBridge = new L1AssetRouter(mockL1WethAddress, bridgeHub, eraChainId, eraDiamondProxy);
        // address defaultOwner = sharedBridge.owner();
        // vm.prank(defaultOwner);
        // sharedBridge.transferOwnership(bridgeOwner);
        // vm.prank(bridgeOwner);
        // sharedBridge.acceptOwnership();

        // secondBridge = new L1AssetRouter(mockL1WethAddress, bridgeHub, eraChainId, eraDiamondProxy);
        // defaultOwner = secondBridge.owner();
        // vm.prank(defaultOwner);
        // secondBridge.transferOwnership(bridgeOwner);
        // vm.prank(bridgeOwner);
        // secondBridge.acceptOwnership();

        // sharedBridgeAddress = address(sharedBridge);
        // secondBridgeAddress = address(secondBridge);
        testToken18 = new TestnetERC20Token("ZKSTT", "ZkSync Test Token", 18);
        testToken6 = new TestnetERC20Token("USDC", "USD Coin", 6);
        testToken8 = new TestnetERC20Token("WBTC", "Wrapped Bitcoin", 8);

        // test if the ownership of the bridgeHub is set correctly or not
        address defaultOwner = bridgeHub.owner();

        // Now, the `reentrancyGuardInitializer` should prevent anyone from calling `initialize` since we have called the constructor of the contract
        vm.expectRevert(SlotOccupied.selector);
        bridgeHub.initialize(bridgeOwner);

        vm.store(address(mockChainContract), LOCK_FLAG_ADDRESS, bytes32(uint256(1)));
        bytes32 bridgehubLocation = bytes32(uint256(36));
        vm.store(address(mockChainContract), bridgehubLocation, bytes32(uint256(uint160(address(bridgeHub)))));
        bytes32 baseTokenGasPriceNominatorLocation = bytes32(uint256(40));
        vm.store(address(mockChainContract), baseTokenGasPriceNominatorLocation, bytes32(uint256(1)));
        bytes32 baseTokenGasPriceDenominatorLocation = bytes32(uint256(41));
        vm.store(address(mockChainContract), baseTokenGasPriceDenominatorLocation, bytes32(uint256(1)));
        // The ownership can only be transferred by the current owner to a new owner via the two-step approach

        // Default owner calls transferOwnership
        vm.prank(defaultOwner);
        bridgeHub.transferOwnership(bridgeOwner);

        // bridgeOwner calls acceptOwnership
        vm.prank(bridgeOwner);
        bridgeHub.acceptOwnership();

        // Ownership should have changed
        assertEq(bridgeHub.owner(), bridgeOwner);
    }

    function test_newPendingAdminReplacesPrevious(address randomDeployer, address otherRandomDeployer) public {
        vm.assume(randomDeployer != address(0));
        vm.assume(otherRandomDeployer != address(0));
        assertEq(address(0), bridgeHub.admin());
        vm.assume(randomDeployer != otherRandomDeployer);

        vm.prank(bridgeHub.owner());
        bridgeHub.setPendingAdmin(randomDeployer);

        vm.prank(bridgeHub.owner());
        bridgeHub.setPendingAdmin(otherRandomDeployer);

        vm.prank(otherRandomDeployer);
        bridgeHub.acceptAdmin();

        assertEq(otherRandomDeployer, bridgeHub.admin());
    }

    function test_onlyPendingAdminCanAccept(address randomDeployer, address otherRandomDeployer) public {
        vm.assume(randomDeployer != address(0));
        vm.assume(otherRandomDeployer != address(0));
        assertEq(address(0), bridgeHub.admin());
        vm.assume(randomDeployer != otherRandomDeployer);

        vm.prank(bridgeHub.owner());
        bridgeHub.setPendingAdmin(randomDeployer);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, otherRandomDeployer));
        vm.prank(otherRandomDeployer);
        bridgeHub.acceptAdmin();

        assertEq(address(0), bridgeHub.admin());
    }

    function test_onlyOwnerCanSetDeployer(address randomDeployer) public {
        vm.assume(randomDeployer != address(0));
        assertEq(address(0), bridgeHub.admin());

        vm.prank(bridgeHub.owner());
        bridgeHub.setPendingAdmin(randomDeployer);
        vm.prank(randomDeployer);
        bridgeHub.acceptAdmin();

        assertEq(randomDeployer, bridgeHub.admin());
    }

    function test_randomCallerCannotSetDeployer(address randomCaller, address randomDeployer) public {
        if (randomCaller != bridgeHub.owner() && randomCaller != bridgeHub.admin()) {
            vm.prank(randomCaller);
            vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomCaller));
            bridgeHub.setPendingAdmin(randomDeployer);

            // The deployer shouldn't have changed.
            assertEq(address(0), bridgeHub.admin());
        }
    }

    function test_addChainTypeManager(address randomAddressWithoutTheCorrectInterface) public {
        vm.assume(randomAddressWithoutTheCorrectInterface != address(0));
        bool isCTMRegistered = bridgeHub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isCTMRegistered);

        vm.prank(bridgeOwner);
        bridgeHub.addChainTypeManager(randomAddressWithoutTheCorrectInterface);

        isCTMRegistered = bridgeHub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isCTMRegistered);

        // An address that has already been registered, cannot be registered again (at least not before calling `removeChainTypeManager`).
        vm.prank(bridgeOwner);
        vm.expectRevert(CTMAlreadyRegistered.selector);
        bridgeHub.addChainTypeManager(randomAddressWithoutTheCorrectInterface);

        isCTMRegistered = bridgeHub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isCTMRegistered);
    }

    function test_addChainTypeManager_cannotBeCalledByRandomAddress(
        address randomCaller,
        address randomAddressWithoutTheCorrectInterface
    ) public {
        vm.assume(randomAddressWithoutTheCorrectInterface != address(0));
        bool isCTMRegistered = bridgeHub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isCTMRegistered);

        if (randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));

            bridgeHub.addChainTypeManager(randomAddressWithoutTheCorrectInterface);
        }

        vm.prank(bridgeOwner);
        bridgeHub.addChainTypeManager(randomAddressWithoutTheCorrectInterface);

        isCTMRegistered = bridgeHub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isCTMRegistered);

        // An address that has already been registered, cannot be registered again (at least not before calling `removeChainTypeManager`).
        vm.prank(bridgeOwner);
        vm.expectRevert(CTMAlreadyRegistered.selector);
        bridgeHub.addChainTypeManager(randomAddressWithoutTheCorrectInterface);

        // Definitely not by a random caller
        if (randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert("Ownable: caller is not the owner");
            bridgeHub.addChainTypeManager(randomAddressWithoutTheCorrectInterface);
        }

        isCTMRegistered = bridgeHub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isCTMRegistered);
    }

    function test_removeChainTypeManager(address randomAddressWithoutTheCorrectInterface) public {
        vm.assume(randomAddressWithoutTheCorrectInterface != address(0));
        bool isCTMRegistered = bridgeHub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isCTMRegistered);

        // A non-existent CTM cannot be removed
        vm.prank(bridgeOwner);
        vm.expectRevert(CTMNotRegistered.selector);
        bridgeHub.removeChainTypeManager(randomAddressWithoutTheCorrectInterface);

        // Let's first register our particular chainTypeManager
        vm.prank(bridgeOwner);
        bridgeHub.addChainTypeManager(randomAddressWithoutTheCorrectInterface);

        isCTMRegistered = bridgeHub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isCTMRegistered);

        // Only an address that has already been registered, can be removed.
        vm.prank(bridgeOwner);
        bridgeHub.removeChainTypeManager(randomAddressWithoutTheCorrectInterface);

        isCTMRegistered = bridgeHub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isCTMRegistered);

        // An already removed CTM cannot be removed again
        vm.prank(bridgeOwner);
        vm.expectRevert(CTMNotRegistered.selector);
        bridgeHub.removeChainTypeManager(randomAddressWithoutTheCorrectInterface);
    }

    function test_removeChainTypeManager_cannotBeCalledByRandomAddress(
        address randomAddressWithoutTheCorrectInterface,
        address randomCaller
    ) public {
        vm.assume(randomAddressWithoutTheCorrectInterface != address(0));
        bool isCTMRegistered = bridgeHub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isCTMRegistered);

        if (randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));

            bridgeHub.removeChainTypeManager(randomAddressWithoutTheCorrectInterface);
        }

        // A non-existent CTM cannot be removed
        vm.prank(bridgeOwner);
        vm.expectRevert(CTMNotRegistered.selector);
        bridgeHub.removeChainTypeManager(randomAddressWithoutTheCorrectInterface);

        // Let's first register our particular chainTypeManager
        vm.prank(bridgeOwner);
        bridgeHub.addChainTypeManager(randomAddressWithoutTheCorrectInterface);

        isCTMRegistered = bridgeHub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isCTMRegistered);

        // Only an address that has already been registered, can be removed.
        vm.prank(bridgeOwner);
        bridgeHub.removeChainTypeManager(randomAddressWithoutTheCorrectInterface);

        isCTMRegistered = bridgeHub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isCTMRegistered);

        // An already removed CTM cannot be removed again
        vm.prank(bridgeOwner);
        vm.expectRevert(CTMNotRegistered.selector);
        bridgeHub.removeChainTypeManager(randomAddressWithoutTheCorrectInterface);

        // Not possible by a randomcaller as well
        if (randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            bridgeHub.removeChainTypeManager(randomAddressWithoutTheCorrectInterface);
        }
    }

    function test_addAssetId(address randomAddress) public {
        vm.startPrank(bridgeOwner);
        bridgeHub.setAddresses(address(mockSharedBridge), ICTMDeploymentTracker(address(0)), IMessageRoot(address(0)));
        vm.stopPrank();

        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, testTokenAddress);
        assertTrue(!bridgeHub.assetIdIsRegistered(assetId), "This random address is not registered as a token");

        vm.prank(bridgeOwner);
        bridgeHub.addTokenAssetId(assetId);

        assertTrue(
            bridgeHub.assetIdIsRegistered(assetId),
            "after call from the bridgeowner, this randomAddress should be a registered token"
        );

        if (randomAddress != address(testTokenAddress)) {
            // Testing to see if a random address can also be added or not
            vm.prank(bridgeOwner);
            assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(randomAddress));
            bridgeHub.addTokenAssetId(assetId);
            assertTrue(bridgeHub.assetIdIsRegistered(assetId));
        }

        // An already registered token cannot be registered again
        vm.prank(bridgeOwner);
        vm.expectRevert("BH: asset id already registered");
        bridgeHub.addTokenAssetId(assetId);
    }

    function test_addAssetId_cannotBeCalledByRandomAddress(
        address randomCaller,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        vm.startPrank(bridgeOwner);
        bridgeHub.setAddresses(address(mockSharedBridge), ICTMDeploymentTracker(address(0)), IMessageRoot(address(0)));
        vm.stopPrank();

        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, testTokenAddress);

        if (randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            bridgeHub.addTokenAssetId(assetId);
        }

        assertTrue(!bridgeHub.assetIdIsRegistered(assetId), "This random address is not registered as a token");

        vm.prank(bridgeOwner);
        bridgeHub.addTokenAssetId(assetId);

        assertTrue(
            bridgeHub.assetIdIsRegistered(assetId),
            "after call from the bridgeowner, this testTokenAddress should be a registered token"
        );

        // An already registered token cannot be registered again by randomCaller
        if (randomCaller != bridgeOwner) {
            vm.prank(bridgeOwner);
            vm.expectRevert("BH: asset id already registered");
            bridgeHub.addTokenAssetId(assetId);
        }
    }

    // function test_setSharedBridge(address randomAddress) public {
    //     assertTrue(
    //         bridgeHub.sharedBridge() == IL1AssetRouter(address(0)),
    //         "This random address is not registered as sharedBridge"
    //     );

    //     vm.prank(bridgeOwner);
    //     bridgeHub.setSharedBridge(randomAddress);

    //     assertTrue(
    //         bridgeHub.sharedBridge() == IL1AssetRouter(randomAddress),
    //         "after call from the bridgeowner, this randomAddress should be the registered sharedBridge"
    //     );
    // }

    // function test_setSharedBridge_cannotBeCalledByRandomAddress(address randomCaller, address randomAddress) public {
    //     if (randomCaller != bridgeOwner) {
    //         vm.prank(randomCaller);
    //         vm.expectRevert(bytes("Ownable: caller is not the owner"));
    //         bridgeHub.setSharedBridge(randomAddress);
    //     }

    // assertTrue(
    //     bridgeHub.sharedBridge() == IL1AssetRouter(address(0)),
    //     "This random address is not registered as sharedBridge"
    // );

    //     vm.prank(bridgeOwner);
    //     bridgeHub.setSharedBridge(randomAddress);

    //     assertTrue(
    //         bridgeHub.sharedBridge() == IL1AssetRouter(randomAddress),
    //         "after call from the bridgeowner, this randomAddress should be the registered sharedBridge"
    //     );
    // }

    // uint256 newChainId;
    // address admin;

    // function test_pause_createNewChain(
    //     uint256 chainId,
    //     uint256 salt,
    //     uint256 randomValue
    // ) public useRandomToken(randomValue) {
    //     chainId = bound(chainId, 1, type(uint48).max);
    //     address deployerAddress = makeAddr("DEPLOYER_ADDRESS");
    //     admin = makeAddr("NEW_CHAIN_ADMIN");

    //     vm.prank(bridgeOwner);
    //     bridgeHub.pause();
    //     vm.prank(bridgeOwner);
    //     bridgeHub.setPendingAdmin(deployerAddress);
    //     vm.prank(deployerAddress);
    //     bridgeHub.acceptAdmin();

    //     vm.expectRevert("Pausable: paused");
    //     vm.prank(deployerAddress);
    //     bridgeHub.createNewChain({
    //         _chainId: chainId,
    //         _chainTypeManager: address(mockCTM),
    //         _baseToken: address(testToken),
    //         _salt: salt,
    //         _admin: admin,
    //         _initData: bytes("")
    //     });

    //     vm.prank(bridgeOwner);
    //     bridgeHub.unpause();

    //     vm.expectRevert(CTMNotRegistered.selector);
    //     vm.prank(deployerAddress);
    //     bridgeHub.createNewChain({
    //         _chainId: 1,
    //         _chainTypeManager: address(mockCTM),
    //         _baseToken: address(testToken),
    //         _salt: uint256(123),
    //         _admin: admin,
    //         _initData: bytes("")
    //     });
    // }

    // function test_RevertWhen_CTMNotRegisteredOnCreate(
    //     uint256 chainId,
    //     uint256 salt,
    //     uint256 randomValue
    // ) public useRandomToken(randomValue) {
    //     chainId = bound(chainId, 1, type(uint48).max);
    //     address deployerAddress = makeAddr("DEPLOYER_ADDRESS");
    //     admin = makeAddr("NEW_CHAIN_ADMIN");

    //     vm.prank(bridgeOwner);
    //     bridgeHub.setPendingAdmin(deployerAddress);
    //     vm.prank(deployerAddress);
    //     bridgeHub.acceptAdmin();

    //     chainId = bound(chainId, 1, type(uint48).max);
    //     vm.expectRevert(CTMNotRegistered.selector);
    //     vm.prank(deployerAddress);
    //     bridgeHub.createNewChain({
    //         _chainId: chainId,
    //         _chainTypeManager: address(mockCTM),
    //         _baseToken: address(testToken),
    //         _salt: salt,
    //         _admin: admin,
    //         _initData: bytes("")
    //     });
    // }

    // function test_RevertWhen_wrongChainIdOnCreate(
    //     uint256 chainId,
    //     uint256 salt,
    //     uint256 randomValue
    // ) public useRandomToken(randomValue) {
    //     chainId = bound(chainId, 1, type(uint48).max);
    //     address deployerAddress = makeAddr("DEPLOYER_ADDRESS");
    //     admin = makeAddr("NEW_CHAIN_ADMIN");

    //     vm.prank(bridgeOwner);
    //     bridgeHub.setPendingAdmin(deployerAddress);
    //     vm.prank(deployerAddress);
    //     bridgeHub.acceptAdmin();

    //     chainId = bound(chainId, type(uint48).max + uint256(1), type(uint256).max);
    //     vm.expectRevert(ChainIdTooBig.selector);
    //     vm.prank(deployerAddress);
    //     bridgeHub.createNewChain({
    //         _chainId: chainId,
    //         _chainTypeManager: address(mockCTM),
    //         _baseToken: address(testToken),
    //         _salt: salt,
    //         _admin: admin,
    //         _initData: bytes("")
    //     });

    //     chainId = 0;
    //     vm.expectRevert(ZeroChainId.selector);
    //     vm.prank(deployerAddress);
    //     bridgeHub.createNewChain({
    //         _chainId: chainId,
    //         _chainTypeManager: address(mockCTM),
    //         _baseToken: address(testToken),
    //         _salt: salt,
    //         _admin: admin,
    //         _initData: bytes("")
    //     });
    // }

    // function test_RevertWhen_tokenNotRegistered(
    //     uint256 chainId,
    //     uint256 salt,
    //     uint256 randomValue
    // ) public useRandomToken(randomValue) {
    //     chainId = bound(chainId, 1, type(uint48).max);
    //     address deployerAddress = makeAddr("DEPLOYER_ADDRESS");
    //     admin = makeAddr("NEW_CHAIN_ADMIN");

    //     vm.prank(bridgeOwner);
    //     bridgeHub.setPendingAdmin(deployerAddress);
    //     vm.prank(deployerAddress);
    //     bridgeHub.acceptAdmin();

    //     vm.startPrank(bridgeOwner);
    //     bridgeHub.addChainTypeManager(address(mockCTM));
    //     vm.stopPrank();

    //     vm.expectRevert(abi.encodeWithSelector(TokenNotRegistered.selector, address(testToken)));
    //     vm.prank(deployerAddress);
    //     bridgeHub.createNewChain({
    //         _chainId: chainId,
    //         _chainTypeManager: address(mockCTM),
    //         _baseToken: address(testToken),
    //         _salt: salt,
    //         _admin: admin,
    //         _initData: bytes("")
    //     });
    // }

    // function test_RevertWhen_wethBridgeNotSet(
    //     uint256 chainId,
    //     uint256 salt,
    //     uint256 randomValue
    // ) public useRandomToken(randomValue) {
    //     chainId = bound(chainId, 1, type(uint48).max);
    //     address deployerAddress = makeAddr("DEPLOYER_ADDRESS");
    //     admin = makeAddr("NEW_CHAIN_ADMIN");

    //     vm.prank(bridgeOwner);
    //     bridgeHub.setPendingAdmin(deployerAddress);
    //     vm.prank(deployerAddress);
    //     bridgeHub.acceptAdmin();

    //     vm.startPrank(bridgeOwner);
    //     bridgeHub.addChainTypeManager(address(mockCTM));
    //     bridgeHub.addToken(address(testToken));
    //     vm.stopPrank();

    //     vm.expectRevert(SharedBridgeNotSet.selector);
    //     vm.prank(deployerAddress);
    //     bridgeHub.createNewChain({
    //         _chainId: chainId,
    //         _chainTypeManager: address(mockCTM),
    //         _baseToken: address(testToken),
    //         _salt: salt,
    //         _admin: admin,
    //         _initData: bytes("")
    //     });
    // }

    // function test_RevertWhen_chainIdAlreadyRegistered(
    //     uint256 chainId,
    //     uint256 salt,
    //     uint256 randomValue
    // ) public useRandomToken(randomValue) {
    //     address deployerAddress = makeAddr("DEPLOYER_ADDRESS");
    //     admin = makeAddr("NEW_CHAIN_ADMIN");
    //     vm.prank(bridgeOwner);
    //     bridgeHub.setPendingAdmin(deployerAddress);
    //     vm.prank(deployerAddress);
    //     bridgeHub.acceptAdmin();

    //     vm.startPrank(bridgeOwner);
    //     bridgeHub.addChainTypeManager(address(mockCTM));
    //     bridgeHub.addToken(address(testToken));
    //     bridgeHub.setSharedBridge(sharedBridgeAddress);
    //     vm.stopPrank();

    //     chainId = bound(chainId, 1, type(uint48).max);
    //     stdstore.target(address(bridgeHub)).sig("chainTypeManager(uint256)").with_key(chainId).checked_write(
    //         address(mockCTM)
    //     );

    //     vm.expectRevert(BridgeHubAlreadyRegistered.selector);
    //     vm.prank(deployerAddress);
    //     bridgeHub.createNewChain({
    //         _chainId: chainId,
    //         _chainTypeManager: address(mockCTM),
    //         _baseToken: address(testToken),
    //         _salt: salt,
    //         _admin: admin,
    //         _initData: bytes("")
    //     });
    // }

    // function test_createNewChain(
    //     address randomCaller,
    //     uint256 chainId,
    //     bool isFreezable,
    //     bytes4[] memory mockSelectors,
    //     address mockInitAddress,
    //     bytes memory mockInitCalldata,
    //     uint256 salt,
    //     uint256 randomValue
    // ) public useRandomToken(randomValue) {
    //     address deployerAddress = makeAddr("DEPLOYER_ADDRESS");
    //     admin = makeAddr("NEW_CHAIN_ADMIN");
    //     chainId = bound(chainId, 1, type(uint48).max);

    //     vm.prank(bridgeOwner);
    //     bridgeHub.setPendingAdmin(deployerAddress);
    //     vm.prank(deployerAddress);
    //     bridgeHub.acceptAdmin();

    //     vm.startPrank(bridgeOwner);
    //     bridgeHub.addChainTypeManager(address(mockCTM));
    //     bridgeHub.addToken(address(testToken));
    //     bridgeHub.setSharedBridge(sharedBridgeAddress);
    //     vm.stopPrank();

    //     if (randomCaller != deployerAddress && randomCaller != bridgeOwner) {
    //         vm.prank(randomCaller);
    //         vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomCaller));
    //         bridgeHub.createNewChain({
    //             _chainId: chainId,
    //             _chainTypeManager: address(mockCTM),
    //             _baseToken: address(testToken),
    //             _salt: salt,
    //             _admin: admin,
    //             _initData: bytes("")
    //         });
    //     }

    //     vm.prank(mockCTM.owner());
    //     bytes memory _newChainInitData = _createNewChainInitData(
    //         isFreezable,
    //         mockSelectors,
    //         mockInitAddress,
    //         mockInitCalldata
    //     );

    //     // bridgeHub.createNewChain => chainTypeManager.createNewChain => this function sets the stateTransition mapping
    //     // of `chainId`, let's emulate that using foundry cheatcodes or let's just use the extra function we introduced in our mockCTM
    //     mockCTM.setZKChain(chainId, address(mockChainContract));
    //     assertTrue(mockCTM.getZKChain(chainId) == address(mockChainContract));

    // vm.startPrank(deployerAddress);
    // vm.mockCall(
    //     address(mockCTM),
    //     // solhint-disable-next-line func-named-parameters
    //     abi.encodeWithSelector(
    //         mockCTM.createNewChain.selector,
    //         chainId,
    //         address(testToken),
    //         sharedBridgeAddress,
    //         admin,
    //         _newChainInitData
    //     ),
    //     bytes("")
    // );

    // vm.expectEmit(true, true, true, true, address(bridgeHub));
    // emit NewChain(chainId, address(mockCTM), admin);

    // newChainId = bridgeHub.createNewChain({
    //     _chainId: chainId,
    //     _chainTypeManager: address(mockCTM),
    //     _baseToken: address(testToken),
    //     _salt: uint256(chainId * 2),
    //     _admin: admin,
    //     _initData: _newChainInitData
    // });

    //     vm.stopPrank();
    //     vm.clearMockedCalls();

    //     assertTrue(bridgeHub.chainTypeManager(newChainId) == address(mockCTM));
    //     assertTrue(bridgeHub.baseToken(newChainId) == testTokenAddress);
    // }

    // function test_getZKChain(uint256 mockChainId) public {
    //     mockChainId = _setUpZKChainForChainId(mockChainId);

    //     // Now the following statements should be true as well:
    //     assertTrue(bridgeHub.chainTypeManager(mockChainId) == address(mockCTM));
    //     address returnedZKChain = bridgeHub.getZKChain(mockChainId);

    //     assertEq(returnedZKChain, address(mockChainContract));
    // }

    // function test_proveL2MessageInclusion(
    //     uint256 mockChainId,
    //     uint256 mockBatchNumber,
    //     uint256 mockIndex,
    //     bytes32[] memory mockProof,
    //     uint16 randomTxNumInBatch,
    //     address randomSender,
    //     bytes memory randomData
    // ) public {
    //     mockChainId = _setUpZKChainForChainId(mockChainId);

    //     // Now the following statements should be true as well:
    //     assertTrue(bridgeHub.chainTypeManager(mockChainId) == address(mockCTM));
    //     assertTrue(bridgeHub.getZKChain(mockChainId) == address(mockChainContract));

    //     // Creating a random L2Message::l2Message so that we pass the correct parameters to `proveL2MessageInclusion`
    //     L2Message memory l2Message = _createMockL2Message(randomTxNumInBatch, randomSender, randomData);

    //     // Since we have used random data for the `bridgeHub.proveL2MessageInclusion` function which basically forwards the call
    //     // to the same function in the mailbox, we will mock the call to the mailbox to return true and see if it works.
    //     vm.mockCall(
    //         address(mockChainContract),
    //         // solhint-disable-next-line func-named-parameters
    //         abi.encodeWithSelector(
    //             mockChainContract.proveL2MessageInclusion.selector,
    //             mockBatchNumber,
    //             mockIndex,
    //             l2Message,
    //             mockProof
    //         ),
    //         abi.encode(true)
    //     );

    //     assertTrue(
    //         bridgeHub.proveL2MessageInclusion({
    //             _chainId: mockChainId,
    //             _batchNumber: mockBatchNumber,
    //             _index: mockIndex,
    //             _message: l2Message,
    //             _proof: mockProof
    //         })
    //     );
    //     vm.clearMockedCalls();
    // }

    function test_proveL2LogInclusion(
        uint256 mockChainId,
        uint256 mockBatchNumber,
        uint256 mockIndex,
        bytes32[] memory mockProof,
        uint8 randomL2ShardId,
        bool randomIsService,
        uint16 randomTxNumInBatch,
        address randomSender,
        bytes32 randomKey,
        bytes32 randomValue
    ) public {
        mockChainId = _setUpZKChainForChainId(mockChainId);

        // Now the following statements should be true as well:
        assertTrue(bridgeHub.chainTypeManager(mockChainId) == address(mockCTM));
        assertTrue(bridgeHub.getZKChain(mockChainId) == address(mockChainContract));

        // Creating a random L2Log::l2Log so that we pass the correct parameters to `proveL2LogInclusion`
        L2Log memory l2Log = _createMockL2Log({
            randomL2ShardId: randomL2ShardId,
            randomIsService: randomIsService,
            randomTxNumInBatch: randomTxNumInBatch,
            randomSender: randomSender,
            randomKey: randomKey,
            randomValue: randomValue
        });

        // Since we have used random data for the `bridgeHub.proveL2LogInclusion` function which basically forwards the call
        // to the same function in the mailbox, we will mock the call to the mailbox to return true and see if it works.
        vm.mockCall(
            address(mockChainContract),
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                mockChainContract.proveL2LogInclusion.selector,
                mockBatchNumber,
                mockIndex,
                l2Log,
                mockProof
            ),
            abi.encode(true)
        );

        assertTrue(
            bridgeHub.proveL2LogInclusion({
                _chainId: mockChainId,
                _batchNumber: mockBatchNumber,
                _index: mockIndex,
                _log: l2Log,
                _proof: mockProof
            })
        );
        vm.clearMockedCalls();
    }

    function test_proveL1ToL2TransactionStatus(
        uint256 randomChainId,
        bytes32 randomL2TxHash,
        uint256 randomL2BatchNumber,
        uint256 randomL2MessageIndex,
        uint16 randomL2TxNumberInBatch,
        bytes32[] memory randomMerkleProof,
        bool randomResultantBool,
        bool txStatusBool
    ) public {
        randomChainId = _setUpZKChainForChainId(randomChainId);

        TxStatus txStatus;

        if (txStatusBool) {
            txStatus = TxStatus.Failure;
        } else {
            txStatus = TxStatus.Success;
        }

        vm.mockCall(
            address(mockChainContract),
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                mockChainContract.proveL1ToL2TransactionStatus.selector,
                randomL2TxHash,
                randomL2BatchNumber,
                randomL2MessageIndex,
                randomL2TxNumberInBatch,
                randomMerkleProof,
                txStatus
            ),
            abi.encode(randomResultantBool)
        );

        assertTrue(
            bridgeHub.proveL1ToL2TransactionStatus({
                _chainId: randomChainId,
                _l2TxHash: randomL2TxHash,
                _l2BatchNumber: randomL2BatchNumber,
                _l2MessageIndex: randomL2MessageIndex,
                _l2TxNumberInBatch: randomL2TxNumberInBatch,
                _merkleProof: randomMerkleProof,
                _status: txStatus
            }) == randomResultantBool
        );
    }

    function test_l2TransactionBaseCost(
        uint256 mockChainId,
        uint256 mockGasPrice,
        uint256 mockL2GasLimit,
        uint256 mockL2GasPerPubdataByteLimit,
        uint256 mockL2TxnCost
    ) public {
        mockChainId = _setUpZKChainForChainId(mockChainId);

        vm.mockCall(
            address(mockChainContract),
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                mockChainContract.l2TransactionBaseCost.selector,
                mockGasPrice,
                mockL2GasLimit,
                mockL2GasPerPubdataByteLimit
            ),
            abi.encode(mockL2TxnCost)
        );

        assertTrue(
            bridgeHub.l2TransactionBaseCost(mockChainId, mockGasPrice, mockL2GasLimit, mockL2GasPerPubdataByteLimit) ==
                mockL2TxnCost
        );
        vm.clearMockedCalls();
    }

    // function _prepareETHL2TransactionDirectRequest(
    //     uint256 mockChainId,
    //     uint256 mockMintValue,
    //     address mockL2Contract,
    //     uint256 mockL2Value,
    //     bytes memory mockL2Calldata,
    //     uint256 mockL2GasLimit,
    //     uint256 mockL2GasPerPubdataByteLimit,
    //     bytes[] memory mockFactoryDeps,
    //     address randomCaller
    // ) internal returns (L2TransactionRequestDirect memory l2TxnReqDirect) {
    //     if (mockFactoryDeps.length > MAX_NEW_FACTORY_DEPS) {
    //         mockFactoryDeps = _restrictArraySize(mockFactoryDeps, MAX_NEW_FACTORY_DEPS);
    //     }

    //     l2TxnReqDirect = _createMockL2TransactionRequestDirect({
    //         mockChainId: mockChainId,
    //         mockMintValue: mockMintValue,
    //         mockL2Contract: mockL2Contract,
    //         mockL2Value: mockL2Value,
    //         mockL2Calldata: mockL2Calldata,
    //         mockL2GasLimit: mockL2GasLimit,
    //         mockL2GasPerPubdataByteLimit: mockL2GasPerPubdataByteLimit,
    //         mockFactoryDeps: mockFactoryDeps,
    //         mockRefundRecipient: address(0)
    //     });

    //     l2TxnReqDirect.chainId = _setUpZKChainForChainId(l2TxnReqDirect.chainId);

    //     assertTrue(!(bridgeHub.baseToken(l2TxnReqDirect.chainId) == ETH_TOKEN_ADDRESS));
    //     _setUpBaseTokenForChainId(l2TxnReqDirect.chainId, true, address(0));
    //     assertTrue(bridgeHub.baseToken(l2TxnReqDirect.chainId) == ETH_TOKEN_ADDRESS);

    //     _setUpSharedBridge();
    //     _setUpSharedBridgeL2(mockChainId);

    //     assertTrue(bridgeHub.getZKChain(l2TxnReqDirect.chainId) == address(mockChainContract));
    //     bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));

    //     vm.mockCall(
    //         address(mockChainContract),
    //         abi.encodeWithSelector(mockChainContract.bridgehubRequestL2Transaction.selector),
    //         abi.encode(canonicalHash)
    //     );

    //     mockChainContract.setFeeParams();
    //     mockChainContract.setBaseTokenGasMultiplierPrice(uint128(1), uint128(1));
    //     mockChainContract.setBridgeHubAddress(address(bridgeHub));
    //     assertTrue(mockChainContract.getBridgeHubAddress() == address(bridgeHub));
    // }

    // function test_requestL2TransactionDirect_RevertWhen_incorrectETHParams(
    //     uint256 mockChainId,
    //     uint256 mockMintValue,
    //     address mockL2Contract,
    //     uint256 mockL2Value,
    //     uint256 msgValue,
    //     bytes memory mockL2Calldata,
    //     uint256 mockL2GasLimit,
    //     uint256 mockL2GasPerPubdataByteLimit,
    //     bytes[] memory mockFactoryDeps
    // ) public {
    //     address randomCaller = makeAddr("RANDOM_CALLER");
    //     vm.assume(msgValue != mockMintValue);

    //     L2TransactionRequestDirect memory l2TxnReqDirect = _prepareETHL2TransactionDirectRequest({
    //         mockChainId: mockChainId,
    //         mockMintValue: mockMintValue,
    //         mockL2Contract: mockL2Contract,
    //         mockL2Value: mockL2Value,
    //         mockL2Calldata: mockL2Calldata,
    //         mockL2GasLimit: mockL2GasLimit,
    //         mockL2GasPerPubdataByteLimit: mockL2GasPerPubdataByteLimit,
    //         mockFactoryDeps: mockFactoryDeps,
    //         randomCaller: randomCaller
    //     });

    //     vm.deal(randomCaller, msgValue);
    //     vm.expectRevert(abi.encodeWithSelector(MsgValueMismatch.selector, mockMintValue, msgValue));
    //     vm.prank(randomCaller);
    //     bridgeHub.requestL2TransactionDirect{value: msgValue}(l2TxnReqDirect);
    // }

    // function test_requestL2TransactionDirect_ETHCase(
    //     uint256 mockChainId,
    //     uint256 mockMintValue,
    //     address mockL2Contract,
    //     uint256 mockL2Value,
    //     bytes memory mockL2Calldata,
    //     uint256 mockL2GasLimit,
    //     uint256 mockL2GasPerPubdataByteLimit,
    //     bytes[] memory mockFactoryDeps,
    //     uint256 gasPrice
    // ) public {
    //     address randomCaller = makeAddr("RANDOM_CALLER");
    //     mockChainId = bound(mockChainId, 1, type(uint48).max);

    //     L2TransactionRequestDirect memory l2TxnReqDirect = _prepareETHL2TransactionDirectRequest({
    //         mockChainId: mockChainId,
    //         mockMintValue: mockMintValue,
    //         mockL2Contract: mockL2Contract,
    //         mockL2Value: mockL2Value,
    //         mockL2Calldata: mockL2Calldata,
    //         mockL2GasLimit: mockL2GasLimit,
    //         mockL2GasPerPubdataByteLimit: mockL2GasPerPubdataByteLimit,
    //         mockFactoryDeps: mockFactoryDeps,
    //         randomCaller: randomCaller
    //     });

    //     vm.deal(randomCaller, l2TxnReqDirect.mintValue);
    //     gasPrice = bound(gasPrice, 1_000, 50_000_000);
    //     vm.txGasPrice(gasPrice * 1 gwei);
    //     vm.prank(randomCaller);
    //     bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));
    //     bytes32 resultantHash = bridgeHub.requestL2TransactionDirect{value: randomCaller.balance}(l2TxnReqDirect);

    //     assertTrue(resultantHash == canonicalHash);
    // }

    // function test_requestL2TransactionDirect_NonETHCase(
    //     uint256 mockChainId,
    //     uint256 mockMintValue,
    //     address mockL2Contract,
    //     uint256 mockL2Value,
    //     bytes memory mockL2Calldata,
    //     uint256 mockL2GasLimit,
    //     uint256 mockL2GasPerPubdataByteLimit,
    //     bytes[] memory mockFactoryDeps,
    //     uint256 gasPrice,
    //     uint256 randomValue
    // ) public useRandomToken(randomValue) {
    //     address randomCaller = makeAddr("RANDOM_CALLER");
    //     mockChainId = bound(mockChainId, 1, type(uint48).max);

    //     if (mockFactoryDeps.length > MAX_NEW_FACTORY_DEPS) {
    //         mockFactoryDeps = _restrictArraySize(mockFactoryDeps, MAX_NEW_FACTORY_DEPS);
    //     }

    //     L2TransactionRequestDirect memory l2TxnReqDirect = _createMockL2TransactionRequestDirect({
    //         mockChainId: mockChainId,
    //         mockMintValue: mockMintValue,
    //         mockL2Contract: mockL2Contract,
    //         mockL2Value: mockL2Value,
    //         mockL2Calldata: mockL2Calldata,
    //         mockL2GasLimit: mockL2GasLimit,
    //         mockL2GasPerPubdataByteLimit: mockL2GasPerPubdataByteLimit,
    //         mockFactoryDeps: mockFactoryDeps,
    //         mockRefundRecipient: address(0)
    //     });

    //     l2TxnReqDirect.chainId = _setUpZKChainForChainId(l2TxnReqDirect.chainId);

    //     _setUpBaseTokenForChainId(l2TxnReqDirect.chainId, false, address(testToken));
    //     _setUpSharedBridge();
    //     _setUpSharedBridgeL2(mockChainId);

    //     assertTrue(bridgeHub.getZKChain(l2TxnReqDirect.chainId) == address(mockChainContract));
    //     bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));

    //     vm.mockCall(
    //         address(mockChainContract),
    //         abi.encodeWithSelector(mockChainContract.bridgehubRequestL2Transaction.selector),
    //         abi.encode(canonicalHash)
    //     );

    //     mockChainContract.setFeeParams();
    //     mockChainContract.setBaseTokenGasMultiplierPrice(uint128(1), uint128(1));
    //     mockChainContract.setBridgeHubAddress(address(bridgeHub));
    //     assertTrue(mockChainContract.getBridgeHubAddress() == address(bridgeHub));

    //     gasPrice = bound(gasPrice, 1_000, 50_000_000);
    //     vm.txGasPrice(gasPrice * 1 gwei);

    //     vm.deal(randomCaller, 1 ether);
    //     vm.prank(randomCaller);
    //     vm.expectRevert(abi.encodeWithSelector(MsgValueMismatch.selector, 0, randomCaller.balance));
    //     bytes32 resultantHash = bridgeHub.requestL2TransactionDirect{value: randomCaller.balance}(l2TxnReqDirect);

    //     // Now, let's call the same function with zero msg.value
    //     testToken.mint(randomCaller, l2TxnReqDirect.mintValue);
    //     assertEq(testToken.balanceOf(randomCaller), l2TxnReqDirect.mintValue);

    //     vm.prank(randomCaller);
    //     testToken.transfer(address(this), l2TxnReqDirect.mintValue);
    //     assertEq(testToken.balanceOf(address(this)), l2TxnReqDirect.mintValue);
    //     testToken.approve(sharedBridgeAddress, l2TxnReqDirect.mintValue);

    //     resultantHash = bridgeHub.requestL2TransactionDirect(l2TxnReqDirect);

    //     assertEq(canonicalHash, resultantHash);
    // }

    // function test_requestTransactionTwoBridgesChecksMagicValue(
    //     uint256 chainId,
    //     uint256 mintValue,
    //     uint256 l2Value,
    //     uint256 l2GasLimit,
    //     uint256 l2GasPerPubdataByteLimit,
    //     address refundRecipient,
    //     uint256 secondBridgeValue,
    //     bytes memory secondBridgeCalldata,
    //     bytes32 magicValue
    // ) public {
    //     chainId = bound(chainId, 1, type(uint48).max);

    //     L2TransactionRequestTwoBridgesOuter memory l2TxnReq2BridgeOut = _createMockL2TransactionRequestTwoBridgesOuter({
    //         chainId: chainId,
    //         mintValue: mintValue,
    //         l2Value: l2Value,
    //         l2GasLimit: l2GasLimit,
    //         l2GasPerPubdataByteLimit: l2GasPerPubdataByteLimit,
    //         refundRecipient: refundRecipient,
    //         secondBridgeValue: secondBridgeValue,
    //         secondBridgeCalldata: secondBridgeCalldata
    //     });

    //     l2TxnReq2BridgeOut.chainId = _setUpZKChainForChainId(l2TxnReq2BridgeOut.chainId);

    //     _setUpBaseTokenForChainId(l2TxnReq2BridgeOut.chainId, true, address(0));
    //     assertTrue(bridgeHub.baseToken(l2TxnReq2BridgeOut.chainId) == ETH_TOKEN_ADDRESS);

    //     _setUpSharedBridge();
    //     _setUpSharedBridgeL2(chainId);

    //     assertTrue(bridgeHub.getZKChain(l2TxnReq2BridgeOut.chainId) == address(mockChainContract));

    //     uint256 callerMsgValue = l2TxnReq2BridgeOut.mintValue + l2TxnReq2BridgeOut.secondBridgeValue;
    //     address randomCaller = makeAddr("RANDOM_CALLER");
    //     vm.deal(randomCaller, callerMsgValue);

    //     if (magicValue != TWO_BRIDGES_MAGIC_VALUE) {
    //         L2TransactionRequestTwoBridgesInner memory request = L2TransactionRequestTwoBridgesInner({
    //             magicValue: magicValue,
    //             l2Contract: makeAddr("L2_CONTRACT"),
    //             l2Calldata: new bytes(0),
    //             factoryDeps: new bytes[](0),
    //             txDataHash: bytes32(0)
    //         });

    //         vm.mockCall(
    //             secondBridgeAddress,
    //             abi.encodeWithSelector(IL1SharedBridge.bridgehubDeposit.selector),
    //             abi.encode(request)
    //         );

    //         vm.expectRevert(abi.encodeWithSelector(WrongMagicValue.selector, TWO_BRIDGES_MAGIC_VALUE, magicValue));
    //         vm.prank(randomCaller);
    //         bridgeHub.requestL2TransactionTwoBridges{value: randomCaller.balance}(l2TxnReq2BridgeOut);
    //     }
    // }

    // function test_requestL2TransactionTwoBridgesWrongBridgeAddress(
    //     uint256 chainId,
    //     uint256 mintValue,
    //     uint256 msgValue,
    //     uint256 l2Value,
    //     uint256 l2GasLimit,
    //     uint256 l2GasPerPubdataByteLimit,
    //     address refundRecipient,
    //     uint256 secondBridgeValue,
    //     uint160 secondBridgeAddressValue,
    //     bytes memory secondBridgeCalldata
    // ) public {
    //     chainId = bound(chainId, 1, type(uint48).max);

    //     L2TransactionRequestTwoBridgesOuter memory l2TxnReq2BridgeOut = _createMockL2TransactionRequestTwoBridgesOuter({
    //         chainId: chainId,
    //         mintValue: mintValue,
    //         l2Value: l2Value,
    //         l2GasLimit: l2GasLimit,
    //         l2GasPerPubdataByteLimit: l2GasPerPubdataByteLimit,
    //         refundRecipient: refundRecipient,
    //         secondBridgeValue: secondBridgeValue,
    //         secondBridgeCalldata: secondBridgeCalldata
    //     });

    //     l2TxnReq2BridgeOut.chainId = _setUpZKChainForChainId(l2TxnReq2BridgeOut.chainId);

    //     _setUpBaseTokenForChainId(l2TxnReq2BridgeOut.chainId, true, address(0));
    //     assertTrue(bridgeHub.baseToken(l2TxnReq2BridgeOut.chainId) == ETH_TOKEN_ADDRESS);

    //     _setUpSharedBridge();
    //     _setUpSharedBridgeL2(chainId);

    //     assertTrue(bridgeHub.getZKChain(l2TxnReq2BridgeOut.chainId) == address(mockChainContract));

    //     uint256 callerMsgValue = l2TxnReq2BridgeOut.mintValue + l2TxnReq2BridgeOut.secondBridgeValue;
    //     address randomCaller = makeAddr("RANDOM_CALLER");
    //     vm.deal(randomCaller, callerMsgValue);

    //     mockChainContract.setBridgeHubAddress(address(bridgeHub));

    //     bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));

    //     vm.mockCall(
    //         address(mockChainContract),
    //         abi.encodeWithSelector(mockChainContract.bridgehubRequestL2Transaction.selector),
    //         abi.encode(canonicalHash)
    //     );

    //     L2TransactionRequestTwoBridgesInner memory outputRequest = L2TransactionRequestTwoBridgesInner({
    //         magicValue: TWO_BRIDGES_MAGIC_VALUE,
    //         l2Contract: address(0),
    //         l2Calldata: abi.encode(""),
    //         factoryDeps: new bytes[](0),
    //         txDataHash: bytes32("")
    //     });
    //     secondBridgeAddressValue = uint160(bound(uint256(secondBridgeAddressValue), 0, uint256(type(uint16).max)));
    //     address secondBridgeAddress = address(secondBridgeAddressValue);

    //     vm.mockCall(
    //         address(secondBridgeAddressValue),
    //         l2TxnReq2BridgeOut.secondBridgeValue,
    //         abi.encodeWithSelector(
    //             IL1SharedBridge.bridgehubDeposit.selector,
    //             l2TxnReq2BridgeOut.chainId,
    //             randomCaller,
    //             l2TxnReq2BridgeOut.l2Value,
    //             l2TxnReq2BridgeOut.secondBridgeCalldata
    //         ),
    //         abi.encode(outputRequest)
    //     );

    //     l2TxnReq2BridgeOut.secondBridgeAddress = address(secondBridgeAddressValue);
    //     vm.expectRevert(abi.encodeWithSelector(AddressTooLow.selector, secondBridgeAddress));
    //     vm.prank(randomCaller);
    //     bridgeHub.requestL2TransactionTwoBridges{value: randomCaller.balance}(l2TxnReq2BridgeOut);
    // }

    // function test_requestL2TransactionTwoBridges_ERC20ToNonBase(
    //     uint256 chainId,
    //     uint256 mintValue,
    //     uint256 l2Value,
    //     uint256 l2GasLimit,
    //     uint256 l2GasPerPubdataByteLimit,
    //     address l2Receiver,
    //     uint256 randomValue
    // ) public useRandomToken(randomValue) {
    //     // create another token, to avoid base token
    //     TestnetERC20Token erc20Token = new TestnetERC20Token("ZKESTT", "ZkSync ERC Test Token", 18);
    //     address erc20TokenAddress = address(erc20Token);
    //     l2Value = bound(l2Value, 1, type(uint256).max);
    //     bytes memory secondBridgeCalldata = abi.encode(erc20TokenAddress, l2Value, l2Receiver);

    //     chainId = _setUpZKChainForChainId(chainId);

    //     L2TransactionRequestTwoBridgesOuter memory l2TxnReq2BridgeOut = _createMockL2TransactionRequestTwoBridgesOuter({
    //         chainId: chainId,
    //         mintValue: mintValue,
    //         l2Value: 0, // not used
    //         l2GasLimit: l2GasLimit,
    //         l2GasPerPubdataByteLimit: l2GasPerPubdataByteLimit,
    //         refundRecipient: address(0),
    //         secondBridgeValue: 0, // not used cause we are using ERC20
    //         secondBridgeCalldata: secondBridgeCalldata
    //     });

    //     address randomCaller = makeAddr("RANDOM_CALLER");
    //     bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));

    //     _setUpBaseTokenForChainId(l2TxnReq2BridgeOut.chainId, false, address(testToken));
    //     assertTrue(bridgeHub.baseToken(l2TxnReq2BridgeOut.chainId) == address(testToken));
    //     _setUpSharedBridge();

    //     _setUpSharedBridgeL2(chainId);
    //     assertTrue(bridgeHub.getZKChain(l2TxnReq2BridgeOut.chainId) == address(mockChainContract));
    //     mockChainContract.setBridgeHubAddress(address(bridgeHub));

    //     vm.mockCall(
    //         address(mockChainContract),
    //         abi.encodeWithSelector(mockChainContract.bridgehubRequestL2Transaction.selector),
    //         abi.encode(canonicalHash)
    //     );

    //     testToken.mint(randomCaller, l2TxnReq2BridgeOut.mintValue);
    //     erc20Token.mint(randomCaller, l2Value);

    //     assertEq(testToken.balanceOf(randomCaller), l2TxnReq2BridgeOut.mintValue);
    //     assertEq(erc20Token.balanceOf(randomCaller), l2Value);

    //     vm.startPrank(randomCaller);
    //     testToken.approve(sharedBridgeAddress, l2TxnReq2BridgeOut.mintValue);
    //     erc20Token.approve(secondBridgeAddress, l2Value);
    //     vm.stopPrank();
    //     vm.prank(randomCaller);
    //     bytes32 resultHash = bridgeHub.requestL2TransactionTwoBridges(l2TxnReq2BridgeOut);
    //     assertEq(resultHash, canonicalHash);

    //     assert(erc20Token.balanceOf(randomCaller) == 0);
    //     assert(testToken.balanceOf(randomCaller) == 0);
    //     assert(erc20Token.balanceOf(secondBridgeAddress) == l2Value);
    //     assert(testToken.balanceOf(sharedBridgeAddress) == l2TxnReq2BridgeOut.mintValue);

    //     l2TxnReq2BridgeOut.secondBridgeValue = 1;
    //     testToken.mint(randomCaller, l2TxnReq2BridgeOut.mintValue);
    //     vm.startPrank(randomCaller);
    //     testToken.approve(sharedBridgeAddress, l2TxnReq2BridgeOut.mintValue);
    //     vm.expectRevert(abi.encodeWithSelector(MsgValueMismatch.selector, l2TxnReq2BridgeOut.secondBridgeValue, 0));
    //     bridgeHub.requestL2TransactionTwoBridges(l2TxnReq2BridgeOut);
    //     vm.stopPrank();
    // }

    // function test_requestL2TransactionTwoBridges_ETHToNonBase(
    //     uint256 chainId,
    //     uint256 mintValue,
    //     uint256 msgValue,
    //     uint256 l2Value,
    //     uint256 l2GasLimit,
    //     uint256 l2GasPerPubdataByteLimit,
    //     address refundRecipient,
    //     uint256 secondBridgeValue,
    //     address l2Receiver,
    //     uint256 randomValue
    // ) public useRandomToken(randomValue) {
    //     secondBridgeValue = bound(secondBridgeValue, 1, type(uint256).max);
    //     bytes memory secondBridgeCalldata = abi.encode(ETH_TOKEN_ADDRESS, 0, l2Receiver);

    //     chainId = _setUpZKChainForChainId(chainId);

    //     L2TransactionRequestTwoBridgesOuter memory l2TxnReq2BridgeOut = _createMockL2TransactionRequestTwoBridgesOuter({
    //         chainId: chainId,
    //         mintValue: mintValue,
    //         l2Value: l2Value,
    //         l2GasLimit: l2GasLimit,
    //         l2GasPerPubdataByteLimit: l2GasPerPubdataByteLimit,
    //         refundRecipient: refundRecipient,
    //         secondBridgeValue: secondBridgeValue,
    //         secondBridgeCalldata: secondBridgeCalldata
    //     });

    //     _setUpBaseTokenForChainId(l2TxnReq2BridgeOut.chainId, false, address(testToken));
    //     assertTrue(bridgeHub.baseToken(l2TxnReq2BridgeOut.chainId) == address(testToken));

    //     _setUpSharedBridge();
    //     _setUpSharedBridgeL2(chainId);
    //     assertTrue(bridgeHub.getZKChain(l2TxnReq2BridgeOut.chainId) == address(mockChainContract));

    //     address randomCaller = makeAddr("RANDOM_CALLER");

    //     mockChainContract.setBridgeHubAddress(address(bridgeHub));

    //     {
    //         bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));

    //         vm.mockCall(
    //             address(mockChainContract),
    //             abi.encodeWithSelector(mockChainContract.bridgehubRequestL2Transaction.selector),
    //             abi.encode(canonicalHash)
    //         );
    //     }

    //     if (msgValue != secondBridgeValue) {
    //         vm.deal(randomCaller, msgValue);
    //         vm.expectRevert(
    //             abi.encodeWithSelector(MsgValueMismatch.selector, l2TxnReq2BridgeOut.secondBridgeValue, msgValue)
    //         );
    //         vm.prank(randomCaller);
    //         bridgeHub.requestL2TransactionTwoBridges{value: msgValue}(l2TxnReq2BridgeOut);
    //     }

    //     testToken.mint(randomCaller, l2TxnReq2BridgeOut.mintValue);
    //     assertEq(testToken.balanceOf(randomCaller), l2TxnReq2BridgeOut.mintValue);
    //     vm.prank(randomCaller);
    //     testToken.approve(sharedBridgeAddress, l2TxnReq2BridgeOut.mintValue);

    //     vm.deal(randomCaller, l2TxnReq2BridgeOut.secondBridgeValue);
    //     vm.prank(randomCaller);
    //     bridgeHub.requestL2TransactionTwoBridges{value: randomCaller.balance}(l2TxnReq2BridgeOut);
    // }

    /////////////////////////////////////////////////////////
    // INTERNAL UTILITY FUNCTIONS
    /////////////////////////////////////////////////////////

    function _createMockL2TransactionRequestTwoBridgesOuter(
        uint256 chainId,
        uint256 mintValue,
        uint256 l2Value,
        uint256 l2GasLimit,
        uint256 l2GasPerPubdataByteLimit,
        address refundRecipient,
        uint256 secondBridgeValue,
        bytes memory secondBridgeCalldata
    ) internal view returns (L2TransactionRequestTwoBridgesOuter memory) {
        L2TransactionRequestTwoBridgesOuter memory l2Req;

        // Don't let the mintValue + secondBridgeValue go beyond type(uint256).max since that calculation is required to be done by our test: test_requestL2TransactionTwoBridges_ETHCase

        mintValue = bound(mintValue, 0, (type(uint256).max) / 2);
        secondBridgeValue = bound(secondBridgeValue, 0, (type(uint256).max) / 2);

        l2Req.chainId = chainId;
        l2Req.mintValue = mintValue;
        l2Req.l2Value = l2Value;
        l2Req.l2GasLimit = l2GasLimit;
        l2Req.l2GasPerPubdataByteLimit = l2GasPerPubdataByteLimit;
        l2Req.refundRecipient = refundRecipient;
        l2Req.secondBridgeAddress = secondBridgeAddress;
        l2Req.secondBridgeValue = secondBridgeValue;
        l2Req.secondBridgeCalldata = secondBridgeCalldata;

        return l2Req;
    }

    function _createMockL2Message(
        uint16 randomTxNumInBatch,
        address randomSender,
        bytes memory randomData
    ) internal pure returns (L2Message memory) {
        L2Message memory l2Message;

        l2Message.txNumberInBatch = randomTxNumInBatch;
        l2Message.sender = randomSender;
        l2Message.data = randomData;

        return l2Message;
    }

    function _createMockL2Log(
        uint8 randomL2ShardId,
        bool randomIsService,
        uint16 randomTxNumInBatch,
        address randomSender,
        bytes32 randomKey,
        bytes32 randomValue
    ) internal pure returns (L2Log memory) {
        L2Log memory l2Log;

        l2Log.l2ShardId = randomL2ShardId;
        l2Log.isService = randomIsService;
        l2Log.txNumberInBatch = randomTxNumInBatch;
        l2Log.sender = randomSender;
        l2Log.key = randomKey;
        l2Log.value = randomValue;

        return l2Log;
    }

    function _createNewChainInitData(
        bool isFreezable,
        bytes4[] memory mockSelectors,
        address, //mockInitAddress,
        bytes memory //mockInitCalldata
    ) internal returns (bytes memory) {
        bytes4[] memory singleSelector = new bytes4[](1);
        singleSelector[0] = bytes4(0xabcdef12);

        Diamond.FacetCut memory facetCut;
        Diamond.DiamondCutData memory diamondCutData;

        facetCut.facet = address(this); // for a random address, it will fail the check of _facet.code.length > 0
        facetCut.action = Diamond.Action.Add;
        facetCut.isFreezable = isFreezable;
        if (mockSelectors.length == 0) {
            mockSelectors = singleSelector;
        }
        facetCut.selectors = mockSelectors;

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = facetCut;

        diamondCutData.facetCuts = facetCuts;
        diamondCutData.initAddress = address(0);
        diamondCutData.initCalldata = "";

        ChainCreationParams memory params = ChainCreationParams({
            diamondCut: diamondCutData,
            // Just some dummy values:
            genesisUpgrade: address(0x01),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: uint64(0x01),
            genesisBatchCommitment: bytes32(uint256(0x01)),
            forceDeploymentsData: bytes("")
        });

        mockCTM.setChainCreationParams(params);

        return abi.encode(abi.encode(diamondCutData), bytes(""));
    }

    function _setUpZKChainForChainId(uint256 mockChainId) internal returns (uint256 mockChainIdInRange) {
        mockChainId = bound(mockChainId, 1, type(uint48).max);
        mockChainIdInRange = mockChainId;
        vm.prank(bridgeOwner);
        bridgeHub.addChainTypeManager(address(mockCTM));

        // We need to set the chainTypeManager of the mockChainId to mockCTM
        // There is no function to do that in the bridgeHub
        // So, perhaps we will have to manually set the values in the chainTypeManager mapping via a foundry cheatcode
        assertTrue(!(bridgeHub.chainTypeManager(mockChainId) == address(mockCTM)));

        dummyBridgehub.setCTM(mockChainId, address(mockCTM));
        dummyBridgehub.setZKChain(mockChainId, address(mockChainContract));
    }

    function _setUpBaseTokenForChainId(uint256 mockChainId, bool tokenIsETH, address token) internal {
        address baseToken = tokenIsETH ? ETH_TOKEN_ADDRESS : token;

        stdstore.target(address(bridgeHub)).sig("baseToken(uint256)").with_key(mockChainId).checked_write(baseToken);
    }

    // function _setUpSharedBridge() internal {
    //     vm.prank(bridgeOwner);
    //     bridgeHub.setSharedBridge(sharedBridgeAddress);
    // }

    // function _setUpSharedBridgeL2(uint256 _chainId) internal {
    //     _chainId = bound(_chainId, 1, type(uint48).max);

    //     vm.prank(bridgeOwner);
    //     sharedBridge.initializeChainGovernance(_chainId, mockL2Contract);

    //     assertEq(sharedBridge.l2BridgeAddress(_chainId), mockL2Contract);

    //     vm.prank(bridgeOwner);
    //     secondBridge.initializeChainGovernance(_chainId, mockL2Contract);

    //     assertEq(secondBridge.l2BridgeAddress(_chainId), mockL2Contract);
    // }

    function _createMockL2TransactionRequestDirect(
        uint256 mockChainId,
        uint256 mockMintValue,
        address mockL2Contract,
        uint256 mockL2Value,
        bytes memory mockL2Calldata,
        uint256 mockL2GasLimit,
        // solhint-disable-next-line no-unused-vars
        uint256 mockL2GasPerPubdataByteLimit,
        bytes[] memory mockFactoryDeps,
        address mockRefundRecipient
    ) internal pure returns (L2TransactionRequestDirect memory) {
        L2TransactionRequestDirect memory l2TxnReqDirect;

        l2TxnReqDirect.chainId = mockChainId;
        l2TxnReqDirect.mintValue = mockMintValue;
        l2TxnReqDirect.l2Contract = mockL2Contract;
        l2TxnReqDirect.l2Value = mockL2Value;
        l2TxnReqDirect.l2Calldata = mockL2Calldata;
        l2TxnReqDirect.l2GasLimit = mockL2GasLimit;
        l2TxnReqDirect.l2GasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        l2TxnReqDirect.factoryDeps = mockFactoryDeps;
        l2TxnReqDirect.refundRecipient = mockRefundRecipient;

        return l2TxnReqDirect;
    }

    function _createBhL2TxnRequest(
        bytes[] memory mockFactoryDepsBH
    ) internal returns (BridgehubL2TransactionRequest memory) {
        BridgehubL2TransactionRequest memory bhL2TxnRequest;

        bhL2TxnRequest.sender = makeAddr("BH_L2_REQUEST_SENDER");
        bhL2TxnRequest.contractL2 = makeAddr("BH_L2_REQUEST_CONTRACT");
        bhL2TxnRequest.mintValue = block.timestamp;
        bhL2TxnRequest.l2Value = block.timestamp * 2;
        bhL2TxnRequest.l2Calldata = abi.encode("mock L2 Calldata");
        bhL2TxnRequest.l2GasLimit = block.timestamp * 3;
        bhL2TxnRequest.l2GasPerPubdataByteLimit = block.timestamp * 4;
        bhL2TxnRequest.factoryDeps = mockFactoryDepsBH;
        bhL2TxnRequest.refundRecipient = makeAddr("BH_L2_REQUEST_REFUND_RECIPIENT");

        return bhL2TxnRequest;
    }

    function _restrictArraySize(bytes[] memory longArray, uint256 newSize) internal pure returns (bytes[] memory) {
        bytes[] memory shortArray = new bytes[](newSize);

        for (uint256 i; i < newSize; i++) {
            shortArray[i] = longArray[i];
        }

        return shortArray;
    }

    /////////////////////////////////////////////////////////
    // OLDER (HIGH-LEVEL MOCKED) TESTS
    ////////////////////////////////////////////////////////

    function test_proveL2MessageInclusion_old(
        uint256 mockChainId,
        uint256 mockBatchNumber,
        uint256 mockIndex,
        bytes32[] memory mockProof,
        uint16 randomTxNumInBatch,
        address randomSender,
        bytes memory randomData
    ) public {
        vm.startPrank(bridgeOwner);
        bridgeHub.addChainTypeManager(address(mockCTM));
        vm.stopPrank();

        L2Message memory l2Message = _createMockL2Message(randomTxNumInBatch, randomSender, randomData);

        vm.mockCall(
            address(bridgeHub),
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                bridgeHub.proveL2MessageInclusion.selector,
                mockChainId,
                mockBatchNumber,
                mockIndex,
                l2Message,
                mockProof
            ),
            abi.encode(true)
        );

        assertTrue(
            bridgeHub.proveL2MessageInclusion({
                _chainId: mockChainId,
                _batchNumber: mockBatchNumber,
                _index: mockIndex,
                _message: l2Message,
                _proof: mockProof
            })
        );
    }

    function test_proveL2LogInclusion_old(
        uint256 mockChainId,
        uint256 mockBatchNumber,
        uint256 mockIndex,
        bytes32[] memory mockProof,
        uint8 randomL2ShardId,
        bool randomIsService,
        uint16 randomTxNumInBatch,
        address randomSender,
        bytes32 randomKey,
        bytes32 randomValue
    ) public {
        vm.startPrank(bridgeOwner);
        bridgeHub.addChainTypeManager(address(mockCTM));
        vm.stopPrank();

        L2Log memory l2Log = _createMockL2Log({
            randomL2ShardId: randomL2ShardId,
            randomIsService: randomIsService,
            randomTxNumInBatch: randomTxNumInBatch,
            randomSender: randomSender,
            randomKey: randomKey,
            randomValue: randomValue
        });

        vm.mockCall(
            address(bridgeHub),
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                bridgeHub.proveL2LogInclusion.selector,
                mockChainId,
                mockBatchNumber,
                mockIndex,
                l2Log,
                mockProof
            ),
            abi.encode(true)
        );

        assertTrue(
            bridgeHub.proveL2LogInclusion({
                _chainId: mockChainId,
                _batchNumber: mockBatchNumber,
                _index: mockIndex,
                _log: l2Log,
                _proof: mockProof
            })
        );
    }

    function test_proveL1ToL2TransactionStatus_old(
        uint256 randomChainId,
        bytes32 randomL2TxHash,
        uint256 randomL2BatchNumber,
        uint256 randomL2MessageIndex,
        uint16 randomL2TxNumberInBatch,
        bytes32[] memory randomMerkleProof,
        bool randomResultantBool
    ) public {
        vm.startPrank(bridgeOwner);
        bridgeHub.addChainTypeManager(address(mockCTM));
        vm.stopPrank();

        TxStatus txStatus;

        if (randomChainId % 2 == 0) {
            txStatus = TxStatus.Failure;
        } else {
            txStatus = TxStatus.Success;
        }

        vm.mockCall(
            address(bridgeHub),
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                bridgeHub.proveL1ToL2TransactionStatus.selector,
                randomChainId,
                randomL2TxHash,
                randomL2BatchNumber,
                randomL2MessageIndex,
                randomL2TxNumberInBatch,
                randomMerkleProof,
                txStatus
            ),
            abi.encode(randomResultantBool)
        );

        assertTrue(
            bridgeHub.proveL1ToL2TransactionStatus({
                _chainId: randomChainId,
                _l2TxHash: randomL2TxHash,
                _l2BatchNumber: randomL2BatchNumber,
                _l2MessageIndex: randomL2MessageIndex,
                _l2TxNumberInBatch: randomL2TxNumberInBatch,
                _merkleProof: randomMerkleProof,
                _status: txStatus
            }) == randomResultantBool
        );
    }
}