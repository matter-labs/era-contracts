pragma solidity 0.8.24;

import "@openzeppelin/contracts-v4/utils/Strings.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {L2TransactionRequestTwoBridgesOuter, BridgehubBurnCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {PermanentRestriction} from "contracts/governance/PermanentRestriction.sol";
import {IPermanentRestriction} from "contracts/governance/IPermanentRestriction.sol";
import {NotAllowed, UnsupportedEncodingVersion, InvalidSelector, ZeroAddress, UnallowedImplementation, RemovingPermanentRestriction, CallNotAllowed} from "contracts/common/L1ContractErrors.sol";
import {Call} from "contracts/governance/Common.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {VerifierParams, FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {ChainTypeManagerTest} from "test/foundry/l1/unit/concrete/state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";

contract TestPermanentRestriction is PermanentRestriction {
    constructor(IBridgehub _bridgehub, address _l2AdminFactory) PermanentRestriction(_bridgehub, _l2AdminFactory) {}

    function isAdminOfAChain(address _chain) external view returns (bool) {
        return _isAdminOfAChain(_chain);
    }

    function getNewAdminFromMigration(Call calldata _call) external view returns (address, bool) {
        return _getNewAdminFromMigration(_call);
    }
}

contract PermanentRestrictionTest is ChainTypeManagerTest {
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
    }

    function _deployPermRestriction(
        IBridgehub _bridgehub,
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
            call.data = abi.encodeCall(Bridgehub.requestL2TransactionTwoBridges, (outer));
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
                chainData: abi.encode(IZKChain(IBridgehub(bridgehub).getZKChain(chainId)).getProtocolVersion())
            })
        );
        outer.secondBridgeCalldata = abi.encodePacked(bytes1(encoding), abi.encode(chainAssetId, bridgehubData));

        call.data = abi.encodeCall(Bridgehub.requestL2TransactionTwoBridges, (outer));
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
        bridgehub.setAddresses(sharedBridge, ICTMDeploymentTracker(address(0)), new MessageRoot(bridgehub));
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
            abi.encodeWithSelector(Bridgehub.baseToken.selector, chainId),
            abi.encode(baseToken)
        );
        vm.mockCall(address(baseToken), abi.encodeWithSelector(IERC20Metadata.name.selector), abi.encode("TestToken"));
        vm.mockCall(address(baseToken), abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode("TT"));

        vm.startPrank(governor);
        bridgehub.createNewChain({
            _chainId: chainId,
            _chainTypeManager: address(chainContractAddress),
            _baseTokenAssetId: DataEncoding.encodeNTVAssetId(block.chainid, baseToken),
            _salt: 0,
            _admin: newChainAdmin,
            _initData: getCTMInitData(),
            _factoryDeps: factoryDeps
        });
        vm.stopPrank();
    }
}
