pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import "lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import "forge-std/console.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {StateTransitionManager} from "contracts/state-transition/StateTransitionManager.sol";
import {IStateTransitionManager} from "contracts/state-transition/IStateTransitionManager.sol";
import {InitializeData, DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {GenesisUpgrade} from "contracts/upgrades/GenesisUpgrade.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {StateTransitionManagerInitializeData, ChainCreationParams} from "contracts/state-transition/IStateTransitionManager.sol";
import {InitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {PermanentRestriction} from "contracts/governance/PermanentRestriction.sol";
import {IPermanentRestriction} from "contracts/governance/IPermanentRestriction.sol";
import {Utils} from "test/foundry/unit/concrete/Utils/Utils.sol";
import {ZeroAddress, ChainZeroAddress, NotAnAdmin, UnallowedImplementation, RemovingPermanentRestriction, CallNotAllowed} from "contracts/common/L1ContractErrors.sol";
import {Call} from "contracts/governance/Common.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {VerifierParams, FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";

contract PermanentRestrictionTest is Test {
    IBridgehub internal iBridgehub;
    ChainAdmin internal chainAdmin;
    AccessControlRestriction internal restriction;
    PermanentRestriction internal permRestriction;
    DiamondProxy internal diamondProxy;
    address internal owner;

    address newChainAddress;
    DiamondInit internal initializeDiamond;

    IExecutor.ProofInput internal proofInput;

    AdminFacet internal adminFacet;
    ExecutorFacet internal executorFacet;
    GettersFacet internal gettersFacet;

    StateTransitionManager internal stateTransitionManager;
    StateTransitionManager internal chainContractAddress;
    GenesisUpgrade internal genesisUpgradeContract;
    address internal bridgehub;
    address internal diamondInit;
    address internal constant governor = address(0x1010101);
    address internal constant admin = address(0x2020202);
    address internal constant validator = address(0x5050505);
    address internal constant baseToken = address(0x3030303);
    address internal constant sharedBridge = address(0x4040404);
    address internal newChainAdmin;
    uint256 chainId = block.chainid;
    address internal testnetVerifier = address(new TestnetVerifier());
    address internal hyperchain;

    Diamond.FacetCut[] internal facetCuts;

    function setUp() public {
        iBridgehub = new Bridgehub();
        bridgehub = address(iBridgehub);
        newChainAdmin = makeAddr("chainadmin");

        vm.startPrank(bridgehub);
        stateTransitionManager = new StateTransitionManager(bridgehub, type(uint256).max);
        diamondInit = address(new DiamondInit());
        genesisUpgradeContract = new GenesisUpgrade();

        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new UtilsFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getUtilsFacetSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new AdminFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getAdminSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new ExecutorFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getExecutorSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new GettersFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: gettersSelectors()
            })
        );

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(address(diamondInit))
        });

        StateTransitionManagerInitializeData memory stmInitializeDataNoGovernor = StateTransitionManagerInitializeData({
            owner: address(0),
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
            protocolVersion: 0
        });

        vm.expectRevert(bytes.concat("STM: owner zero"));
        new TransparentUpgradeableProxy(
            address(stateTransitionManager),
            admin,
            abi.encodeCall(StateTransitionManager.initialize, stmInitializeDataNoGovernor)
        );

        StateTransitionManagerInitializeData memory stmInitializeData = StateTransitionManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
            protocolVersion: 0
        });

        TransparentUpgradeableProxy transparentUpgradeableProxy = new TransparentUpgradeableProxy(
            address(stateTransitionManager),
            admin,
            abi.encodeCall(StateTransitionManager.initialize, stmInitializeData)
        );
        chainContractAddress = StateTransitionManager(address(transparentUpgradeableProxy));

        vm.stopPrank();
        vm.startPrank(governor);

        createNewChain(getDiamondCutData(address(diamondInit)));
        initializeDiamond = new DiamondInit();
        newChainAddress = chainContractAddress.getHyperchain(chainId);
        executorFacet = ExecutorFacet(address(newChainAddress));
        gettersFacet = GettersFacet(address(newChainAddress));
        adminFacet = AdminFacet(address(newChainAddress));
        vm.stopPrank();

        owner = makeAddr("owner");

        iBridgehub = new Bridgehub();
        hyperchain = chainContractAddress.getHyperchain(chainId);
        console.log(hyperchain);
        uint256 id = IZkSyncHyperchain(hyperchain).getChainId();
        permRestriction = new PermanentRestriction(owner, iBridgehub);

        restriction = new AccessControlRestriction(0, owner);
        address[] memory restrictions = new address[](1);
        restrictions[0] = address(restriction);

        chainAdmin = new ChainAdmin(restrictions);
    }

    function test_ownerAsAddressZero() public {
        vm.expectRevert(ZeroAddress.selector);
        permRestriction = new PermanentRestriction(address(0), iBridgehub);
    }

    function test_allowAdminImplementation(bytes32 implementationHash) public {
        vm.expectEmit();
        emit IPermanentRestriction.AdminImplementationAllowed(implementationHash, true);

        vm.prank(owner);
        permRestriction.allowAdminImplementation(implementationHash , true);
    }

    function test_setAllowedData(bytes memory data) public {
        vm.expectEmit();
        emit IPermanentRestriction.AllowedDataChanged(data, true);

        vm.prank(owner);
        permRestriction.setAllowedData(data , true);
    }

    function test_setSelectorIsValidated(bytes4 selector) public {
        vm.expectEmit();
        emit IPermanentRestriction.SelectorValidationChanged(selector, true);

        vm.prank(owner);
        permRestriction.setSelectorIsValidated(selector , true);
    }

    function test_tryCompareAdminOfAChainIsAddressZero() public {
        vm.expectRevert(ChainZeroAddress.selector);
        permRestriction.tryCompareAdminOfAChain(address(0), owner);
    }

    function test_tryCompareAdminOfAChainNotAHyperchain() public {
        //vm.expectRevert(ChainZeroAddress.selector);
        permRestriction.tryCompareAdminOfAChain(makeAddr("Caller"), owner);
    }

    function test_tryCompareAdminOfAChainNotAnAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(NotAnAdmin.selector, IZkSyncHyperchain(hyperchain).getAdmin(), owner));
        permRestriction.tryCompareAdminOfAChain(hyperchain, owner);
    }

    function test_tryCompareAdminOfAChain() public {
        permRestriction.tryCompareAdminOfAChain(hyperchain, newChainAdmin);
    }

    function test_validateCallTooShortData() public {
        Call memory call = Call({
            target: hyperchain,
            value: 0,
            data: ""
        });

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
        permRestriction.allowAdminImplementation(address(chainAdmin).codehash , true);

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
        permRestriction.allowAdminImplementation(address(chainAdmin).codehash , true);
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

    function getDiamondCutData(address _diamondInit) internal returns (Diamond.DiamondCutData memory) {
        InitializeDataNewChain memory initializeData = Utils.makeInitializeDataForNewChain(testnetVerifier);

        bytes memory initCalldata = abi.encode(initializeData);

        return Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: _diamondInit, initCalldata: initCalldata});
    }

    function createNewChain(Diamond.DiamondCutData memory _diamondCut) internal {
        vm.stopPrank();
        vm.startPrank(bridgehub);

        chainContractAddress.createNewChain({
            _chainId: chainId,
            _baseToken: baseToken,
            _sharedBridge: sharedBridge,
            _admin: newChainAdmin,
            _diamondCut: abi.encode(_diamondCut)
        });
    }

    function gettersSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](29);
        selectors[0] = GettersFacet.getVerifier.selector;
        selectors[1] = GettersFacet.getAdmin.selector;
        selectors[2] = GettersFacet.getPendingAdmin.selector;
        selectors[3] = GettersFacet.getChainId.selector;
        selectors[4] = GettersFacet.getTotalBlocksVerified.selector;
        selectors[5] = GettersFacet.getTotalBlocksExecuted.selector;
        selectors[6] = GettersFacet.getTotalPriorityTxs.selector;
        selectors[7] = GettersFacet.getFirstUnprocessedPriorityTx.selector;
        selectors[8] = GettersFacet.getPriorityQueueSize.selector;
        selectors[9] = GettersFacet.priorityQueueFrontOperation.selector;
        selectors[10] = GettersFacet.isValidator.selector;
        selectors[11] = GettersFacet.l2LogsRootHash.selector;
        selectors[12] = GettersFacet.storedBatchHash.selector;
        selectors[13] = GettersFacet.getL2BootloaderBytecodeHash.selector;
        selectors[14] = GettersFacet.getL2DefaultAccountBytecodeHash.selector;
        selectors[15] = GettersFacet.getVerifierParams.selector;
        selectors[16] = GettersFacet.getL2SystemContractsUpgradeBatchNumber.selector;
        selectors[17] = GettersFacet.getPriorityTxMaxGasLimit.selector;
        selectors[18] = GettersFacet.isEthWithdrawalFinalized.selector;
        selectors[19] = GettersFacet.facets.selector;
        selectors[20] = GettersFacet.facetFunctionSelectors.selector;
        selectors[21] = GettersFacet.facetAddresses.selector;
        selectors[22] = GettersFacet.facetAddress.selector;
        selectors[23] = GettersFacet.getSemverProtocolVersion.selector;
        selectors[24] = GettersFacet.getProtocolVersion.selector;
        selectors[25] = GettersFacet.getTotalBatchesCommitted.selector;
        selectors[26] = GettersFacet.getTotalBatchesVerified.selector;
        selectors[27] = GettersFacet.getTotalBatchesExecuted.selector;
        selectors[28] = GettersFacet.getL2SystemContractsUpgradeTxHash.selector;
        return selectors;
    }
}