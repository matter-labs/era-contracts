// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {DummyChainTypeManagerWBH} from "contracts/dev-contracts/test/DummyChainTypeManagerWithBridgeHubAddress.sol";
import {IVerifier, VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";

import {InteropCenter} from "contracts/interop/InteropCenter.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import "contracts/core/bridgehub/L1Bridgehub.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import "contracts/chain-registrar/ChainRegistrar.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import "contracts/dev-contracts/test/DummyBridgehub.sol";
import "contracts/dev-contracts/test/DummySharedBridge.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {console2 as console} from "forge-std/Script.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ChainCreationParams} from "contracts/state-transition/IChainTypeManager.sol";
import "contracts/dev-contracts/test/DummyZKChain.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";

contract ChainRegistrarTest is Test {
    DummyBridgehub private bridgeHub;
    InteropCenter private interopCenter;
    L1MessageRoot private messageRoot;
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
        interopCenter = new InteropCenter();
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        interopCenter.initL2(
            block.chainid,
            makeAddr("admin"),
            DataEncoding.encodeNTVAssetId(324, address(0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E))
        );
        messageRoot = new L1MessageRoot(address(bridgeHub), 1);
        ctm = new DummyChainTypeManagerWBH(address(bridgeHub));
        admin = makeAddr("admin");
        deployer = makeAddr("deployer");
        vm.prank(admin);

        l1NullifierImpl = new L1NullifierDev({
            _bridgehub: IL1Bridgehub(address(bridgeHub)),
            _messageRoot: IMessageRoot(address(messageRoot)),
            _interopCenter: (interopCenter),
            _eraChainId: 270,
            _eraDiamondProxy: makeAddr("era")
        });

        assetRouter = new L1AssetRouter({
            _l1WethToken: makeAddr("weth"),
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
            l2BootloaderBytecodeHash: bytes32(0),
            l2DefaultAccountBytecodeHash: bytes32(0),
            l2EvmEmulatorBytecodeHash: bytes32(0)
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
        IEIP7702Checker eip7702Checker = IEIP7702Checker(Utils.deployEIP7702Checker());
        DummyZKChain zkChain = new DummyZKChain(address(bridgeHub), 270, 6, address(0), eip7702Checker);
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
