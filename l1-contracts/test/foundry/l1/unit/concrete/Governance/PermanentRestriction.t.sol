pragma solidity 0.8.24;

import "@openzeppelin/contracts-v4/utils/Strings.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {PermanentRestriction} from "contracts/governance/PermanentRestriction.sol";
import {IPermanentRestriction} from "contracts/governance/IPermanentRestriction.sol";
import {ZeroAddress, ChainZeroAddress, NotAnAdmin, UnallowedImplementation, RemovingPermanentRestriction, CallNotAllowed} from "contracts/common/L1ContractErrors.sol";
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

contract PermanentRestrictionTest is ChainTypeManagerTest {
    ChainAdmin internal chainAdmin;
    AccessControlRestriction internal restriction;
    PermanentRestriction internal permRestriction;

    address internal owner;
    address internal hyperchain;

    function setUp() public {
        deploy();

        createNewChainBridgehub();

        vm.stopPrank();

        owner = makeAddr("owner");
        hyperchain = chainContractAddress.getHyperchain(chainId);
        permRestriction = new PermanentRestriction(owner, bridgehub);
        restriction = new AccessControlRestriction(0, owner);
        address[] memory restrictions = new address[](1);
        restrictions[0] = address(restriction);
        chainAdmin = new ChainAdmin(restrictions);
    }

    function test_ownerAsAddressZero() public {
        vm.expectRevert(ZeroAddress.selector);
        permRestriction = new PermanentRestriction(address(0), bridgehub);
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

    function createNewChainBridgehub() internal {
        bytes[] memory factoryDeps = new bytes[](0);
        vm.stopPrank();
        vm.startPrank(governor);
        bridgehub.addChainTypeManager(address(chainContractAddress));
        bridgehub.addTokenAssetId(DataEncoding.encodeNTVAssetId(block.chainid, baseToken));
        bridgehub.setAddresses(sharedBridge, ICTMDeploymentTracker(address(0)), new MessageRoot(bridgehub));
        address l1Nullifier = makeAddr("l1Nullifier");
        address l2LegacySharedBridge = makeAddr("l2LegacySharedBridge");
        vm.mockCall(
            address(sharedBridge),
            abi.encodeWithSelector(IL1AssetRouter.L1_NULLIFIER.selector),
            abi.encode(l1Nullifier)
        );
        vm.mockCall(
            address(l1Nullifier),
            abi.encodeWithSelector(IL1Nullifier.__DEPRECATED_l2BridgeAddress.selector),
            abi.encode(l2LegacySharedBridge)
        );
        bridgehub.createNewChain({
            _chainId: chainId,
            _chainTypeManager: address(chainContractAddress),
            _baseTokenAssetId: DataEncoding.encodeNTVAssetId(block.chainid, baseToken),
            _salt: 0,
            _admin: newChainAdmin,
            _initData: getCTMInitData(),
            _factoryDeps: factoryDeps
        });
    }
}
