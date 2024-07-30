//SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.24;

import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {ChainCreationParams} from "contracts/state-transition/IStateTransitionManager.sol";
import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {DummyStateTransitionManagerWBH} from "contracts/dev-contracts/test/DummyStateTransitionManagerWithBridgeHubAddress.sol";
import {DummyHyperchain} from "contracts/dev-contracts/test/DummyHyperchain.sol";
import {IL1SharedBridge} from "contracts/bridge/interfaces/IL1SharedBridge.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {L2TransactionRequestTwoBridgesInner} from "contracts/bridgehub/IBridgehub.sol";
import {L2Message, L2Log, TxStatus, BridgehubL2TransactionRequest} from "contracts/common/Messaging.sol";
import {ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA, MAX_NEW_FACTORY_DEPS, TWO_BRIDGES_MAGIC_VALUE} from "contracts/common/Config.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";

contract ExperimentalBridgeTest is Test {
    using stdStorage for StdStorage;

    Bridgehub bridgeHub;
    address public bridgeOwner;
    DummyStateTransitionManagerWBH mockSTM;
    DummyHyperchain mockChainContract;
    L1SharedBridge sharedBridge;
    address sharedBridgeAddress;
    address secondBridgeAddress;
    L1SharedBridge secondBridge;
    TestnetERC20Token testToken;
    TestnetERC20Token testToken6;
    TestnetERC20Token testToken8;
    TestnetERC20Token testToken18;

    address mockL2Contract;

    uint256 eraChainId;

    event NewChain(uint256 indexed chainId, address stateTransitionManager, address indexed chainGovernance);

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
        bridgeHub = new Bridgehub();
        bridgeOwner = makeAddr("BRIDGE_OWNER");
        mockSTM = new DummyStateTransitionManagerWBH(address(bridgeHub));
        mockChainContract = new DummyHyperchain(address(bridgeHub), eraChainId);
        mockL2Contract = makeAddr("mockL2Contract");

        // mocks to use in bridges instead of using a dummy one
        address mockL1WethAddress = makeAddr("Weth");
        address eraDiamondProxy = makeAddr("eraDiamondProxy");

        sharedBridge = new L1SharedBridge(mockL1WethAddress, bridgeHub, eraChainId, eraDiamondProxy);
        address defaultOwner = sharedBridge.owner();
        vm.prank(defaultOwner);
        sharedBridge.transferOwnership(bridgeOwner);
        vm.prank(bridgeOwner);
        sharedBridge.acceptOwnership();

        secondBridge = new L1SharedBridge(mockL1WethAddress, bridgeHub, eraChainId, eraDiamondProxy);
        defaultOwner = secondBridge.owner();
        vm.prank(defaultOwner);
        secondBridge.transferOwnership(bridgeOwner);
        vm.prank(bridgeOwner);
        secondBridge.acceptOwnership();

        sharedBridgeAddress = address(sharedBridge);
        secondBridgeAddress = address(secondBridge);
        testToken18 = new TestnetERC20Token("ZKSTT", "ZkSync Test Token", 18);
        testToken6 = new TestnetERC20Token("USDC", "USD Coin", 6);
        testToken8 = new TestnetERC20Token("WBTC", "Wrapped Bitcoin", 8);

        // test if the ownership of the bridgeHub is set correctly or not
        defaultOwner = bridgeHub.owner();

        // Now, the `reentrancyGuardInitializer` should prevent anyone from calling `initialize` since we have called the constructor of the contract
        vm.expectRevert(bytes("1B"));
        bridgeHub.initialize(bridgeOwner);

        vm.store(
            address(mockChainContract),
            0x8e94fed44239eb2314ab7a406345e6c5a8f0ccedf3b600de3d004e672c33abf4,
            bytes32(uint256(1))
        );
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
        assertEq(address(0), bridgeHub.admin());
        vm.assume(randomDeployer != otherRandomDeployer);

        vm.prank(bridgeHub.owner());
        bridgeHub.setPendingAdmin(randomDeployer);

        vm.expectRevert(bytes("n42"));
        vm.prank(otherRandomDeployer);
        bridgeHub.acceptAdmin();

        assertEq(address(0), bridgeHub.admin());
    }

    function test_onlyOwnerCanSetDeployer(address randomDeployer) public {
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
            vm.expectRevert(bytes("Bridgehub: not owner or admin"));
            bridgeHub.setPendingAdmin(randomDeployer);

            // The deployer shouldn't have changed.
            assertEq(address(0), bridgeHub.admin());
        }
    }

    function test_addStateTransitionManager(address randomAddressWithoutTheCorrectInterface) public {
        bool isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isSTMRegistered);

        vm.prank(bridgeOwner);
        bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);

        isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isSTMRegistered);

        // An address that has already been registered, cannot be registered again (at least not before calling `removeStateTransitionManager`).
        vm.prank(bridgeOwner);
        vm.expectRevert(bytes("Bridgehub: state transition already registered"));
        bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);

        isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isSTMRegistered);
    }

    function test_addStateTransitionManager_cannotBeCalledByRandomAddress(
        address randomCaller,
        address randomAddressWithoutTheCorrectInterface
    ) public {
        bool isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isSTMRegistered);

        if (randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));

            bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);
        }

        vm.prank(bridgeOwner);
        bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);

        isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isSTMRegistered);

        // An address that has already been registered, cannot be registered again (at least not before calling `removeStateTransitionManager`).
        vm.prank(bridgeOwner);
        vm.expectRevert(bytes("Bridgehub: state transition already registered"));
        bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);

        // Definitely not by a random caller
        if (randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert("Ownable: caller is not the owner");
            bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);
        }

        isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isSTMRegistered);
    }

    function test_removeStateTransitionManager(address randomAddressWithoutTheCorrectInterface) public {
        bool isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isSTMRegistered);

        // A non-existent STM cannot be removed
        vm.prank(bridgeOwner);
        vm.expectRevert(bytes("Bridgehub: state transition not registered yet"));
        bridgeHub.removeStateTransitionManager(randomAddressWithoutTheCorrectInterface);

        // Let's first register our particular stateTransitionManager
        vm.prank(bridgeOwner);
        bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);

        isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isSTMRegistered);

        // Only an address that has already been registered, can be removed.
        vm.prank(bridgeOwner);
        bridgeHub.removeStateTransitionManager(randomAddressWithoutTheCorrectInterface);

        isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isSTMRegistered);

        // An already removed STM cannot be removed again
        vm.prank(bridgeOwner);
        vm.expectRevert(bytes("Bridgehub: state transition not registered yet"));
        bridgeHub.removeStateTransitionManager(randomAddressWithoutTheCorrectInterface);
    }

    function test_removeStateTransitionManager_cannotBeCalledByRandomAddress(
        address randomAddressWithoutTheCorrectInterface,
        address randomCaller
    ) public {
        bool isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isSTMRegistered);

        if (randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));

            bridgeHub.removeStateTransitionManager(randomAddressWithoutTheCorrectInterface);
        }

        // A non-existent STM cannot be removed
        vm.prank(bridgeOwner);
        vm.expectRevert(bytes("Bridgehub: state transition not registered yet"));
        bridgeHub.removeStateTransitionManager(randomAddressWithoutTheCorrectInterface);

        // Let's first register our particular stateTransitionManager
        vm.prank(bridgeOwner);
        bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);

        isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isSTMRegistered);

        // Only an address that has already been registered, can be removed.
        vm.prank(bridgeOwner);
        bridgeHub.removeStateTransitionManager(randomAddressWithoutTheCorrectInterface);

        isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isSTMRegistered);

        // An already removed STM cannot be removed again
        vm.prank(bridgeOwner);
        vm.expectRevert(bytes("Bridgehub: state transition not registered yet"));
        bridgeHub.removeStateTransitionManager(randomAddressWithoutTheCorrectInterface);

        // Not possible by a randomcaller as well
        if (randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            bridgeHub.removeStateTransitionManager(randomAddressWithoutTheCorrectInterface);
        }
    }

    function test_addToken(address, address randomAddress, uint256 randomValue) public useRandomToken(randomValue) {
        assertTrue(!bridgeHub.tokenIsRegistered(randomAddress), "This random address is not registered as a token");

        vm.prank(bridgeOwner);
        bridgeHub.addToken(randomAddress);

        assertTrue(
            bridgeHub.tokenIsRegistered(randomAddress),
            "after call from the bridgeowner, this randomAddress should be a registered token"
        );

        if (randomAddress != address(testToken)) {
            // Testing to see if an actual ERC20 implementation can also be added or not
            vm.prank(bridgeOwner);
            bridgeHub.addToken(address(testToken));

            assertTrue(bridgeHub.tokenIsRegistered(address(testToken)));
        }

        // An already registered token cannot be registered again
        vm.prank(bridgeOwner);
        vm.expectRevert("Bridgehub: token already registered");
        bridgeHub.addToken(randomAddress);
    }

    function test_addToken_cannotBeCalledByRandomAddress(
        address randomAddress,
        address randomCaller,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        if (randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            bridgeHub.addToken(randomAddress);
        }

        assertTrue(!bridgeHub.tokenIsRegistered(randomAddress), "This random address is not registered as a token");

        vm.prank(bridgeOwner);
        bridgeHub.addToken(randomAddress);

        assertTrue(
            bridgeHub.tokenIsRegistered(randomAddress),
            "after call from the bridgeowner, this randomAddress should be a registered token"
        );

        if (randomAddress != address(testToken)) {
            // Testing to see if an actual ERC20 implementation can also be added or not
            vm.prank(bridgeOwner);
            bridgeHub.addToken(address(testToken));

            assertTrue(bridgeHub.tokenIsRegistered(address(testToken)));
        }

        // An already registered token cannot be registered again by randomCaller
        if (randomCaller != bridgeOwner) {
            vm.prank(bridgeOwner);
            vm.expectRevert("Bridgehub: token already registered");
            bridgeHub.addToken(randomAddress);
        }
    }

    function test_setSharedBridge(address randomAddress) public {
        assertTrue(
            bridgeHub.sharedBridge() == IL1SharedBridge(address(0)),
            "This random address is not registered as sharedBridge"
        );

        vm.prank(bridgeOwner);
        bridgeHub.setSharedBridge(randomAddress);

        assertTrue(
            bridgeHub.sharedBridge() == IL1SharedBridge(randomAddress),
            "after call from the bridgeowner, this randomAddress should be the registered sharedBridge"
        );
    }

    function test_setSharedBridge_cannotBeCalledByRandomAddress(address randomCaller, address randomAddress) public {
        if (randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            bridgeHub.setSharedBridge(randomAddress);
        }

        assertTrue(
            bridgeHub.sharedBridge() == IL1SharedBridge(address(0)),
            "This random address is not registered as sharedBridge"
        );

        vm.prank(bridgeOwner);
        bridgeHub.setSharedBridge(randomAddress);

        assertTrue(
            bridgeHub.sharedBridge() == IL1SharedBridge(randomAddress),
            "after call from the bridgeowner, this randomAddress should be the registered sharedBridge"
        );
    }

    uint256 newChainId;
    address admin;

    function test_pause_createNewChain(
        uint256 chainId,
        uint256 salt,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        chainId = bound(chainId, 1, type(uint48).max);
        address deployerAddress = makeAddr("DEPLOYER_ADDRESS");
        admin = makeAddr("NEW_CHAIN_ADMIN");

        vm.prank(bridgeOwner);
        bridgeHub.pause();
        vm.prank(bridgeOwner);
        bridgeHub.setPendingAdmin(deployerAddress);
        vm.prank(deployerAddress);
        bridgeHub.acceptAdmin();

        vm.expectRevert("Pausable: paused");
        vm.prank(deployerAddress);
        bridgeHub.createNewChain({
            _chainId: chainId,
            _stateTransitionManager: address(mockSTM),
            _baseToken: address(testToken),
            _salt: salt,
            _admin: admin,
            _initData: bytes("")
        });

        vm.prank(bridgeOwner);
        bridgeHub.unpause();

        vm.expectRevert("Bridgehub: state transition not registered");
        vm.prank(deployerAddress);
        bridgeHub.createNewChain({
            _chainId: 1,
            _stateTransitionManager: address(mockSTM),
            _baseToken: address(testToken),
            _salt: uint256(123),
            _admin: admin,
            _initData: bytes("")
        });
    }

    function test_RevertWhen_STMNotRegisteredOnCreate(
        uint256 chainId,
        uint256 salt,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        chainId = bound(chainId, 1, type(uint48).max);
        address deployerAddress = makeAddr("DEPLOYER_ADDRESS");
        admin = makeAddr("NEW_CHAIN_ADMIN");

        vm.prank(bridgeOwner);
        bridgeHub.setPendingAdmin(deployerAddress);
        vm.prank(deployerAddress);
        bridgeHub.acceptAdmin();

        chainId = bound(chainId, 1, type(uint48).max);
        vm.expectRevert("Bridgehub: state transition not registered");
        vm.prank(deployerAddress);
        bridgeHub.createNewChain({
            _chainId: chainId,
            _stateTransitionManager: address(mockSTM),
            _baseToken: address(testToken),
            _salt: salt,
            _admin: admin,
            _initData: bytes("")
        });
    }

    function test_RevertWhen_wrongChainIdOnCreate(
        uint256 chainId,
        uint256 salt,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        chainId = bound(chainId, 1, type(uint48).max);
        address deployerAddress = makeAddr("DEPLOYER_ADDRESS");
        admin = makeAddr("NEW_CHAIN_ADMIN");

        vm.prank(bridgeOwner);
        bridgeHub.setPendingAdmin(deployerAddress);
        vm.prank(deployerAddress);
        bridgeHub.acceptAdmin();

        chainId = bound(chainId, type(uint48).max + uint256(1), type(uint256).max);
        vm.expectRevert("Bridgehub: chainId too large");
        vm.prank(deployerAddress);
        bridgeHub.createNewChain({
            _chainId: chainId,
            _stateTransitionManager: address(mockSTM),
            _baseToken: address(testToken),
            _salt: salt,
            _admin: admin,
            _initData: bytes("")
        });

        chainId = 0;
        vm.expectRevert("Bridgehub: chainId cannot be 0");
        vm.prank(deployerAddress);
        bridgeHub.createNewChain({
            _chainId: chainId,
            _stateTransitionManager: address(mockSTM),
            _baseToken: address(testToken),
            _salt: salt,
            _admin: admin,
            _initData: bytes("")
        });
    }

    function test_RevertWhen_tokenNotRegistered(
        uint256 chainId,
        uint256 salt,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        chainId = bound(chainId, 1, type(uint48).max);
        address deployerAddress = makeAddr("DEPLOYER_ADDRESS");
        admin = makeAddr("NEW_CHAIN_ADMIN");

        vm.prank(bridgeOwner);
        bridgeHub.setPendingAdmin(deployerAddress);
        vm.prank(deployerAddress);
        bridgeHub.acceptAdmin();

        vm.startPrank(bridgeOwner);
        bridgeHub.addStateTransitionManager(address(mockSTM));
        vm.stopPrank();

        vm.expectRevert("Bridgehub: token not registered");
        vm.prank(deployerAddress);
        bridgeHub.createNewChain({
            _chainId: chainId,
            _stateTransitionManager: address(mockSTM),
            _baseToken: address(testToken),
            _salt: salt,
            _admin: admin,
            _initData: bytes("")
        });
    }

    function test_RevertWhen_wethBridgeNotSet(
        uint256 chainId,
        uint256 salt,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        chainId = bound(chainId, 1, type(uint48).max);
        address deployerAddress = makeAddr("DEPLOYER_ADDRESS");
        admin = makeAddr("NEW_CHAIN_ADMIN");

        vm.prank(bridgeOwner);
        bridgeHub.setPendingAdmin(deployerAddress);
        vm.prank(deployerAddress);
        bridgeHub.acceptAdmin();

        vm.startPrank(bridgeOwner);
        bridgeHub.addStateTransitionManager(address(mockSTM));
        bridgeHub.addToken(address(testToken));
        vm.stopPrank();

        vm.expectRevert("Bridgehub: weth bridge not set");
        vm.prank(deployerAddress);
        bridgeHub.createNewChain({
            _chainId: chainId,
            _stateTransitionManager: address(mockSTM),
            _baseToken: address(testToken),
            _salt: salt,
            _admin: admin,
            _initData: bytes("")
        });
    }

    function test_RevertWhen_chainIdAlreadyRegistered(
        uint256 chainId,
        uint256 salt,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        address deployerAddress = makeAddr("DEPLOYER_ADDRESS");
        admin = makeAddr("NEW_CHAIN_ADMIN");
        vm.prank(bridgeOwner);
        bridgeHub.setPendingAdmin(deployerAddress);
        vm.prank(deployerAddress);
        bridgeHub.acceptAdmin();

        vm.startPrank(bridgeOwner);
        bridgeHub.addStateTransitionManager(address(mockSTM));
        bridgeHub.addToken(address(testToken));
        bridgeHub.setSharedBridge(sharedBridgeAddress);
        vm.stopPrank();

        chainId = bound(chainId, 1, type(uint48).max);
        stdstore.target(address(bridgeHub)).sig("stateTransitionManager(uint256)").with_key(chainId).checked_write(
            address(mockSTM)
        );

        vm.expectRevert("Bridgehub: chainId already registered");
        vm.prank(deployerAddress);
        bridgeHub.createNewChain({
            _chainId: chainId,
            _stateTransitionManager: address(mockSTM),
            _baseToken: address(testToken),
            _salt: salt,
            _admin: admin,
            _initData: bytes("")
        });
    }

    function test_createNewChain(
        address randomCaller,
        uint256 chainId,
        bool isFreezable,
        bytes4[] memory mockSelectors,
        address mockInitAddress,
        bytes memory mockInitCalldata,
        uint256 salt,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        address deployerAddress = makeAddr("DEPLOYER_ADDRESS");
        admin = makeAddr("NEW_CHAIN_ADMIN");
        chainId = bound(chainId, 1, type(uint48).max);

        vm.prank(bridgeOwner);
        bridgeHub.setPendingAdmin(deployerAddress);
        vm.prank(deployerAddress);
        bridgeHub.acceptAdmin();

        vm.startPrank(bridgeOwner);
        bridgeHub.addStateTransitionManager(address(mockSTM));
        bridgeHub.addToken(address(testToken));
        bridgeHub.setSharedBridge(sharedBridgeAddress);
        vm.stopPrank();

        if (randomCaller != deployerAddress && randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Bridgehub: not owner or admin"));
            bridgeHub.createNewChain({
                _chainId: chainId,
                _stateTransitionManager: address(mockSTM),
                _baseToken: address(testToken),
                _salt: salt,
                _admin: admin,
                _initData: bytes("")
            });
        }

        vm.prank(mockSTM.owner());
        bytes memory _newChainInitData = _createNewChainInitData(
            isFreezable,
            mockSelectors,
            mockInitAddress,
            mockInitCalldata
        );

        // bridgeHub.createNewChain => stateTransitionManager.createNewChain => this function sets the stateTransition mapping
        // of `chainId`, let's emulate that using foundry cheatcodes or let's just use the extra function we introduced in our mockSTM
        mockSTM.setHyperchain(chainId, address(mockChainContract));
        assertTrue(mockSTM.getHyperchain(chainId) == address(mockChainContract));

        vm.startPrank(deployerAddress);
        vm.mockCall(
            address(mockSTM),
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                mockSTM.createNewChain.selector,
                chainId,
                address(testToken),
                sharedBridgeAddress,
                admin,
                _newChainInitData
            ),
            bytes("")
        );

        vm.expectEmit(true, true, true, true, address(bridgeHub));
        emit NewChain(chainId, address(mockSTM), admin);

        newChainId = bridgeHub.createNewChain({
            _chainId: chainId,
            _stateTransitionManager: address(mockSTM),
            _baseToken: address(testToken),
            _salt: uint256(chainId * 2),
            _admin: admin,
            _initData: _newChainInitData
        });

        vm.stopPrank();
        vm.clearMockedCalls();

        assertTrue(bridgeHub.stateTransitionManager(newChainId) == address(mockSTM));
        assertTrue(bridgeHub.baseToken(newChainId) == address(testToken));
    }

    function test_getHyperchain(uint256 mockChainId) public {
        mockChainId = _setUpHyperchainForChainId(mockChainId);

        // Now the following statements should be true as well:
        assertTrue(bridgeHub.stateTransitionManager(mockChainId) == address(mockSTM));
        address returnedHyperchain = bridgeHub.getHyperchain(mockChainId);

        assertEq(returnedHyperchain, address(mockChainContract));
    }

    function test_proveL2MessageInclusion(
        uint256 mockChainId,
        uint256 mockBatchNumber,
        uint256 mockIndex,
        bytes32[] memory mockProof,
        uint16 randomTxNumInBatch,
        address randomSender,
        bytes memory randomData
    ) public {
        mockChainId = _setUpHyperchainForChainId(mockChainId);

        // Now the following statements should be true as well:
        assertTrue(bridgeHub.stateTransitionManager(mockChainId) == address(mockSTM));
        assertTrue(bridgeHub.getHyperchain(mockChainId) == address(mockChainContract));

        // Creating a random L2Message::l2Message so that we pass the correct parameters to `proveL2MessageInclusion`
        L2Message memory l2Message = _createMockL2Message(randomTxNumInBatch, randomSender, randomData);

        // Since we have used random data for the `bridgeHub.proveL2MessageInclusion` function which basically forwards the call
        // to the same function in the mailbox, we will mock the call to the mailbox to return true and see if it works.
        vm.mockCall(
            address(mockChainContract),
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                mockChainContract.proveL2MessageInclusion.selector,
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
        vm.clearMockedCalls();
    }

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
        mockChainId = _setUpHyperchainForChainId(mockChainId);

        // Now the following statements should be true as well:
        assertTrue(bridgeHub.stateTransitionManager(mockChainId) == address(mockSTM));
        assertTrue(bridgeHub.getHyperchain(mockChainId) == address(mockChainContract));

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
        randomChainId = _setUpHyperchainForChainId(randomChainId);

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
        mockChainId = _setUpHyperchainForChainId(mockChainId);

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

    function _prepareETHL2TransactionDirectRequest(
        uint256 mockChainId,
        uint256 mockMintValue,
        address mockL2Contract,
        uint256 mockL2Value,
        bytes memory mockL2Calldata,
        uint256 mockL2GasLimit,
        uint256 mockL2GasPerPubdataByteLimit,
        bytes[] memory mockFactoryDeps,
        address randomCaller
    ) internal returns (L2TransactionRequestDirect memory l2TxnReqDirect) {
        if (mockFactoryDeps.length > MAX_NEW_FACTORY_DEPS) {
            mockFactoryDeps = _restrictArraySize(mockFactoryDeps, MAX_NEW_FACTORY_DEPS);
        }

        l2TxnReqDirect = _createMockL2TransactionRequestDirect({
            mockChainId: mockChainId,
            mockMintValue: mockMintValue,
            mockL2Contract: mockL2Contract,
            mockL2Value: mockL2Value,
            mockL2Calldata: mockL2Calldata,
            mockL2GasLimit: mockL2GasLimit,
            mockL2GasPerPubdataByteLimit: mockL2GasPerPubdataByteLimit,
            mockFactoryDeps: mockFactoryDeps,
            mockRefundRecipient: address(0)
        });

        l2TxnReqDirect.chainId = _setUpHyperchainForChainId(l2TxnReqDirect.chainId);

        assertTrue(!(bridgeHub.baseToken(l2TxnReqDirect.chainId) == ETH_TOKEN_ADDRESS));
        _setUpBaseTokenForChainId(l2TxnReqDirect.chainId, true, address(0));
        assertTrue(bridgeHub.baseToken(l2TxnReqDirect.chainId) == ETH_TOKEN_ADDRESS);

        _setUpSharedBridge();
        _setUpSharedBridgeL2(mockChainId);

        assertTrue(bridgeHub.getHyperchain(l2TxnReqDirect.chainId) == address(mockChainContract));
        bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));

        vm.mockCall(
            address(mockChainContract),
            abi.encodeWithSelector(mockChainContract.bridgehubRequestL2Transaction.selector),
            abi.encode(canonicalHash)
        );

        mockChainContract.setFeeParams();
        mockChainContract.setBaseTokenGasMultiplierPrice(uint128(1), uint128(1));
        mockChainContract.setBridgeHubAddress(address(bridgeHub));
        assertTrue(mockChainContract.getBridgeHubAddress() == address(bridgeHub));
    }

    function test_requestL2TransactionDirect_RevertWhen_incorrectETHParams(
        uint256 mockChainId,
        uint256 mockMintValue,
        address mockL2Contract,
        uint256 mockL2Value,
        uint256 msgValue,
        bytes memory mockL2Calldata,
        uint256 mockL2GasLimit,
        uint256 mockL2GasPerPubdataByteLimit,
        bytes[] memory mockFactoryDeps
    ) public {
        address randomCaller = makeAddr("RANDOM_CALLER");
        vm.assume(msgValue != mockMintValue);

        L2TransactionRequestDirect memory l2TxnReqDirect = _prepareETHL2TransactionDirectRequest({
            mockChainId: mockChainId,
            mockMintValue: mockMintValue,
            mockL2Contract: mockL2Contract,
            mockL2Value: mockL2Value,
            mockL2Calldata: mockL2Calldata,
            mockL2GasLimit: mockL2GasLimit,
            mockL2GasPerPubdataByteLimit: mockL2GasPerPubdataByteLimit,
            mockFactoryDeps: mockFactoryDeps,
            randomCaller: randomCaller
        });

        vm.deal(randomCaller, msgValue);
        vm.expectRevert("Bridgehub: msg.value mismatch 1");
        vm.prank(randomCaller);
        bridgeHub.requestL2TransactionDirect{value: msgValue}(l2TxnReqDirect);
    }

    function test_requestL2TransactionDirect_ETHCase(
        uint256 mockChainId,
        uint256 mockMintValue,
        address mockL2Contract,
        uint256 mockL2Value,
        bytes memory mockL2Calldata,
        uint256 mockL2GasLimit,
        uint256 mockL2GasPerPubdataByteLimit,
        bytes[] memory mockFactoryDeps,
        uint256 gasPrice
    ) public {
        address randomCaller = makeAddr("RANDOM_CALLER");
        mockChainId = bound(mockChainId, 1, type(uint48).max);

        L2TransactionRequestDirect memory l2TxnReqDirect = _prepareETHL2TransactionDirectRequest({
            mockChainId: mockChainId,
            mockMintValue: mockMintValue,
            mockL2Contract: mockL2Contract,
            mockL2Value: mockL2Value,
            mockL2Calldata: mockL2Calldata,
            mockL2GasLimit: mockL2GasLimit,
            mockL2GasPerPubdataByteLimit: mockL2GasPerPubdataByteLimit,
            mockFactoryDeps: mockFactoryDeps,
            randomCaller: randomCaller
        });

        vm.deal(randomCaller, l2TxnReqDirect.mintValue);
        gasPrice = bound(gasPrice, 1_000, 50_000_000);
        vm.txGasPrice(gasPrice * 1 gwei);
        vm.prank(randomCaller);
        bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));
        bytes32 resultantHash = bridgeHub.requestL2TransactionDirect{value: randomCaller.balance}(l2TxnReqDirect);

        assertTrue(resultantHash == canonicalHash);
    }

    function test_requestL2TransactionDirect_NonETHCase(
        uint256 mockChainId,
        uint256 mockMintValue,
        address mockL2Contract,
        uint256 mockL2Value,
        bytes memory mockL2Calldata,
        uint256 mockL2GasLimit,
        uint256 mockL2GasPerPubdataByteLimit,
        bytes[] memory mockFactoryDeps,
        uint256 gasPrice,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        address randomCaller = makeAddr("RANDOM_CALLER");
        mockChainId = bound(mockChainId, 1, type(uint48).max);

        if (mockFactoryDeps.length > MAX_NEW_FACTORY_DEPS) {
            mockFactoryDeps = _restrictArraySize(mockFactoryDeps, MAX_NEW_FACTORY_DEPS);
        }

        L2TransactionRequestDirect memory l2TxnReqDirect = _createMockL2TransactionRequestDirect({
            mockChainId: mockChainId,
            mockMintValue: mockMintValue,
            mockL2Contract: mockL2Contract,
            mockL2Value: mockL2Value,
            mockL2Calldata: mockL2Calldata,
            mockL2GasLimit: mockL2GasLimit,
            mockL2GasPerPubdataByteLimit: mockL2GasPerPubdataByteLimit,
            mockFactoryDeps: mockFactoryDeps,
            mockRefundRecipient: address(0)
        });

        l2TxnReqDirect.chainId = _setUpHyperchainForChainId(l2TxnReqDirect.chainId);

        _setUpBaseTokenForChainId(l2TxnReqDirect.chainId, false, address(testToken));
        _setUpSharedBridge();
        _setUpSharedBridgeL2(mockChainId);

        assertTrue(bridgeHub.getHyperchain(l2TxnReqDirect.chainId) == address(mockChainContract));
        bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));

        vm.mockCall(
            address(mockChainContract),
            abi.encodeWithSelector(mockChainContract.bridgehubRequestL2Transaction.selector),
            abi.encode(canonicalHash)
        );

        mockChainContract.setFeeParams();
        mockChainContract.setBaseTokenGasMultiplierPrice(uint128(1), uint128(1));
        mockChainContract.setBridgeHubAddress(address(bridgeHub));
        assertTrue(mockChainContract.getBridgeHubAddress() == address(bridgeHub));

        gasPrice = bound(gasPrice, 1_000, 50_000_000);
        vm.txGasPrice(gasPrice * 1 gwei);

        vm.deal(randomCaller, 1 ether);
        vm.prank(randomCaller);
        vm.expectRevert("Bridgehub: non-eth bridge with msg.value");
        bytes32 resultantHash = bridgeHub.requestL2TransactionDirect{value: randomCaller.balance}(l2TxnReqDirect);

        // Now, let's call the same function with zero msg.value
        testToken.mint(randomCaller, l2TxnReqDirect.mintValue);
        assertEq(testToken.balanceOf(randomCaller), l2TxnReqDirect.mintValue);

        vm.prank(randomCaller);
        testToken.transfer(address(this), l2TxnReqDirect.mintValue);
        assertEq(testToken.balanceOf(address(this)), l2TxnReqDirect.mintValue);
        testToken.approve(sharedBridgeAddress, l2TxnReqDirect.mintValue);

        resultantHash = bridgeHub.requestL2TransactionDirect(l2TxnReqDirect);

        assertEq(canonicalHash, resultantHash);
    }

    function test_requestTransactionTwoBridgesChecksMagicValue(
        uint256 chainId,
        uint256 mintValue,
        uint256 l2Value,
        uint256 l2GasLimit,
        uint256 l2GasPerPubdataByteLimit,
        address refundRecipient,
        uint256 secondBridgeValue,
        bytes memory secondBridgeCalldata,
        bytes32 magicValue
    ) public {
        chainId = bound(chainId, 1, type(uint48).max);

        L2TransactionRequestTwoBridgesOuter memory l2TxnReq2BridgeOut = _createMockL2TransactionRequestTwoBridgesOuter({
            chainId: chainId,
            mintValue: mintValue,
            l2Value: l2Value,
            l2GasLimit: l2GasLimit,
            l2GasPerPubdataByteLimit: l2GasPerPubdataByteLimit,
            refundRecipient: refundRecipient,
            secondBridgeValue: secondBridgeValue,
            secondBridgeCalldata: secondBridgeCalldata
        });

        l2TxnReq2BridgeOut.chainId = _setUpHyperchainForChainId(l2TxnReq2BridgeOut.chainId);

        _setUpBaseTokenForChainId(l2TxnReq2BridgeOut.chainId, true, address(0));
        assertTrue(bridgeHub.baseToken(l2TxnReq2BridgeOut.chainId) == ETH_TOKEN_ADDRESS);

        _setUpSharedBridge();
        _setUpSharedBridgeL2(chainId);

        assertTrue(bridgeHub.getHyperchain(l2TxnReq2BridgeOut.chainId) == address(mockChainContract));

        uint256 callerMsgValue = l2TxnReq2BridgeOut.mintValue + l2TxnReq2BridgeOut.secondBridgeValue;
        address randomCaller = makeAddr("RANDOM_CALLER");
        vm.deal(randomCaller, callerMsgValue);

        if (magicValue != TWO_BRIDGES_MAGIC_VALUE) {
            L2TransactionRequestTwoBridgesInner memory request = L2TransactionRequestTwoBridgesInner({
                magicValue: magicValue,
                l2Contract: makeAddr("L2_CONTRACT"),
                l2Calldata: new bytes(0),
                factoryDeps: new bytes[](0),
                txDataHash: bytes32(0)
            });

            vm.mockCall(
                secondBridgeAddress,
                abi.encodeWithSelector(IL1SharedBridge.bridgehubDeposit.selector),
                abi.encode(request)
            );

            vm.expectRevert("Bridgehub: magic value mismatch");
            vm.prank(randomCaller);
            bridgeHub.requestL2TransactionTwoBridges{value: randomCaller.balance}(l2TxnReq2BridgeOut);
        }
    }

    function test_requestL2TransactionTwoBridgesWrongBridgeAddress(
        uint256 chainId,
        uint256 mintValue,
        uint256 msgValue,
        uint256 l2Value,
        uint256 l2GasLimit,
        uint256 l2GasPerPubdataByteLimit,
        address refundRecipient,
        uint256 secondBridgeValue,
        uint160 secondBridgeAddressValue,
        bytes memory secondBridgeCalldata
    ) public {
        chainId = bound(chainId, 1, type(uint48).max);

        L2TransactionRequestTwoBridgesOuter memory l2TxnReq2BridgeOut = _createMockL2TransactionRequestTwoBridgesOuter({
            chainId: chainId,
            mintValue: mintValue,
            l2Value: l2Value,
            l2GasLimit: l2GasLimit,
            l2GasPerPubdataByteLimit: l2GasPerPubdataByteLimit,
            refundRecipient: refundRecipient,
            secondBridgeValue: secondBridgeValue,
            secondBridgeCalldata: secondBridgeCalldata
        });

        l2TxnReq2BridgeOut.chainId = _setUpHyperchainForChainId(l2TxnReq2BridgeOut.chainId);

        _setUpBaseTokenForChainId(l2TxnReq2BridgeOut.chainId, true, address(0));
        assertTrue(bridgeHub.baseToken(l2TxnReq2BridgeOut.chainId) == ETH_TOKEN_ADDRESS);

        _setUpSharedBridge();
        _setUpSharedBridgeL2(chainId);

        assertTrue(bridgeHub.getHyperchain(l2TxnReq2BridgeOut.chainId) == address(mockChainContract));

        uint256 callerMsgValue = l2TxnReq2BridgeOut.mintValue + l2TxnReq2BridgeOut.secondBridgeValue;
        address randomCaller = makeAddr("RANDOM_CALLER");
        vm.deal(randomCaller, callerMsgValue);

        mockChainContract.setBridgeHubAddress(address(bridgeHub));

        bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));

        vm.mockCall(
            address(mockChainContract),
            abi.encodeWithSelector(mockChainContract.bridgehubRequestL2Transaction.selector),
            abi.encode(canonicalHash)
        );

        L2TransactionRequestTwoBridgesInner memory outputRequest = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: address(0),
            l2Calldata: abi.encode(""),
            factoryDeps: new bytes[](0),
            txDataHash: bytes32("")
        });
        secondBridgeAddressValue = uint160(bound(uint256(secondBridgeAddressValue), 0, uint256(type(uint16).max)));
        address secondBridgeAddress = address(secondBridgeAddressValue);

        vm.mockCall(
            address(secondBridgeAddressValue),
            l2TxnReq2BridgeOut.secondBridgeValue,
            abi.encodeWithSelector(
                IL1SharedBridge.bridgehubDeposit.selector,
                l2TxnReq2BridgeOut.chainId,
                randomCaller,
                l2TxnReq2BridgeOut.l2Value,
                l2TxnReq2BridgeOut.secondBridgeCalldata
            ),
            abi.encode(outputRequest)
        );

        l2TxnReq2BridgeOut.secondBridgeAddress = address(secondBridgeAddressValue);
        vm.expectRevert("Bridgehub: second bridge address too low");
        vm.prank(randomCaller);
        bridgeHub.requestL2TransactionTwoBridges{value: randomCaller.balance}(l2TxnReq2BridgeOut);
    }

    function test_requestL2TransactionTwoBridges_ERC20ToNonBase(
        uint256 chainId,
        uint256 mintValue,
        uint256 l2Value,
        uint256 l2GasLimit,
        uint256 l2GasPerPubdataByteLimit,
        address l2Receiver,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        // create another token, to avoid base token
        TestnetERC20Token erc20Token = new TestnetERC20Token("ZKESTT", "ZkSync ERC Test Token", 18);
        address erc20TokenAddress = address(erc20Token);
        l2Value = bound(l2Value, 1, type(uint256).max);
        bytes memory secondBridgeCalldata = abi.encode(erc20TokenAddress, l2Value, l2Receiver);

        chainId = _setUpHyperchainForChainId(chainId);

        L2TransactionRequestTwoBridgesOuter memory l2TxnReq2BridgeOut = _createMockL2TransactionRequestTwoBridgesOuter({
            chainId: chainId,
            mintValue: mintValue,
            l2Value: 0, // not used
            l2GasLimit: l2GasLimit,
            l2GasPerPubdataByteLimit: l2GasPerPubdataByteLimit,
            refundRecipient: address(0),
            secondBridgeValue: 0, // not used cause we are using ERC20
            secondBridgeCalldata: secondBridgeCalldata
        });

        address randomCaller = makeAddr("RANDOM_CALLER");
        bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));

        _setUpBaseTokenForChainId(l2TxnReq2BridgeOut.chainId, false, address(testToken));
        assertTrue(bridgeHub.baseToken(l2TxnReq2BridgeOut.chainId) == address(testToken));
        _setUpSharedBridge();

        _setUpSharedBridgeL2(chainId);
        assertTrue(bridgeHub.getHyperchain(l2TxnReq2BridgeOut.chainId) == address(mockChainContract));
        mockChainContract.setBridgeHubAddress(address(bridgeHub));

        vm.mockCall(
            address(mockChainContract),
            abi.encodeWithSelector(mockChainContract.bridgehubRequestL2Transaction.selector),
            abi.encode(canonicalHash)
        );

        testToken.mint(randomCaller, l2TxnReq2BridgeOut.mintValue);
        erc20Token.mint(randomCaller, l2Value);

        assertEq(testToken.balanceOf(randomCaller), l2TxnReq2BridgeOut.mintValue);
        assertEq(erc20Token.balanceOf(randomCaller), l2Value);

        vm.startPrank(randomCaller);
        testToken.approve(sharedBridgeAddress, l2TxnReq2BridgeOut.mintValue);
        erc20Token.approve(secondBridgeAddress, l2Value);
        vm.stopPrank();
        vm.prank(randomCaller);
        bytes32 resultHash = bridgeHub.requestL2TransactionTwoBridges(l2TxnReq2BridgeOut);
        assertEq(resultHash, canonicalHash);

        assert(erc20Token.balanceOf(randomCaller) == 0);
        assert(testToken.balanceOf(randomCaller) == 0);
        assert(erc20Token.balanceOf(secondBridgeAddress) == l2Value);
        assert(testToken.balanceOf(sharedBridgeAddress) == l2TxnReq2BridgeOut.mintValue);

        l2TxnReq2BridgeOut.secondBridgeValue = 1;
        testToken.mint(randomCaller, l2TxnReq2BridgeOut.mintValue);
        vm.startPrank(randomCaller);
        testToken.approve(sharedBridgeAddress, l2TxnReq2BridgeOut.mintValue);
        vm.expectRevert("Bridgehub: msg.value mismatch 3");
        bridgeHub.requestL2TransactionTwoBridges(l2TxnReq2BridgeOut);
        vm.stopPrank();
    }

    function test_requestL2TransactionTwoBridges_ETHToNonBase(
        uint256 chainId,
        uint256 mintValue,
        uint256 msgValue,
        uint256 l2Value,
        uint256 l2GasLimit,
        uint256 l2GasPerPubdataByteLimit,
        address refundRecipient,
        uint256 secondBridgeValue,
        address l2Receiver,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        secondBridgeValue = bound(secondBridgeValue, 1, type(uint256).max);
        bytes memory secondBridgeCalldata = abi.encode(ETH_TOKEN_ADDRESS, 0, l2Receiver);

        chainId = _setUpHyperchainForChainId(chainId);

        L2TransactionRequestTwoBridgesOuter memory l2TxnReq2BridgeOut = _createMockL2TransactionRequestTwoBridgesOuter({
            chainId: chainId,
            mintValue: mintValue,
            l2Value: l2Value,
            l2GasLimit: l2GasLimit,
            l2GasPerPubdataByteLimit: l2GasPerPubdataByteLimit,
            refundRecipient: refundRecipient,
            secondBridgeValue: secondBridgeValue,
            secondBridgeCalldata: secondBridgeCalldata
        });

        _setUpBaseTokenForChainId(l2TxnReq2BridgeOut.chainId, false, address(testToken));
        assertTrue(bridgeHub.baseToken(l2TxnReq2BridgeOut.chainId) == address(testToken));

        _setUpSharedBridge();
        _setUpSharedBridgeL2(chainId);
        assertTrue(bridgeHub.getHyperchain(l2TxnReq2BridgeOut.chainId) == address(mockChainContract));

        address randomCaller = makeAddr("RANDOM_CALLER");

        mockChainContract.setBridgeHubAddress(address(bridgeHub));

        bytes32 canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));

        vm.mockCall(
            address(mockChainContract),
            abi.encodeWithSelector(mockChainContract.bridgehubRequestL2Transaction.selector),
            abi.encode(canonicalHash)
        );

        if (msgValue != secondBridgeValue) {
            vm.deal(randomCaller, msgValue);
            vm.expectRevert("Bridgehub: msg.value mismatch 3");
            vm.prank(randomCaller);
            bridgeHub.requestL2TransactionTwoBridges{value: msgValue}(l2TxnReq2BridgeOut);
        }

        testToken.mint(randomCaller, l2TxnReq2BridgeOut.mintValue);
        assertEq(testToken.balanceOf(randomCaller), l2TxnReq2BridgeOut.mintValue);
        vm.prank(randomCaller);
        testToken.approve(sharedBridgeAddress, l2TxnReq2BridgeOut.mintValue);

        vm.deal(randomCaller, l2TxnReq2BridgeOut.secondBridgeValue);
        vm.prank(randomCaller);
        bridgeHub.requestL2TransactionTwoBridges{value: randomCaller.balance}(l2TxnReq2BridgeOut);
    }

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
            genesisBatchCommitment: bytes32(uint256(0x01))
        });

        mockSTM.setChainCreationParams(params);

        return abi.encode(diamondCutData);
    }

    function _setUpHyperchainForChainId(uint256 mockChainId) internal returns (uint256 mockChainIdInRange) {
        mockChainId = bound(mockChainId, 1, type(uint48).max);
        mockChainIdInRange = mockChainId;
        vm.prank(bridgeOwner);
        bridgeHub.addStateTransitionManager(address(mockSTM));

        // We need to set the stateTransitionManager of the mockChainId to mockSTM
        // There is no function to do that in the bridgeHub
        // So, perhaps we will have to manually set the values in the stateTransitionManager mapping via a foundry cheatcode
        assertTrue(!(bridgeHub.stateTransitionManager(mockChainId) == address(mockSTM)));

        stdstore.target(address(bridgeHub)).sig("stateTransitionManager(uint256)").with_key(mockChainId).checked_write(
            address(mockSTM)
        );

        // Now in the StateTransitionManager that has been set for our mockChainId, we set the hyperchain contract as our mockChainContract
        mockSTM.setHyperchain(mockChainId, address(mockChainContract));
    }

    function _setUpBaseTokenForChainId(uint256 mockChainId, bool tokenIsETH, address token) internal {
        address baseToken = tokenIsETH ? ETH_TOKEN_ADDRESS : token;

        stdstore.target(address(bridgeHub)).sig("baseToken(uint256)").with_key(mockChainId).checked_write(baseToken);
    }

    function _setUpSharedBridge() internal {
        vm.prank(bridgeOwner);
        bridgeHub.setSharedBridge(sharedBridgeAddress);
    }

    function _setUpSharedBridgeL2(uint256 _chainId) internal {
        _chainId = bound(_chainId, 1, type(uint48).max);

        vm.prank(bridgeOwner);
        sharedBridge.initializeChainGovernance(_chainId, mockL2Contract);

        assertEq(sharedBridge.l2BridgeAddress(_chainId), mockL2Contract);

        vm.prank(bridgeOwner);
        secondBridge.initializeChainGovernance(_chainId, mockL2Contract);

        assertEq(secondBridge.l2BridgeAddress(_chainId), mockL2Contract);
    }

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
        bridgeHub.addStateTransitionManager(address(mockSTM));
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
        bridgeHub.addStateTransitionManager(address(mockSTM));
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
        bridgeHub.addStateTransitionManager(address(mockSTM));
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
