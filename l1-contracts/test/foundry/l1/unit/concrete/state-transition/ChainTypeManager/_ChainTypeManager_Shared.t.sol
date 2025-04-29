// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/Script.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {InitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {ChainTypeManagerInitializeData, ChainCreationParams} from "contracts/state-transition/IChainTypeManager.sol";
import {TestnetVerifier} from "contracts/state-transition/verifiers/TestnetVerifier.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";

import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";

contract ChainTypeManagerTest is Test {
    ChainTypeManager internal chainTypeManager;
    ChainTypeManager internal chainContractAddress;
    L1GenesisUpgrade internal genesisUpgradeContract;
    Bridgehub internal bridgehub;
    address internal rollupL1DAValidator;
    address internal diamondInit;
    address internal constant governor = address(0x1010101);
    address internal constant admin = address(0x2020202);
    address internal constant baseToken = address(0x3030303);
    address internal constant sharedBridge = address(0x4040404);
    address internal constant validator = address(0x5050505);
    address internal constant l1Nullifier = address(0x6060606);
    address internal constant serverNotifier = address(0x7070707);
    address internal newChainAdmin;
    uint256 chainId = 112;
    address internal testnetVerifier = address(new TestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));
    bytes internal forceDeploymentsData = hex"";

    uint256 eraChainId = 9;
    uint256 internal constant MAX_NUMBER_OF_ZK_CHAINS = 10;

    Diamond.FacetCut[] internal facetCuts;

    function deploy() public {
        bridgehub = new Bridgehub(block.chainid, governor, MAX_NUMBER_OF_ZK_CHAINS);
        vm.prank(governor);
        bridgehub.setAddresses(sharedBridge, ICTMDeploymentTracker(address(0)), IMessageRoot(address(0)));

        vm.mockCall(
            address(sharedBridge),
            abi.encodeCall(L1AssetRouter.l2BridgeAddress, (chainId)),
            abi.encode(makeAddr("l2BridgeAddress"))
        );

        newChainAdmin = makeAddr("chainadmin");

        vm.startPrank(address(bridgehub));
        chainTypeManager = new ChainTypeManager(address(IBridgehub(address(bridgehub))));
        diamondInit = address(new DiamondInit());
        genesisUpgradeContract = new L1GenesisUpgrade();

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
                facet: address(new AdminFacet(block.chainid, RollupDAManager(address(0)))),
                action: Diamond.Action.Add,
                isFreezable: false,
                selectors: Utils.getAdminSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new ExecutorFacet(block.chainid)),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getExecutorSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new GettersFacet()),
                action: Diamond.Action.Add,
                isFreezable: false,
                selectors: Utils.getGettersSelectors()
            })
        );

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(address(diamondInit)),
            forceDeploymentsData: forceDeploymentsData
        });

        ChainTypeManagerInitializeData memory ctmInitializeDataNoGovernor = ChainTypeManagerInitializeData({
            owner: address(0),
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
            protocolVersion: 0,
            serverNotifier: serverNotifier
        });

        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(chainTypeManager),
            admin,
            abi.encodeCall(ChainTypeManager.initialize, ctmInitializeDataNoGovernor)
        );

        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
            protocolVersion: 0,
            serverNotifier: serverNotifier
        });

        TransparentUpgradeableProxy transparentUpgradeableProxy = new TransparentUpgradeableProxy(
            address(chainTypeManager),
            admin,
            abi.encodeCall(ChainTypeManager.initialize, ctmInitializeData)
        );
        chainContractAddress = ChainTypeManager(address(transparentUpgradeableProxy));

        rollupL1DAValidator = Utils.deployL1RollupDAValidatorBytecode();

        vm.stopPrank();
        vm.startPrank(governor);
    }

    function getDiamondCutData(address _diamondInit) internal view returns (Diamond.DiamondCutData memory) {
        InitializeDataNewChain memory initializeData = Utils.makeInitializeDataForNewChain(testnetVerifier);

        bytes memory initCalldata = abi.encode(initializeData);

        return Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: _diamondInit, initCalldata: initCalldata});
    }

    function getDiamondCutDataWithCustomFacets(
        address _diamondInit,
        Diamond.FacetCut[] memory _facetCuts
    ) internal returns (Diamond.DiamondCutData memory) {
        return Diamond.DiamondCutData({facetCuts: _facetCuts, initAddress: _diamondInit, initCalldata: bytes("")});
    }

    function getCTMInitData() internal view returns (bytes memory) {
        return abi.encode(abi.encode(getDiamondCutData(diamondInit)), forceDeploymentsData);
    }

    function createNewChain(Diamond.DiamondCutData memory _diamondCut) internal returns (address) {
        vm.stopPrank();
        vm.prank(address(bridgehub));

        vm.mockCall(
            address(sharedBridge),
            abi.encodeWithSelector(IL1AssetRouter.L1_NULLIFIER.selector),
            abi.encode(l1Nullifier)
        );

        vm.mockCall(
            address(l1Nullifier),
            abi.encodeWithSelector(IL1Nullifier.l2BridgeAddress.selector),
            abi.encode(l1Nullifier)
        );

        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(Bridgehub.baseToken.selector, chainId),
            abi.encode(baseToken)
        );
        vm.mockCall(address(baseToken), abi.encodeWithSelector(IERC20Metadata.name.selector), abi.encode("TestToken"));
        vm.mockCall(address(baseToken), abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode("TT"));

        return
            chainContractAddress.createNewChain({
                _chainId: chainId,
                _baseTokenAssetId: DataEncoding.encodeNTVAssetId(block.chainid, baseToken),
                _admin: newChainAdmin,
                _initData: abi.encode(abi.encode(_diamondCut), bytes("")),
                _factoryDeps: new bytes[](0)
            });

        vm.startPrank(governor);
    }

    function createNewChainWithId(Diamond.DiamondCutData memory _diamondCut, uint256 id) internal {
        vm.stopPrank();
        vm.prank(address(bridgehub));

        vm.mockCall(
            address(sharedBridge),
            abi.encodeWithSelector(IL1AssetRouter.L1_NULLIFIER.selector),
            abi.encode(l1Nullifier)
        );

        vm.mockCall(
            address(l1Nullifier),
            abi.encodeWithSelector(IL1Nullifier.l2BridgeAddress.selector),
            abi.encode(l1Nullifier)
        );

        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(Bridgehub.baseToken.selector, chainId),
            abi.encode(baseToken)
        );
        vm.mockCall(address(baseToken), abi.encodeWithSelector(IERC20Metadata.name.selector), abi.encode("TestToken"));
        vm.mockCall(address(baseToken), abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode("TT"));

        chainContractAddress.createNewChain({
            _chainId: id,
            _baseTokenAssetId: DataEncoding.encodeNTVAssetId(id, baseToken),
            _admin: newChainAdmin,
            _initData: abi.encode(abi.encode(_diamondCut), bytes("")),
            _factoryDeps: new bytes[](0)
        });

        vm.startPrank(governor);
    }

    function _mockGetZKChainFromBridgehub(address _chainAddress) internal {
        // We have to mock the call to the bridgehub's getZKChain since we are mocking calls in the ChainTypeManagerTest.createNewChain() as well...
        // So, although ideally the bridgehub SHOULD have responded with the correct address for the chain when we call getZKChain(chainId), in our case it will not
        // So, we mock that behavior again.
        vm.mockCall(address(bridgehub), abi.encodeCall(Bridgehub.getZKChain, chainId), abi.encode(_chainAddress));
    }

    function _mockMigrationPausedFromBridgehub() internal {
        vm.mockCall(address(bridgehub), abi.encodeWithSignature("migrationPaused()"), abi.encode(true));
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Functions that have been migrated from the erstwhile StateTransitionManager to Bridgehub
    ////////////////////////////////////////////////////////////////////////////////////////////

    function _getAllZKChainIDs() internal view returns (uint256[] memory chainIDs) {
        chainIDs = bridgehub.getAllZKChainChainIDs();
    }

    function _getAllZKChains() internal view returns (address[] memory chainAddresses) {
        chainAddresses = bridgehub.getAllZKChains();
    }

    function _registerAlreadyDeployedZKChain(uint256 _chainId, address _zkChain) internal {
        bridgehub.registerAlreadyDeployedZKChain(_chainId, _zkChain);
    }
}
