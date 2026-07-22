// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ExperimentalBridgeTestBase} from "./_ExperimentalBridge_Shared.t.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {HARD_CODED_CHAIN_ID, MAINNET_CHAIN_ID, SEPOLIA_CHAIN_ID} from "contracts/common/Config.sol";
import {
    AssetIdAlreadyRegistered,
    AssetIdNotSupported,
    BridgeHubAlreadyRegistered,
    CTMAlreadyRegistered,
    CTMNotRegistered,
    ChainIdIsHardcoded,
    ChainIdTooBig,
    SharedBridgeNotSet,
    Unauthorized,
    ZeroAddress,
    ZeroChainId
} from "contracts/common/L1ContractErrors.sol";

contract ExperimentalBridgeTest is ExperimentalBridgeTestBase {
    using stdStorage for StdStorage;

    function test_newPendingAdminReplacesPrevious(address randomDeployer, address otherRandomDeployer) public {
        vm.assume(randomDeployer != address(0));
        vm.assume(otherRandomDeployer != address(0));
        assertEq(address(0), bridgehub.admin());
        vm.assume(randomDeployer != otherRandomDeployer);

        vm.prank(bridgehub.owner());
        bridgehub.setPendingAdmin(randomDeployer);

        vm.prank(bridgehub.owner());
        bridgehub.setPendingAdmin(otherRandomDeployer);

        vm.prank(otherRandomDeployer);
        bridgehub.acceptAdmin();

        assertEq(otherRandomDeployer, bridgehub.admin());
    }

    function test_onlyPendingAdminCanAccept(address randomDeployer, address otherRandomDeployer) public {
        vm.assume(randomDeployer != address(0));
        vm.assume(otherRandomDeployer != address(0));
        assertEq(address(0), bridgehub.admin());
        vm.assume(randomDeployer != otherRandomDeployer);

        vm.prank(bridgehub.owner());
        bridgehub.setPendingAdmin(randomDeployer);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, otherRandomDeployer));
        vm.prank(otherRandomDeployer);
        bridgehub.acceptAdmin();

        assertEq(address(0), bridgehub.admin());
    }

    function test_onlyOwnerCanSetDeployer(address randomDeployer) public {
        vm.assume(randomDeployer != address(0));
        assertEq(address(0), bridgehub.admin());

        vm.prank(bridgehub.owner());
        bridgehub.setPendingAdmin(randomDeployer);
        vm.prank(randomDeployer);
        bridgehub.acceptAdmin();

        assertEq(randomDeployer, bridgehub.admin());
    }

    function test_randomCallerCannotSetDeployer(address randomCaller, address randomDeployer) public {
        if (randomCaller != bridgehub.owner() && randomCaller != bridgehub.admin()) {
            vm.prank(randomCaller);
            vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomCaller));
            bridgehub.setPendingAdmin(randomDeployer);

            // The deployer shouldn't have changed.
            assertEq(address(0), bridgehub.admin());
        }
    }

    function test_addChainTypeManager(address randomAddressWithoutTheCorrectInterface) public {
        vm.assume(randomAddressWithoutTheCorrectInterface != address(0));
        bool isCTMRegistered = bridgehub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isCTMRegistered);

        vm.prank(bridgeOwner);
        bridgehub.addChainTypeManager(randomAddressWithoutTheCorrectInterface);

        isCTMRegistered = bridgehub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isCTMRegistered);

        // An address that has already been registered, cannot be registered again (at least not before calling `removeChainTypeManager`).
        vm.prank(bridgeOwner);
        vm.expectRevert(CTMAlreadyRegistered.selector);
        bridgehub.addChainTypeManager(randomAddressWithoutTheCorrectInterface);

        isCTMRegistered = bridgehub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isCTMRegistered);
    }

    function test_addChainTypeManager_cannotBeCalledByRandomAddress(
        address randomCaller,
        address randomAddressWithoutTheCorrectInterface
    ) public {
        vm.assume(randomAddressWithoutTheCorrectInterface != address(0));
        bool isCTMRegistered = bridgehub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isCTMRegistered);

        if (randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));

            bridgehub.addChainTypeManager(randomAddressWithoutTheCorrectInterface);
        }

        vm.prank(bridgeOwner);
        bridgehub.addChainTypeManager(randomAddressWithoutTheCorrectInterface);

        isCTMRegistered = bridgehub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isCTMRegistered);

        // An address that has already been registered, cannot be registered again (at least not before calling `removeChainTypeManager`).
        vm.prank(bridgeOwner);
        vm.expectRevert(CTMAlreadyRegistered.selector);
        bridgehub.addChainTypeManager(randomAddressWithoutTheCorrectInterface);

        // Definitely not by a random caller
        if (randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert("Ownable: caller is not the owner");
            bridgehub.addChainTypeManager(randomAddressWithoutTheCorrectInterface);
        }

        isCTMRegistered = bridgehub.chainTypeManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isCTMRegistered);
    }

    function test_removeChainTypeManager_cannotBeCalledByRandomAddress(
        address _chainTypeManager,
        address _randomCaller
    ) public {
        vm.assume(_chainTypeManager != address(0));
        vm.assume(_randomCaller != bridgeOwner);

        // Removing a non-registered CTM is still owner-only.
        vm.prank(_randomCaller);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        bridgehub.removeChainTypeManager(_chainTypeManager);

        // Register the CTM so the second check covers the successful-removal path.
        vm.prank(bridgeOwner);
        bridgehub.addChainTypeManager(_chainTypeManager);
        assertTrue(bridgehub.chainTypeManagerIsRegistered(_chainTypeManager));

        vm.prank(_randomCaller);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        bridgehub.removeChainTypeManager(_chainTypeManager);
        assertTrue(bridgehub.chainTypeManagerIsRegistered(_chainTypeManager));

        vm.prank(bridgeOwner);
        bridgehub.removeChainTypeManager(_chainTypeManager);
        assertFalse(bridgehub.chainTypeManagerIsRegistered(_chainTypeManager));
    }

    function test_addAssetId(address randomAddress) public {
        vm.startPrank(bridgeOwner);
        bridgehub.setAddresses(
            address(mockSharedBridge),
            ICTMDeploymentTracker(address(0)),
            IMessageRootBase(address(0)),
            address(0),
            address(0)
        );
        vm.stopPrank();

        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, testTokenAddress);
        assertTrue(!bridgehub.assetIdIsRegistered(assetId), "This random address is not registered as a token");

        vm.prank(bridgeOwner);
        bridgehub.addTokenAssetId(assetId);

        assertTrue(
            bridgehub.assetIdIsRegistered(assetId),
            "after call from the bridgeowner, this randomAddress should be a registered token"
        );

        if (randomAddress != address(testTokenAddress)) {
            assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(randomAddress));
            vm.assume(!bridgehub.assetIdIsRegistered(assetId));
            // Testing to see if a random address can also be added or not
            vm.prank(bridgeOwner);
            bridgehub.addTokenAssetId(assetId);
            assertTrue(bridgehub.assetIdIsRegistered(assetId));
        }

        // An already registered token cannot be registered again
        vm.prank(bridgeOwner);
        vm.expectRevert(AssetIdAlreadyRegistered.selector);
        bridgehub.addTokenAssetId(assetId);
    }

    function test_addAssetId_cannotBeCalledByRandomAddress(
        address randomCaller,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        vm.startPrank(bridgeOwner);
        bridgehub.setAddresses(
            address(mockSharedBridge),
            ICTMDeploymentTracker(address(0)),
            IMessageRootBase(address(0)),
            address(0),
            address(0)
        );
        vm.stopPrank();

        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, testTokenAddress);

        vm.assume(randomCaller != bridgeOwner);
        vm.assume(randomCaller != bridgehub.admin());
        vm.prank(randomCaller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomCaller));
        bridgehub.addTokenAssetId(assetId);

        assertTrue(!bridgehub.assetIdIsRegistered(assetId), "This random address is not registered as a token");

        vm.prank(bridgeOwner);
        bridgehub.addTokenAssetId(assetId);

        assertTrue(
            bridgehub.assetIdIsRegistered(assetId),
            "after call from the bridgeowner, this testTokenAddress should be a registered token"
        );

        // An already registered token cannot be registered again by randomCaller
        if (randomCaller != bridgeOwner) {
            vm.prank(bridgeOwner);
            vm.expectRevert(AssetIdAlreadyRegistered.selector);
            bridgehub.addTokenAssetId(assetId);
        }
    }

    function test_setAddresses(address randomAssetRouter, address randomCTMDeployer, address randomMessageRoot) public {
        assertTrue(address(bridgehub.assetRouter()) == address(0), "Shared bridge is already there");
        assertTrue(bridgehub.l1CtmDeployer() == ICTMDeploymentTracker(address(0)), "L1 CTM deployer is already there");
        assertTrue(bridgehub.messageRoot() == IMessageRootBase(address(0)), "Message root is already there");

        vm.prank(bridgeOwner);
        bridgehub.setAddresses(
            randomAssetRouter,
            ICTMDeploymentTracker(randomCTMDeployer),
            IMessageRootBase(randomMessageRoot),
            address(0),
            address(0)
        );

        assertTrue(address(bridgehub.assetRouter()) == randomAssetRouter, "Shared bridge is already there");
        assertTrue(
            bridgehub.l1CtmDeployer() == ICTMDeploymentTracker(randomCTMDeployer),
            "L1 CTM deployer is already there"
        );
        assertTrue(bridgehub.messageRoot() == IMessageRootBase(randomMessageRoot), "Message root is already there");
    }

    function test_setAddresses_cannotBeCalledByRandomAddress(
        address randomCaller,
        address randomAssetRouter,
        address randomCTMDeployer,
        address randomMessageRoot
    ) public {
        vm.assume(randomCaller != bridgeOwner && randomCaller != L2_COMPLEX_UPGRADER_ADDR);

        vm.prank(randomCaller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomCaller));
        bridgehub.setAddresses(
            randomAssetRouter,
            ICTMDeploymentTracker(randomCTMDeployer),
            IMessageRootBase(randomMessageRoot),
            address(0),
            address(0)
        );

        assertTrue(address(bridgehub.assetRouter()) == address(0), "Shared bridge is already there");
        assertTrue(bridgehub.l1CtmDeployer() == ICTMDeploymentTracker(address(0)), "L1 CTM deployer is already there");
        assertTrue(bridgehub.messageRoot() == IMessageRootBase(address(0)), "Message root is already there");
    }

    uint256 newChainId;
    address admin;

    function test_pause_createNewChain(
        uint256 chainId,
        uint256 salt,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        chainId = bound(chainId, 1, type(uint48).max);
        vm.assume(chainId != block.chainid);

        admin = makeAddr("NEW_CHAIN_ADMIN");

        vm.prank(bridgeOwner);
        bridgehub.pause();
        vm.prank(bridgeOwner);
        bridgehub.setPendingAdmin(deployerAddress);
        vm.prank(deployerAddress);
        bridgehub.acceptAdmin();

        // ntv.registerToken(address(testToken));

        // bytes32 tokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, address(testToken));

        // vm.prank(deployerAddress);
        // bridgehub.addTokenAssetId(tokenAssetId);

        vm.expectRevert("Pausable: paused");
        vm.prank(deployerAddress);
        bridgehub.createNewChain({
            _chainId: chainId,
            _chainTypeManager: address(mockCTM),
            _baseTokenAssetId: tokenAssetId,
            _salt: salt,
            _admin: admin,
            _initData: bytes(""),
            _factoryDeps: new bytes[](0)
        });

        vm.prank(bridgeOwner);
        bridgehub.unpause();

        vm.expectRevert(CTMNotRegistered.selector);
        vm.prank(deployerAddress);
        bridgehub.createNewChain({
            _chainId: chainId,
            _chainTypeManager: address(mockCTM),
            _baseTokenAssetId: tokenAssetId,
            _salt: salt,
            _admin: admin,
            _initData: bytes(""),
            _factoryDeps: new bytes[](0)
        });
    }

    function test_RevertWhen_CTMNotRegisteredOnCreate(
        uint256 chainId,
        uint256 salt,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        chainId = bound(chainId, 1, type(uint48).max);
        vm.assume(chainId != block.chainid);

        admin = makeAddr("NEW_CHAIN_ADMIN");

        vm.prank(bridgeOwner);
        bridgehub.setPendingAdmin(deployerAddress);
        vm.prank(deployerAddress);
        bridgehub.acceptAdmin();

        chainId = bound(chainId, 1, type(uint48).max);
        vm.expectRevert(CTMNotRegistered.selector);
        vm.prank(deployerAddress);
        bridgehub.createNewChain({
            _chainId: chainId,
            _chainTypeManager: address(mockCTM),
            _baseTokenAssetId: tokenAssetId,
            _salt: salt,
            _admin: admin,
            _initData: bytes(""),
            _factoryDeps: new bytes[](0)
        });
    }

    function test_RevertWhen_wrongChainIdOnCreate(
        uint256 chainId,
        uint256 salt,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        chainId = bound(chainId, 1, type(uint48).max);
        vm.assume(chainId != block.chainid);

        admin = makeAddr("NEW_CHAIN_ADMIN");

        vm.prank(bridgeOwner);
        bridgehub.setPendingAdmin(deployerAddress);
        vm.prank(deployerAddress);
        bridgehub.acceptAdmin();

        chainId = bound(chainId, type(uint48).max + uint256(1), type(uint256).max);
        vm.expectRevert(ChainIdTooBig.selector);
        vm.prank(deployerAddress);
        bridgehub.createNewChain({
            _chainId: chainId,
            _chainTypeManager: address(mockCTM),
            _baseTokenAssetId: tokenAssetId,
            _salt: salt,
            _admin: admin,
            _initData: bytes(""),
            _factoryDeps: new bytes[](0)
        });

        chainId = 0;
        vm.expectRevert(ZeroChainId.selector);
        vm.prank(deployerAddress);
        bridgehub.createNewChain({
            _chainId: chainId,
            _chainTypeManager: address(mockCTM),
            _baseTokenAssetId: tokenAssetId,
            _salt: salt,
            _admin: admin,
            _initData: bytes(""),
            _factoryDeps: new bytes[](0)
        });
    }

    function test_RevertWhen_hardcodedChainIdOnMainnet(
        uint256 salt,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        admin = makeAddr("NEW_CHAIN_ADMIN");

        vm.prank(bridgeOwner);
        bridgehub.setPendingAdmin(deployerAddress);
        vm.prank(deployerAddress);
        bridgehub.acceptAdmin();

        vm.chainId(MAINNET_CHAIN_ID);
        vm.expectRevert(ChainIdIsHardcoded.selector);
        vm.prank(deployerAddress);
        bridgehub.createNewChain({
            _chainId: HARD_CODED_CHAIN_ID,
            _chainTypeManager: address(mockCTM),
            _baseTokenAssetId: tokenAssetId,
            _salt: salt,
            _admin: admin,
            _initData: bytes(""),
            _factoryDeps: new bytes[](0)
        });
    }

    function test_RevertWhen_hardcodedChainIdOnSepolia(
        uint256 salt,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        admin = makeAddr("NEW_CHAIN_ADMIN");

        vm.prank(bridgeOwner);
        bridgehub.setPendingAdmin(deployerAddress);
        vm.prank(deployerAddress);
        bridgehub.acceptAdmin();

        vm.chainId(SEPOLIA_CHAIN_ID);
        vm.expectRevert(ChainIdIsHardcoded.selector);
        vm.prank(deployerAddress);
        bridgehub.createNewChain({
            _chainId: HARD_CODED_CHAIN_ID,
            _chainTypeManager: address(mockCTM),
            _baseTokenAssetId: tokenAssetId,
            _salt: salt,
            _admin: admin,
            _initData: bytes(""),
            _factoryDeps: new bytes[](0)
        });
    }

    function test_RevertWhen_assetIdNotRegistered(
        uint256 chainId,
        uint256 salt,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        chainId = bound(chainId, 1, type(uint48).max);
        vm.assume(chainId != block.chainid);

        admin = makeAddr("NEW_CHAIN_ADMIN");

        vm.prank(bridgeOwner);
        bridgehub.setPendingAdmin(deployerAddress);
        vm.prank(deployerAddress);
        bridgehub.acceptAdmin();

        vm.startPrank(bridgeOwner);
        bridgehub.addChainTypeManager(address(mockCTM));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(AssetIdNotSupported.selector, tokenAssetId));
        vm.prank(deployerAddress);
        bridgehub.createNewChain({
            _chainId: chainId,
            _chainTypeManager: address(mockCTM),
            _baseTokenAssetId: tokenAssetId,
            _salt: salt,
            _admin: admin,
            _initData: bytes(""),
            _factoryDeps: new bytes[](0)
        });
    }

    function test_RevertWhen_wethBridgeNotSet(
        uint256 chainId,
        uint256 salt,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        chainId = bound(chainId, 1, type(uint48).max);
        vm.assume(chainId != block.chainid);
        admin = makeAddr("NEW_CHAIN_ADMIN");

        vm.prank(bridgeOwner);
        bridgehub.setPendingAdmin(deployerAddress);
        vm.prank(deployerAddress);
        bridgehub.acceptAdmin();

        vm.startPrank(bridgeOwner);
        bridgehub.addChainTypeManager(address(mockCTM));
        bridgehub.addTokenAssetId(tokenAssetId);
        vm.stopPrank();

        vm.expectRevert(SharedBridgeNotSet.selector);
        vm.prank(deployerAddress);
        bridgehub.createNewChain({
            _chainId: chainId,
            _chainTypeManager: address(mockCTM),
            _baseTokenAssetId: tokenAssetId,
            _salt: salt,
            _admin: admin,
            _initData: bytes(""),
            _factoryDeps: new bytes[](0)
        });
    }

    function test_RevertWhen_chainIdAlreadyRegistered(
        uint256 chainId,
        uint256 salt,
        uint256 randomValue
    ) public useRandomToken(randomValue) {
        admin = makeAddr("NEW_CHAIN_ADMIN");

        _initializeBridgehub();

        chainId = bound(chainId, 1, type(uint48).max);
        vm.assume(chainId != block.chainid);
        stdstore.target(address(bridgehub)).sig("chainTypeManager(uint256)").with_key(chainId).checked_write(
            address(mockCTM)
        );

        vm.expectRevert(BridgeHubAlreadyRegistered.selector);
        vm.prank(deployerAddress);
        bridgehub.createNewChain({
            _chainId: chainId,
            _chainTypeManager: address(mockCTM),
            _baseTokenAssetId: tokenAssetId,
            _salt: salt,
            _admin: admin,
            _initData: bytes(""),
            _factoryDeps: new bytes[](0)
        });
    }

    function test_createNewChain(
        address randomCaller,
        uint256 chainId,
        bytes memory mockInitCalldata,
        bytes[] memory factoryDeps,
        uint256 salt,
        uint256 randomValue,
        address newChainAddress
    ) public useRandomToken(randomValue) {
        admin = makeAddr("NEW_CHAIN_ADMIN");
        chainId = bound(chainId, 1, type(uint48).max);
        vm.assume(chainId != block.chainid);
        vm.assume(randomCaller != deployerAddress && randomCaller != bridgeOwner);
        vm.assume(newChainAddress != address(0));

        _initializeBridgehub();

        vm.prank(randomCaller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomCaller));
        bridgehub.createNewChain({
            _chainId: chainId,
            _chainTypeManager: address(mockCTM),
            _baseTokenAssetId: tokenAssetId,
            _salt: salt,
            _admin: admin,
            _initData: bytes(""),
            _factoryDeps: factoryDeps
        });

        vm.prank(mockCTM.owner());

        // bridgehub.createNewChain => chainTypeManager.createNewChain => this function sets the stateTransition mapping
        // of `chainId`, let's emulate that using foundry cheatcodes or let's just use the extra function we introduced in our mockCTM
        mockCTM.setZKChain(chainId, address(mockChainContract));

        vm.startPrank(deployerAddress);
        vm.mockCall(
            address(mockCTM),
            // solhint-disable-next-line func-named-parameters
            abi.encodeWithSelector(
                mockCTM.createNewChain.selector,
                chainId,
                tokenAssetId,
                admin,
                mockInitCalldata,
                factoryDeps
            ),
            abi.encode(newChainAddress)
        );
        // The Bridgehub seeds the fresh chain's genesis root right after registration by pulling
        // from the chain's getters; `newChainAddress` is a fuzzed address, so mock the VM flag to
        // the EraVM no-op branch.
        vm.mockCall(newChainAddress, abi.encodeWithSelector(IGetters.getZKsyncOS.selector), abi.encode(false));

        vm.expectEmit(true, true, true, true, address(bridgehub));
        emit NewChain(chainId, address(mockCTM), admin);

        bridgehub.createNewChain({
            _chainId: chainId,
            _chainTypeManager: address(mockCTM),
            _baseTokenAssetId: tokenAssetId,
            _salt: uint256(chainId * 2),
            _admin: admin,
            _initData: mockInitCalldata,
            _factoryDeps: factoryDeps
        });

        vm.stopPrank();
        vm.clearMockedCalls();

        assertTrue(bridgehub.chainTypeManager(chainId) == address(mockCTM));
        assertTrue(bridgehub.baseTokenAssetId(chainId) == tokenAssetId);
        assertTrue(bridgehub.getZKChain(chainId) == newChainAddress);
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
            bridgehub.l2TransactionBaseCost(mockChainId, mockGasPrice, mockL2GasLimit, mockL2GasPerPubdataByteLimit) ==
                mockL2TxnCost
        );
        vm.clearMockedCalls();
    }

    function test_setInteropCenter(address randomCaller, address newInteropCenter) public {
        _useMockSharedBridge();
        _initializeBridgehub();
        vm.assume(randomCaller != bridgeOwner && randomCaller != L2_COMPLEX_UPGRADER_ADDR);
        vm.assume(newInteropCenter != address(0));

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomCaller));
        vm.prank(randomCaller);
        bridgehub.setInteropCenter(newInteropCenter);

        vm.expectRevert(ZeroAddress.selector);
        vm.prank(bridgeOwner);
        bridgehub.setInteropCenter(address(0));

        vm.expectEmit(true, false, false, true, address(bridgehub));
        emit IL1Bridgehub.InteropCenterSet(newInteropCenter);
        vm.prank(bridgeOwner);
        bridgehub.setInteropCenter(newInteropCenter);
        assertEq(bridgehub.interopCenter(), newInteropCenter);
    }
}
