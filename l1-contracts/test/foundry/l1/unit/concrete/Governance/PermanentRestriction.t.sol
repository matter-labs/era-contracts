pragma solidity 0.8.28;

import "@openzeppelin/contracts-v4/utils/Strings.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {BridgehubBurnCTMAssetData, IBridgehubBase, L2TransactionRequestTwoBridgesOuter} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";

import {PermanentRestriction} from "contracts/governance/PermanentRestriction.sol";
import {IPermanentRestriction} from "contracts/governance/IPermanentRestriction.sol";
import {AlreadyWhitelisted, CallNotAllowed, InvalidSelector, NotAllowed, RemovingPermanentRestriction, TooHighDeploymentNonce, UnallowedImplementation, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {Call} from "contracts/governance/Common.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";

import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {IMessageRoot} from "contracts/core/message-root/IMessageRoot.sol";

import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";

import {ChainTypeManagerTest} from "test/foundry/l1/unit/concrete/state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";

import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";

import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";

import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";

contract TestPermanentRestriction is PermanentRestriction {
    constructor(IL1Bridgehub _bridgehub, address _l2AdminFactory) PermanentRestriction(_bridgehub, _l2AdminFactory) {}

    function isAdminOfAChain(address _chain) external view returns (bool) {
        return _isAdminOfAChain(_chain);
    }

    function getNewAdminFromMigration(Call calldata _call) external view returns (address, bool) {
        return _getNewAdminFromMigration(_call);
    }
}

contract PermanentRestrictionTest is ChainTypeManagerTest {
    uint256 internal L1_CHAIN_ID;
    ChainAdmin internal chainAdmin;
    AccessControlRestriction internal restriction;
    TestPermanentRestriction internal permRestriction;

    address constant L2_FACTORY_ADDR = address(0);

    address internal owner;
    address internal hyperchain;

    function setUp() public {
        deploy();

        createNewChainBridgehub();

        owner = makeAddr("owner");
        hyperchain = chainContractAddress.getHyperchain(chainId);
        (permRestriction, ) = _deployPermRestriction(bridgehub, L2_FACTORY_ADDR, owner);
        restriction = new AccessControlRestriction(0, owner);
        address[] memory restrictions = new address[](1);
        restrictions[0] = address(restriction);
        chainAdmin = new ChainAdmin(restrictions);
        L1_CHAIN_ID = 5;
    }

    function _deployPermRestriction(
        IL1Bridgehub _bridgehub,
        address _l2AdminFactory,
        address _owner
    ) internal returns (TestPermanentRestriction proxy, TestPermanentRestriction impl) {
        impl = new TestPermanentRestriction(_bridgehub, _l2AdminFactory);
        TransparentUpgradeableProxy tup = new TransparentUpgradeableProxy(
            address(impl),
            address(uint160(1)),
            abi.encodeCall(PermanentRestriction.initialize, (_owner))
        );

        proxy = TestPermanentRestriction(address(tup));
    }

    function test_ownerAsAddressZero() public {
        TestPermanentRestriction impl = new TestPermanentRestriction(bridgehub, L2_FACTORY_ADDR);
        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            address(uint160(1)),
            abi.encodeCall(PermanentRestriction.initialize, (address(0)))
        );
    }

    function test_setAllowedAdminImplementation(bytes32 implementationHash) public {
        vm.expectEmit(true, false, false, true);
        emit IPermanentRestriction.AdminImplementationAllowed(implementationHash, true);

        vm.prank(owner);
        permRestriction.setAllowedAdminImplementation(implementationHash, true);
    }

    function test_setAllowedData(bytes memory data) public {
        vm.expectEmit(false, false, false, true);
        emit IPermanentRestriction.AllowedDataChanged(data, true);

        vm.prank(owner);
        permRestriction.setAllowedData(data, true);
    }

    function test_setSelectorShouldBeValidated(bytes4 selector) public {
        vm.expectEmit(true, false, false, true);
        emit IPermanentRestriction.SelectorValidationChanged(selector, true);

        vm.prank(owner);
        permRestriction.setSelectorShouldBeValidated(selector, true);
    }

    function isAddressAdmin(address chainAddr, address _potentialAdmin) internal returns (bool) {
        // The permanent restriction compares it only against the msg.sender,
        // so we have to use `prank` to test the function
        vm.prank(_potentialAdmin);
        return permRestriction.isAdminOfAChain(chainAddr);
    }

    function test_isAdminOfAChainIsAddressZero() public {
        assertFalse(permRestriction.isAdminOfAChain(address(0)));
    }

    function test_isAdminOfAChainNotAHyperchain() public {
        assertFalse(permRestriction.isAdminOfAChain(makeAddr("random")));
    }

    function test_isAdminOfAChainOfAChainNotAnAdmin() public {
        assertFalse(permRestriction.isAdminOfAChain(hyperchain));
    }

    function test_tryCompareAdminOfAChain() public {
        assertTrue(isAddressAdmin(hyperchain, newChainAdmin));
    }

    function test_validateCallTooShortData() public {
        Call memory call = Call({target: hyperchain, value: 0, data: ""});

        vm.startPrank(newChainAdmin);
        permRestriction.validateCall(call, owner);
        vm.stopPrank();
    }

    function test_validateCallSetPendingAdminUnallowedImplementation() public {
        Call memory call = Call({
            target: hyperchain,
            value: 0,
            data: abi.encodeWithSelector(IAdmin.setPendingAdmin.selector, owner)
        });

        vm.expectRevert(abi.encodeWithSelector(UnallowedImplementation.selector, owner.codehash));

        vm.startPrank(newChainAdmin);
        permRestriction.validateCall(call, owner);
        vm.stopPrank();
    }

    function test_validateCallSetPendingAdminRemovingPermanentRestriction() public {
        vm.prank(owner);
        permRestriction.setAllowedAdminImplementation(address(chainAdmin).codehash, true);

        Call memory call = Call({
            target: hyperchain,
            value: 0,
            data: abi.encodeWithSelector(IAdmin.setPendingAdmin.selector, address(chainAdmin))
        });

        vm.expectRevert(RemovingPermanentRestriction.selector);

        vm.startPrank(newChainAdmin);
        permRestriction.validateCall(call, owner);
        vm.stopPrank();
    }

    function test_validateCallSetPendingAdmin() public {
        vm.prank(owner);
        permRestriction.setAllowedAdminImplementation(address(chainAdmin).codehash, true);

        vm.prank(address(chainAdmin));
        chainAdmin.addRestriction(address(permRestriction));

        Call memory call = Call({
            target: hyperchain,
            value: 0,
            data: abi.encodeWithSelector(IAdmin.setPendingAdmin.selector, address(chainAdmin))
        });

        vm.startPrank(newChainAdmin);
        permRestriction.validateCall(call, owner);
        vm.stopPrank();
    }

    function test_validateCallNotValidatedSelector() public {
        Call memory call = Call({
            target: hyperchain,
            value: 0,
            data: abi.encodeWithSelector(IAdmin.acceptAdmin.selector)
        });

        vm.startPrank(newChainAdmin);
        permRestriction.validateCall(call, owner);
        vm.stopPrank();
    }

    function test_validateCallCallNotAllowed() public {
        vm.prank(owner);
        permRestriction.setSelectorShouldBeValidated(IAdmin.acceptAdmin.selector, true);
        Call memory call = Call({
            target: hyperchain,
            value: 0,
            data: abi.encodeWithSelector(IAdmin.acceptAdmin.selector)
        });

        vm.expectRevert(abi.encodeWithSelector(CallNotAllowed.selector, call.data));

        vm.startPrank(newChainAdmin);
        permRestriction.validateCall(call, owner);
        vm.stopPrank();
    }

    function test_validateCall() public {
        vm.prank(owner);
        permRestriction.setSelectorShouldBeValidated(IAdmin.acceptAdmin.selector, true);
        Call memory call = Call({
            target: hyperchain,
            value: 0,
            data: abi.encodeWithSelector(IAdmin.acceptAdmin.selector)
        });

        vm.prank(owner);
        permRestriction.setAllowedData(call.data, true);

        vm.startPrank(newChainAdmin);
        permRestriction.validateCall(call, owner);
        vm.stopPrank();
    }

    function _encodeMigraationCall(
        bool correctTarget,
        bool correctSelector,
        bool correctSecondBridge,
        bool correctEncodingVersion,
        bool correctAssetId,
        address l2Admin
    ) internal returns (Call memory call) {
        if (!correctTarget) {
            call.target = address(0);
            return call;
        }
        call.target = address(bridgehub);

        if (!correctSelector) {
            call.data = hex"00000000";
            return call;
        }

        L2TransactionRequestTwoBridgesOuter memory outer = L2TransactionRequestTwoBridgesOuter({
            chainId: chainId,
            mintValue: 0,
            l2Value: 0,
            l2GasLimit: 0,
            l2GasPerPubdataByteLimit: 0,
            refundRecipient: address(0),
            secondBridgeAddress: address(0),
            secondBridgeValue: 0,
            secondBridgeCalldata: hex""
        });
        if (!correctSecondBridge) {
            call.data = abi.encodeCall(IL1Bridgehub.requestL2TransactionTwoBridges, (outer));
            // 0 is not correct second bridge
            return call;
        }
        outer.secondBridgeAddress = sharedBridge;

        uint8 encoding = correctEncodingVersion ? 1 : 12;

        bytes32 chainAssetId = correctAssetId ? bridgehub.ctmAssetIdFromChainId(chainId) : bytes32(0);

        bytes memory bridgehubData = abi.encode(
            BridgehubBurnCTMAssetData({
                // Gateway chain id, we do not need it
                chainId: 0,
                ctmData: abi.encode(l2Admin, hex""),
                chainData: abi.encode(IZKChain(IBridgehubBase(bridgehub).getZKChain(chainId)).getProtocolVersion())
            })
        );
        outer.secondBridgeCalldata = abi.encodePacked(bytes1(encoding), abi.encode(chainAssetId, bridgehubData));

        call.data = abi.encodeCall(IL1Bridgehub.requestL2TransactionTwoBridges, (outer));
    }

    function assertInvalidMigrationCall(Call memory call) public {
        (address newAdmin, bool migration) = permRestriction.getNewAdminFromMigration(call);
        assertFalse(migration);
        assertEq(newAdmin, address(0));
    }

    function test_tryGetNewAdminFromMigrationRevertWhenInvalidSelector() public {
        Call memory call = _encodeMigraationCall(false, true, true, true, true, address(0));

        assertInvalidMigrationCall(call);
    }

    function test_tryGetNewAdminFromMigrationRevertWhenNotBridgehub() public {
        Call memory call = _encodeMigraationCall(true, false, true, true, true, address(0));

        assertInvalidMigrationCall(call);
    }

    function test_tryGetNewAdminFromMigrationRevertWhenNotSharedBridge() public {
        Call memory call = _encodeMigraationCall(true, true, false, true, true, address(0));

        assertInvalidMigrationCall(call);
    }

    function test_tryGetNewAdminFromMigrationRevertWhenIncorrectEncoding() public {
        Call memory call = _encodeMigraationCall(true, true, true, false, true, address(0));

        assertInvalidMigrationCall(call);
    }

    function test_tryGetNewAdminFromMigrationRevertWhenIncorrectAssetId() public {
        Call memory call = _encodeMigraationCall(true, true, true, true, false, address(0));

        assertInvalidMigrationCall(call);
    }

    function test_tryGetNewAdminFromMigrationShouldWorkCorrectly() public {
        address l2Addr = makeAddr("l2Addr");
        Call memory call = _encodeMigraationCall(true, true, true, true, true, l2Addr);

        (address newAdmin, bool migration) = permRestriction.getNewAdminFromMigration(call);
        assertTrue(migration);
        assertEq(newAdmin, l2Addr);
    }

    function test_validateMigrationToL2RevertNotAllowed() public {
        Call memory call = _encodeMigraationCall(true, true, true, true, true, address(0));

        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, address(0)));
        permRestriction.validateCall(call, owner);
    }

    function test_validateMigrationToL2() public {
        address expectedAddress = L2ContractHelper.computeCreateAddress(L2_FACTORY_ADDR, uint256(0));

        vm.expectEmit(true, false, false, true);
        emit IPermanentRestriction.AllowL2Admin(expectedAddress);
        permRestriction.allowL2Admin(uint256(0));

        Call memory call = _encodeMigraationCall(true, true, true, true, true, expectedAddress);

        // Should not fail
        permRestriction.validateCall(call, owner);
    }

    function createNewChainBridgehub() internal {
        bytes[] memory factoryDeps = new bytes[](0);
        vm.stopPrank();
        vm.startPrank(governor);
        bridgehub.addChainTypeManager(address(chainContractAddress));
        bridgehub.addTokenAssetId(DataEncoding.encodeNTVAssetId(block.chainid, baseToken));
        L1MessageRoot messageRootNew = new L1MessageRoot(address(bridgehub), 1);
        bridgehub.setAddresses(
            sharedBridge,
            ICTMDeploymentTracker(address(0)),
            messageRootNew,
            address(chainAssetHandler),
            address(0)
        ); // kl todo maybe address(1)
        vm.stopPrank();

        // ctm deployer address is 0 in this test
        vm.startPrank(address(0));
        bridgehub.setCTMAssetAddress(
            bytes32(uint256(uint160(address(chainContractAddress)))),
            address(chainContractAddress)
        );
        vm.stopPrank();

        address l1Nullifier = makeAddr("l1Nullifier");
        vm.mockCall(
            address(sharedBridge),
            abi.encodeWithSelector(IL1AssetRouter.L1_NULLIFIER.selector),
            abi.encode(l1Nullifier)
        );
        vm.mockCall(
            address(sharedBridge),
            abi.encodeWithSelector(IAssetRouterBase.assetHandlerAddress.selector),
            abi.encode(bridgehub)
        );
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.baseToken.selector, chainId),
            abi.encode(baseToken)
        );
        vm.mockCall(
            address(messageRootNew),
            abi.encodeWithSelector(IL1MessageRoot.v31UpgradeChainBatchNumber.selector),
            abi.encode(0)
        );
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(chainAssetHandler)
        );
        vm.mockCall(address(baseToken), abi.encodeWithSelector(IERC20Metadata.name.selector), abi.encode("TestToken"));
        vm.mockCall(address(baseToken), abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode("TT"));
        vm.mockCall(address(baseToken), abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(18));

        bytes32 baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, baseToken);
        mockDiamondInitInteropCenterCallsWithAddress(address(bridgehub), sharedBridge, baseTokenAssetId);
        vm.startPrank(governor);
        bridgehub.createNewChain({
            _chainId: chainId,
            _chainTypeManager: address(chainContractAddress),
            _baseTokenAssetId: baseTokenAssetId,
            _salt: 0,
            _admin: newChainAdmin,
            _initData: getCTMInitData(),
            _factoryDeps: factoryDeps
        });
        vm.stopPrank();
    }

    // Additional tests for coverage

    function test_allowL2Admin_TooHighDeploymentNonce() public {
        // MAX_ALLOWED_NONCE is (1 << 48)
        uint256 tooHighNonce = (1 << 48) + 1;

        vm.expectRevert(TooHighDeploymentNonce.selector);
        permRestriction.allowL2Admin(tooHighNonce);
    }

    function test_allowL2Admin_AlreadyWhitelisted() public {
        // First, whitelist an admin
        permRestriction.allowL2Admin(0);

        address expectedAddress = L2ContractHelper.computeCreateAddress(L2_FACTORY_ADDR, 0);

        // Try to whitelist the same admin again
        vm.expectRevert(abi.encodeWithSelector(AlreadyWhitelisted.selector, expectedAddress));
        permRestriction.allowL2Admin(0);
    }

    function test_validateRemoveRestriction_ShortData() public {
        // Call with data length < 4 on msg.sender (chainAdmin)
        Call memory call = Call({
            target: address(chainAdmin),
            value: 0,
            data: hex"aabb" // Only 2 bytes, less than 4
        });

        // Should not revert - short data is allowed
        vm.startPrank(address(chainAdmin));
        permRestriction.validateCall(call, owner);
        vm.stopPrank();
    }

    function test_validateRemoveRestriction_DifferentSelector() public {
        // Call with a selector that is not removeRestriction
        Call memory call = Call({
            target: address(chainAdmin),
            value: 0,
            data: abi.encodeWithSelector(IAdmin.acceptAdmin.selector)
        });

        // Should not revert - different selector
        vm.startPrank(address(chainAdmin));
        permRestriction.validateCall(call, owner);
        vm.stopPrank();
    }

    function test_validateRemoveRestriction_RemoveDifferentRestriction() public {
        // Call removeRestriction with a different address (not this restriction)
        address differentRestriction = makeAddr("differentRestriction");
        Call memory call = Call({
            target: address(chainAdmin),
            value: 0,
            data: abi.encodeWithSelector(IChainAdmin.removeRestriction.selector, differentRestriction)
        });

        // Should not revert - removing a different restriction is allowed
        vm.startPrank(address(chainAdmin));
        permRestriction.validateCall(call, owner);
        vm.stopPrank();
    }

    function test_validateRemoveRestriction_RemoveThisRestriction() public {
        // Call removeRestriction with this restriction's address
        Call memory call = Call({
            target: address(chainAdmin),
            value: 0,
            data: abi.encodeWithSelector(IChainAdmin.removeRestriction.selector, address(permRestriction))
        });

        vm.expectRevert(RemovingPermanentRestriction.selector);
        vm.startPrank(address(chainAdmin));
        permRestriction.validateCall(call, owner);
        vm.stopPrank();
    }

    function test_tryGetNewAdminFromMigration_ShortData() public {
        // Call with data length < 4 targeting bridgehub
        Call memory call = Call({
            target: address(bridgehub),
            value: 0,
            data: hex"aabb" // Only 2 bytes
        });

        assertInvalidMigrationCall(call);
    }

    function test_tryGetNewAdminFromMigration_EmptySecondBridgeCalldata() public {
        // Create a call with empty secondBridgeCalldata
        L2TransactionRequestTwoBridgesOuter memory outer = L2TransactionRequestTwoBridgesOuter({
            chainId: chainId,
            mintValue: 0,
            l2Value: 0,
            l2GasLimit: 0,
            l2GasPerPubdataByteLimit: 0,
            refundRecipient: address(0),
            secondBridgeAddress: sharedBridge,
            secondBridgeValue: 0,
            secondBridgeCalldata: hex"" // Empty calldata
        });

        Call memory call = Call({
            target: address(bridgehub),
            value: 0,
            data: abi.encodeCall(IL1Bridgehub.requestL2TransactionTwoBridges, (outer))
        });

        assertInvalidMigrationCall(call);
    }

    function test_tryGetNewAdminFromMigration_WrongAssetHandler() public {
        address wrongHandler = makeAddr("wrongHandler");

        // Mock the asset handler to return a different address than bridgehub
        bytes32 chainAssetId = bridgehub.ctmAssetIdFromChainId(chainId);
        vm.mockCall(
            address(sharedBridge),
            abi.encodeWithSelector(IAssetRouterBase.assetHandlerAddress.selector, chainAssetId),
            abi.encode(wrongHandler) // Not bridgehub
        );

        Call memory call = _encodeMigraationCall(true, true, true, true, true, address(0));

        assertInvalidMigrationCall(call);
    }

    function test_isAdminOfAChain_ChainIdMismatch() public {
        // Create an address that returns a valid chainId but bridgehub returns different address
        address fakeChain = makeAddr("fakeChain");
        uint256 fakeChainId = 999999;

        // Mock the chain to return a chainId using IGetters interface
        vm.mockCall(fakeChain, abi.encodeCall(IGetters.getChainId, ()), abi.encode(fakeChainId));

        // Bridgehub returns a different address for this chainId (or address(0))
        // By default, bridgehub.getZKChain will return address(0) for unknown chainIds

        assertFalse(permRestriction.isAdminOfAChain(fakeChain));
    }
}
