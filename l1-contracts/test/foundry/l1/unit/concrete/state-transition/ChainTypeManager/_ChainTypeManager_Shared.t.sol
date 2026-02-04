// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/Script.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IMessageRoot} from "contracts/core/message-root/IMessageRoot.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {InitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";
import {IChainTypeManager, ChainCreationParams, ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET} from "contracts/common/Config.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";
import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";

import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {UtilsCallMockerTest} from "foundry-test/l1/unit/concrete/Utils/UtilsCallMocker.t.sol";
import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";

contract ChainTypeManagerTest is UtilsCallMockerTest {
    using stdStorage for StdStorage;

    EraChainTypeManager internal chainTypeManager;
    EraChainTypeManager internal chainContractAddress;
    L1GenesisUpgrade internal genesisUpgradeContract;
    L1Bridgehub internal bridgehub;
    L1ChainAssetHandler internal chainAssetHandler;
    L1MessageRoot internal messageroot;
    address internal rollupL1DAValidator;
    address internal diamondInit;
    address internal interopCenterAddress;
    address internal governor;
    address internal admin;
    address internal baseToken;
    address internal sharedBridge;
    address internal validator;
    address internal l1Nullifier;
    address internal serverNotifier;
    bytes32 internal baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, baseToken);
    address internal newChainAdmin;
    uint256 l1ChainId = 5;
    uint256 chainId = 112;
    address internal testnetVerifier = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));
    bytes internal forceDeploymentsData = hex"";

    uint256 eraChainId = 9;
    uint256 internal constant MAX_NUMBER_OF_ZK_CHAINS = 10;

    Diamond.FacetCut[] internal facetCuts;

    function deploy() public {
        // Timestamp needs to be late enough for `pauseDepositsBeforeInitiatingMigration` time checks
        vm.warp(PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET + 1);

        interopCenterAddress = makeAddr("interopCenter");
        governor = makeAddr("governor");
        admin = makeAddr("admin");
        baseToken = makeAddr("baseToken");
        sharedBridge = makeAddr("sharedBridge");
        validator = makeAddr("validator");
        l1Nullifier = makeAddr("l1Nullifier");
        serverNotifier = makeAddr("serverNotifier");
        bridgehub = new L1Bridgehub(governor, MAX_NUMBER_OF_ZK_CHAINS);
        messageroot = new L1MessageRoot(address(bridgehub), 1);
        chainAssetHandler = new L1ChainAssetHandler(
            governor,
            address(bridgehub),
            address(0),
            address(messageroot),
            address(0),
            IL1Nullifier(address(0))
        );
        stdstore
            .target(address(messageroot))
            .sig(IL1MessageRoot.v31UpgradeChainBatchNumber.selector)
            .with_key(chainId)
            .checked_write(uint256(1));
        vm.prank(governor);
        bridgehub.setAddresses(
            sharedBridge,
            ICTMDeploymentTracker(address(0)),
            messageroot,
            address(chainAssetHandler),
            address(0)
        );

        vm.mockCall(
            address(sharedBridge),
            abi.encodeCall(L1AssetRouter.l2BridgeAddress, (chainId)),
            abi.encode(makeAddr("l2BridgeAddress"))
        );

        newChainAdmin = makeAddr("chainadmin");

        vm.startPrank(address(bridgehub));
        chainTypeManager = new EraChainTypeManager(address(bridgehub), interopCenterAddress, address(0));
        diamondInit = address(new DiamondInit(false));
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
                facet: address(new AdminFacet(block.chainid, RollupDAManager(address(0)), false)),
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
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(
                    new MailboxFacet(
                        eraChainId,
                        block.chainid,
                        address(0),
                        IEIP7702Checker(makeAddr("eip7702Checker")),
                        false
                    )
                ),
                action: Diamond.Action.Add,
                isFreezable: false,
                selectors: Utils.getMailboxSelectors()
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
            abi.encodeCall(IChainTypeManager.initialize, ctmInitializeDataNoGovernor)
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
            abi.encodeCall(IChainTypeManager.initialize, ctmInitializeData)
        );
        chainContractAddress = EraChainTypeManager(address(transparentUpgradeableProxy));

        // Set verifier for protocol version 0 (used for chain creation)
        vm.stopPrank();
        vm.prank(governor);
        chainContractAddress.setProtocolVersionVerifier(0, testnetVerifier);
        vm.startPrank(address(bridgehub));

        rollupL1DAValidator = Utils.deployL1RollupDAValidatorBytecode();

        vm.stopPrank();
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
            abi.encodeWithSelector(IBridgehubBase.baseToken.selector, chainId),
            abi.encode(baseToken)
        );
        vm.mockCall(address(baseToken), abi.encodeWithSelector(IERC20Metadata.name.selector), abi.encode("TestToken"));
        vm.mockCall(address(baseToken), abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode("TT"));
        vm.mockCall(address(baseToken), abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(18));

        mockDiamondInitInteropCenterCallsWithAddress(address(bridgehub), sharedBridge, baseTokenAssetId);

        vm.prank(address(bridgehub));
        return
            chainContractAddress.createNewChain({
                _chainId: chainId,
                _baseTokenAssetId: baseTokenAssetId,
                _admin: newChainAdmin,
                _initData: abi.encode(abi.encode(_diamondCut), bytes("")),
                _factoryDeps: new bytes[](0)
            });
    }

    function createNewChainWithId(Diamond.DiamondCutData memory _diamondCut, uint256 id) internal {

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
            abi.encodeWithSelector(IBridgehubBase.baseToken.selector, chainId),
            abi.encode(baseToken)
        );
        vm.mockCall(address(baseToken), abi.encodeWithSelector(IERC20Metadata.name.selector), abi.encode("TestToken"));
        vm.mockCall(address(baseToken), abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode("TT"));
        vm.mockCall(address(baseToken), abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(18));

        vm.prank(address(bridgehub));
        chainContractAddress.createNewChain({
            _chainId: id,
            _baseTokenAssetId: DataEncoding.encodeNTVAssetId(id, baseToken),
            _admin: newChainAdmin,
            _initData: abi.encode(abi.encode(_diamondCut), bytes("")),
            _factoryDeps: new bytes[](0)
        });
    }

    function _mockGetZKChainFromBridgehub(address _chainAddress) internal {
        // We have to mock the call to the bridgehub's getZKChain since we are mocking calls in the ChainTypeManagerTest.createNewChain() as well...
        // So, although ideally the bridgehub SHOULD have responded with the correct address for the chain when we call getZKChain(chainId), in our case it will not
        // So, we mock that behavior again.
        vm.mockCall(address(bridgehub), abi.encodeCall(IBridgehubBase.getZKChain, chainId), abi.encode(_chainAddress));
    }

    function _mockMigrationPausedFromBridgehub() internal {
        address mockChainAssetHandler = makeAddr("mockChainAssetHandler");
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSignature("chainAssetHandler()"),
            abi.encode(mockChainAssetHandler)
        );
        vm.mockCall(mockChainAssetHandler, abi.encodeWithSignature("migrationPaused()"), abi.encode(true));
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
