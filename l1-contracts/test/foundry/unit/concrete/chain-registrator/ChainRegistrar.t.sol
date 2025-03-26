// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DummyChainTypeManagerWBH} from "contracts/dev-contracts/test/DummyChainTypeManagerWithBridgeHubAddress.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";

import "contracts/bridgehub/Bridgehub.sol";
import "contracts/chain-registrar/ChainRegistrar.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import "contracts/dev-contracts/test/DummyBridgehub.sol";
import "contracts/dev-contracts/test/DummySharedBridge.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {console2 as console} from "forge-std/Script.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ChainCreationParams} from "contracts/state-transition/IChainTypeManager.sol";
import {FeeParams} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import "contracts/dev-contracts/test/DummyZKChain.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";

contract ChainRegistrarTest is Test {
    DummyBridgehub private bridgeHub;
    DummyChainTypeManagerWBH private ctm;
    address private admin;
    address private deployer;
    ChainRegistrar private chainRegistrar;
    L1AssetRouter private assetRouter;
    bytes diamondCutData;
    bytes initCalldata;
    address l1NullifierAddress;
    L1Nullifier l1NullifierImpl;
    L1Nullifier l1Nullifier;

    constructor() {
        bridgeHub = new DummyBridgehub();
        ctm = new DummyChainTypeManagerWBH(address(bridgeHub));
        admin = makeAddr("admin");
        deployer = makeAddr("deployer");
        vm.prank(admin);

        l1NullifierImpl = new L1NullifierDev({
            _bridgehub: IBridgehub(address(bridgeHub)),
            _eraChainId: 270,
            _eraDiamondProxy: makeAddr("era")
        });

        assetRouter = new L1AssetRouter({
            _l1WethAddress: makeAddr("weth"),
            _bridgehub: address(bridgeHub),
            _l1Nullifier: address(l1NullifierImpl),
            _eraChainId: 270,
            _eraDiamondProxy: makeAddr("era")
        });
        address defaultOwnerSb = assetRouter.owner();
        vm.prank(defaultOwnerSb);
        assetRouter.transferOwnership(admin);
        vm.startPrank(admin);
        assetRouter.acceptOwnership();
        bridgeHub.setSharedBridge(address(assetRouter));

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            verifier: IVerifier(makeAddr("verifier")),
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: bytes32(0),
                recursionLeafLevelVkHash: bytes32(0),
                recursionCircuitsSetVksHash: bytes32(0)
            }),
            l2BootloaderBytecodeHash: bytes32(0),
            l2DefaultAccountBytecodeHash: bytes32(0),
            l2EvmEmulatorBytecodeHash: bytes32(0),
            priorityTxMaxGasLimit: 10,
            feeParams: FeeParams({
                pubdataPricingMode: PubdataPricingMode.Rollup,
                batchOverheadL1Gas: 1_000_000,
                maxPubdataPerBatch: 110_000,
                maxL2GasPerBatch: 80_000_000,
                priorityTxMaxPubdata: 99_000,
                minimalL2GasPrice: 250_000_000
            }),
            blobVersionedHashRetriever: makeAddr("blob")
        });
        initCalldata = abi.encode(initializeData);

        Diamond.DiamondCutData memory diamondCutDataStruct = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: makeAddr("init"),
            initCalldata: initCalldata
        });

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: makeAddr("genesis"),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: diamondCutDataStruct,
            forceDeploymentsData: hex""
        });
        diamondCutData = abi.encode(diamondCutDataStruct);
        vm.stopPrank();
        vm.prank(ctm.admin());
        ctm.setChainCreationParams(chainCreationParams);
        address chainRegistrarImplementation = address(new ChainRegistrar());
        TransparentUpgradeableProxy chainRegistrarProxy = new TransparentUpgradeableProxy(
            chainRegistrarImplementation,
            admin,
            abi.encodeCall(ChainRegistrar.initialize, (address(bridgeHub), deployer, admin))
        );
        chainRegistrar = ChainRegistrar(address(chainRegistrarProxy));
    }

    function test_ChainIsAlreadyProposed() public {
        address author = makeAddr("author");
        vm.startPrank(author);
        chainRegistrar.proposeChainRegistration({
            _chainId: 1,
            _pubdataPricingMode: PubdataPricingMode.Validium,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("setter"),
            _gasPriceMultiplierNominator: 1,
            _gasPriceMultiplierDenominator: 1
        });

        vm.expectRevert(ChainRegistrar.ChainIsAlreadyProposed.selector);
        chainRegistrar.proposeChainRegistration({
            _chainId: 1,
            _pubdataPricingMode: PubdataPricingMode.Validium,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("newGovernor"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("setter"),
            _gasPriceMultiplierNominator: 1,
            _gasPriceMultiplierDenominator: 1
        });
        vm.stopPrank();
    }

    function test_SuccessfulProposal() public {
        address author = makeAddr("author");
        vm.prank(author);
        vm.recordLogs();
        chainRegistrar.proposeChainRegistration({
            _chainId: 1,
            _pubdataPricingMode: PubdataPricingMode.Validium,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("setter"),
            _gasPriceMultiplierNominator: 1,
            _gasPriceMultiplierDenominator: 1
        });
        registerChainAndVerify(author, 1);
    }

    function test_CustomBaseToken() public {
        address author = makeAddr("author");
        vm.prank(author);
        vm.recordLogs();
        TestnetERC20Token token = new TestnetERC20Token("test", "test", 18);
        token.mint(author, 100 ether);
        vm.prank(author);
        token.approve(address(chainRegistrar), 10 ether);
        vm.prank(author);
        chainRegistrar.proposeChainRegistration({
            _chainId: 1,
            _pubdataPricingMode: PubdataPricingMode.Validium,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: address(token),
            _tokenMultiplierSetter: makeAddr("setter"),
            _gasPriceMultiplierNominator: 10,
            _gasPriceMultiplierDenominator: 1
        });
        registerChainAndVerify(author, 1);
    }

    function test_PreTransferErc20Token() public {
        address author = makeAddr("author");
        vm.startPrank(author);
        vm.recordLogs();
        TestnetERC20Token token = new TestnetERC20Token("test", "test", 18);
        token.mint(author, 100 ether);
        token.transfer(chainRegistrar.l2Deployer(), 10 ether);
        chainRegistrar.proposeChainRegistration({
            _chainId: 1,
            _pubdataPricingMode: PubdataPricingMode.Validium,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: address(token),
            _tokenMultiplierSetter: makeAddr("setter"),
            _gasPriceMultiplierNominator: 10,
            _gasPriceMultiplierDenominator: 1
        });
        vm.stopPrank();
        registerChainAndVerify(author, 1);
    }

    function test_BaseTokenPreTransferIsNotEnough() public {
        address author = makeAddr("author");
        vm.startPrank(author);
        vm.recordLogs();
        TestnetERC20Token token = new TestnetERC20Token("test", "test", 18);
        token.mint(author, 100 ether);
        token.transfer(chainRegistrar.l2Deployer(), 1 ether);
        vm.expectRevert(bytes("ERC20: insufficient allowance"));
        chainRegistrar.proposeChainRegistration({
            _chainId: 1,
            _pubdataPricingMode: PubdataPricingMode.Validium,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: address(token),
            _tokenMultiplierSetter: makeAddr("setter"),
            _gasPriceMultiplierNominator: 10,
            _gasPriceMultiplierDenominator: 1
        });
    }

    function test_BaseTokenApproveIsNotEnough() public {
        address author = makeAddr("author");
        vm.startPrank(author);
        vm.recordLogs();
        TestnetERC20Token token = new TestnetERC20Token("test", "test", 18);
        token.mint(author, 100 ether);
        token.approve(chainRegistrar.l2Deployer(), 1 ether);
        vm.expectRevert(bytes("ERC20: insufficient allowance"));
        chainRegistrar.proposeChainRegistration({
            _chainId: 1,
            _pubdataPricingMode: PubdataPricingMode.Validium,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: address(token),
            _tokenMultiplierSetter: makeAddr("setter"),
            _gasPriceMultiplierNominator: 10,
            _gasPriceMultiplierDenominator: 1
        });
    }

    function registerChainAndVerify(address author, uint256 chainId) internal {
        DummyZKChain zkChain = new DummyZKChain(address(bridgeHub), 270, 6);
        vm.prank(admin);
        ctm.setZKChain(1, address(zkChain));
        vm.prank(admin);
        //assetRouter.initializeChainGovernance(chainId, makeAddr("l2bridge"));
        ChainRegistrar.RegisteredChainConfig memory registeredConfig = chainRegistrar.getRegisteredChainConfig(chainId);
        (
            uint256 proposedChainId,
            ChainRegistrar.BaseToken memory baseToken,
            address blobOperator,
            address operator,
            address governor,
            PubdataPricingMode pubdataPricingMode
        ) = chainRegistrar.proposedChains(author, chainId);
        require(registeredConfig.diamondProxy != address(0));
        require(registeredConfig.chainAdmin != address(0));
        require(registeredConfig.l2BridgeAddress != address(0));
        require(proposedChainId == chainId);
    }
}
