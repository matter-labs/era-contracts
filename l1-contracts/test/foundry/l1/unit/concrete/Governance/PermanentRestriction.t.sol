pragma solidity 0.8.24;

import "@openzeppelin/contracts-v4/utils/Strings.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {L2TransactionRequestTwoBridgesOuter, BridgehubBurnCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {PermanentRestriction, MIN_GAS_FOR_FALLABLE_CALL} from "contracts/governance/PermanentRestriction.sol";
import {IPermanentRestriction} from "contracts/governance/IPermanentRestriction.sol";
import {NotAllowed, NotEnoughGas, InvalidAddress, UnsupportedEncodingVersion, InvalidSelector, NotBridgehub, ZeroAddress, ChainZeroAddress, NotAnAdmin, UnallowedImplementation, RemovingPermanentRestriction, CallNotAllowed} from "contracts/common/L1ContractErrors.sol";
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

contract PermanentRestrictionTest is ChainTypeManagerTest {
    ChainAdmin internal chainAdmin;
    AccessControlRestriction internal restriction;
    PermanentRestriction internal permRestriction;

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
    ) internal returns (PermanentRestriction proxy, PermanentRestriction impl) {
        impl = new PermanentRestriction(_bridgehub, _l2AdminFactory);
        TransparentUpgradeableProxy tup = new TransparentUpgradeableProxy(
            address(impl),
            address(uint160(1)),
            abi.encodeCall(PermanentRestriction.initialize, (_owner))
        );

        proxy = PermanentRestriction(address(tup));
    }

    function test_ownerAsAddressZero() public {
        PermanentRestriction impl = new PermanentRestriction(bridgehub, L2_FACTORY_ADDR);
        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            address(uint160(1)),
            abi.encodeCall(PermanentRestriction.initialize, (address(0)))
        );
    }

    function test_allowAdminImplementation(bytes32 implementationHash) public {
        vm.expectEmit(true, false, false, true);
        emit IPermanentRestriction.AdminImplementationAllowed(implementationHash, true);

        vm.prank(owner);
        permRestriction.allowAdminImplementation(implementationHash, true);
    }

    function test_setAllowedData(bytes memory data) public {
        vm.expectEmit(false, false, false, true);
        emit IPermanentRestriction.AllowedDataChanged(data, true);

        vm.prank(owner);
        permRestriction.setAllowedData(data, true);
    }

    function test_setSelectorIsValidated(bytes4 selector) public {
        vm.expectEmit(true, false, false, true);
        emit IPermanentRestriction.SelectorValidationChanged(selector, true);

        vm.prank(owner);
        permRestriction.setSelectorIsValidated(selector, true);
    }

    function test_tryCompareAdminOfAChainIsAddressZero() public {
        vm.expectRevert(ChainZeroAddress.selector);
        permRestriction.tryCompareAdminOfAChain(address(0), owner);
    }

    function test_tryCompareAdminOfAChainNotAHyperchain() public {
        vm.expectRevert();
        permRestriction.tryCompareAdminOfAChain(makeAddr("random"), owner);
    }

    function test_tryCompareAdminOfAChainNotAnAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(NotAnAdmin.selector, IZKChain(hyperchain).getAdmin(), owner));
        permRestriction.tryCompareAdminOfAChain(hyperchain, owner);
    }

    function test_tryCompareAdminOfAChain() public {
        permRestriction.tryCompareAdminOfAChain(hyperchain, newChainAdmin);
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
        permRestriction.allowAdminImplementation(address(chainAdmin).codehash, true);

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
        permRestriction.allowAdminImplementation(address(chainAdmin).codehash, true);

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
        permRestriction.setSelectorIsValidated(IAdmin.acceptAdmin.selector, true);
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
        permRestriction.setSelectorIsValidated(IAdmin.acceptAdmin.selector, true);
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

    function test_tryGetNewAdminFromMigrationRevertWhenInvalidSelector() public {
        Call memory call = _encodeMigraationCall(false, true, true, true, true, address(0));

        vm.expectRevert(abi.encodeWithSelector(NotBridgehub.selector, address(0)));
        permRestriction.tryGetNewAdminFromMigration(call);
    }

    function test_tryGetNewAdminFromMigrationRevertWhenNotBridgehub() public {
        Call memory call = _encodeMigraationCall(true, false, true, true, true, address(0));

        vm.expectRevert(abi.encodeWithSelector(InvalidSelector.selector, bytes4(0)));
        permRestriction.tryGetNewAdminFromMigration(call);
    }

    function test_tryGetNewAdminFromMigrationRevertWhenNotSharedBridge() public {
        Call memory call = _encodeMigraationCall(true, true, false, true, true, address(0));

        vm.expectRevert(abi.encodeWithSelector(InvalidAddress.selector, address(sharedBridge), address(0)));
        permRestriction.tryGetNewAdminFromMigration(call);
    }

    function test_tryGetNewAdminFromMigrationRevertWhenIncorrectEncoding() public {
        Call memory call = _encodeMigraationCall(true, true, true, false, true, address(0));

        vm.expectRevert(abi.encodeWithSelector(UnsupportedEncodingVersion.selector));
        permRestriction.tryGetNewAdminFromMigration(call);
    }

    function test_tryGetNewAdminFromMigrationRevertWhenIncorrectAssetId() public {
        Call memory call = _encodeMigraationCall(true, true, true, true, false, address(0));

        vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector));
        permRestriction.tryGetNewAdminFromMigration(call);
    }

    function test_tryGetNewAdminFromMigrationShouldWorkCorrectly() public {
        address l2Addr = makeAddr("l2Addr");
        Call memory call = _encodeMigraationCall(true, true, true, true, true, l2Addr);

        address result = permRestriction.tryGetNewAdminFromMigration(call);
        assertEq(result, l2Addr);
    }

    function test_validateMigrationToL2RevertNotAllowed() public {
        Call memory call = _encodeMigraationCall(true, true, true, true, true, address(0));

        vm.expectRevert(abi.encodeWithSelector(NotAllowed.selector, address(0)));
        permRestriction.validateCall(call, owner);
    }

    function test_validateMigrationToL2() public {
        address expectedAddress = L2ContractHelper.computeCreate2Address(
            L2_FACTORY_ADDR,
            bytes32(0),
            bytes32(0),
            bytes32(0)
        );

        vm.expectEmit(true, false, false, true);
        emit IPermanentRestriction.AllowL2Admin(expectedAddress);
        permRestriction.allowL2Admin(bytes32(0), bytes32(0), bytes32(0));

        Call memory call = _encodeMigraationCall(true, true, true, true, true, expectedAddress);

        // Should not fail
        permRestriction.validateCall(call, owner);
    }

    function test_validateNotEnoughGas() public {
        address l2Addr = makeAddr("l2Addr");
        Call memory call = _encodeMigraationCall(true, true, true, true, true, l2Addr);

        vm.expectRevert(abi.encodeWithSelector(NotEnoughGas.selector));
        permRestriction.validateCall{gas: MIN_GAS_FOR_FALLABLE_CALL}(call, address(0));
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
        bridgehub.setAssetHandlerAddress(
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
