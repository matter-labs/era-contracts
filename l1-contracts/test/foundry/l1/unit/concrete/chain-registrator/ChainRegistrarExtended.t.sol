// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {DummyChainTypeManagerWBH} from "contracts/dev-contracts/test/DummyChainTypeManagerWithBridgeHubAddress.sol";
import {IVerifier, VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";

import {InteropCenter} from "contracts/interop/InteropCenter.sol";
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

/// @title Extended tests for ChainRegistrar to increase coverage
contract ChainRegistrarExtendedTest is Test {
    DummyBridgehub private bridgeHub;
    InteropCenter private interopCenter;
    L1MessageRoot private messageRoot;
    DummyChainTypeManagerWBH private ctm;
    address private admin;
    address private proxyAdmin;
    address private deployer;
    ChainRegistrar private chainRegistrar;
    L1AssetRouter private assetRouter;
    bytes diamondCutData;
    bytes initCalldata;
    L1Nullifier l1NullifierImpl;
    IEIP7702Checker private eip7702Checker;

    function setUp() public {
        bridgeHub = new DummyBridgehub();
        interopCenter = new InteropCenter();
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        interopCenter.initL2(block.chainid, makeAddr("interopAdmin"));
        messageRoot = new L1MessageRoot(address(bridgeHub), 1);
        ctm = new DummyChainTypeManagerWBH(address(bridgeHub));
        admin = makeAddr("admin");
        proxyAdmin = makeAddr("proxyAdmin");
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
            proxyAdmin,
            abi.encodeCall(ChainRegistrar.initialize, (address(bridgeHub), deployer, admin))
        );
        chainRegistrar = ChainRegistrar(address(chainRegistrarProxy));

        // Deploy EIP7702Checker once for all tests to avoid CREATE2 address conflicts
        eip7702Checker = IEIP7702Checker(Utils.deployEIP7702Checker());

        // Mock bridgehub.chainTypeManager to return address(0) by default (chain not deployed)
        // Individual tests can override this for specific chain IDs
        vm.mockCall(
            address(bridgeHub),
            abi.encodeWithSelector(IBridgehubBase.chainTypeManager.selector),
            abi.encode(address(0))
        );

        // Mock bridgehub.assetRouter to return the asset router address
        vm.mockCall(
            address(bridgeHub),
            abi.encodeWithSelector(IBridgehubBase.assetRouter.selector),
            abi.encode(address(assetRouter))
        );
    }

    function test_Initialize_SetsBridgehub() public view {
        assertEq(address(chainRegistrar.bridgehub()), address(bridgeHub));
    }

    function test_Initialize_SetsL2Deployer() public view {
        assertEq(chainRegistrar.l2Deployer(), deployer);
    }

    function test_ChangeDeployer_Success() public {
        address newDeployer = makeAddr("newDeployer");

        vm.prank(admin);
        chainRegistrar.changeDeployer(newDeployer);

        assertEq(chainRegistrar.l2Deployer(), newDeployer);
    }

    function test_ChangeDeployer_EmitsEvent() public {
        address newDeployer = makeAddr("newDeployer");

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit ChainRegistrar.L2DeployerChanged(newDeployer);
        chainRegistrar.changeDeployer(newDeployer);
    }

    function test_ChangeDeployer_OnlyOwner() public {
        address newDeployer = makeAddr("newDeployer");
        address randomUser = makeAddr("randomUser");

        vm.prank(randomUser);
        vm.expectRevert("Ownable: caller is not the owner");
        chainRegistrar.changeDeployer(newDeployer);
    }

    function test_ChainIsAlreadyDeployed() public {
        address author = makeAddr("author");

        // First set up the chain as deployed in CTM
        DummyZKChain zkChain = new DummyZKChain(
            address(bridgeHub),
            270,
            block.chainid,
            address(assetRouter),
            eip7702Checker
        );
        vm.prank(admin);
        ctm.setZKChain(999, address(zkChain));

        // Mock chainTypeManager to return a non-zero address for chainId 999
        vm.mockCall(
            address(bridgeHub),
            abi.encodeWithSelector(IBridgehubBase.chainTypeManager.selector, 999),
            abi.encode(address(ctm))
        );

        vm.prank(author);
        vm.expectRevert(ChainRegistrar.ChainIsAlreadyDeployed.selector);
        chainRegistrar.proposeChainRegistration({
            _chainId: 999,
            _pubdataPricingMode: PubdataPricingMode.Validium,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("setter"),
            _gasPriceMultiplierNominator: 1,
            _gasPriceMultiplierDenominator: 1
        });
    }

    function test_GetRegisteredChainConfig_ChainNotDeployed() public {
        vm.expectRevert(ChainRegistrar.ChainIsNotYetDeployed.selector);
        chainRegistrar.getRegisteredChainConfig(12345);
    }

    function test_GetRegisteredChainConfig_BridgeNotRegistered() public {
        uint256 chainId = 999;

        // Set up chain in CTM
        DummyZKChain zkChain = new DummyZKChain(
            address(bridgeHub),
            270,
            block.chainid,
            address(assetRouter),
            eip7702Checker
        );
        vm.prank(admin);
        ctm.setZKChain(chainId, address(zkChain));

        // Also set in bridgehub since ctm.getZKChain delegates to bridgehub
        bridgeHub.setZKChain(chainId, address(zkChain));

        // Mock chainTypeManager call
        vm.mockCall(
            address(bridgeHub),
            abi.encodeWithSelector(IBridgehubBase.chainTypeManager.selector, chainId),
            abi.encode(address(ctm))
        );

        // Mock the IGetters methods that chainRegistrar will call on zkChain
        vm.mockCall(
            address(zkChain),
            abi.encodeWithSelector(IGetters.getPendingAdmin.selector),
            abi.encode(makeAddr("pendingAdmin"))
        );
        vm.mockCall(
            address(zkChain),
            abi.encodeWithSelector(IGetters.getAdmin.selector),
            abi.encode(makeAddr("chainAdmin"))
        );

        // Now L2 bridge address will be 0 because no governance was initialized
        // Need to mock the l2BridgeAddress call to return 0
        vm.mockCall(
            address(assetRouter),
            abi.encodeWithSelector(IL1SharedBridgeLegacy.l2BridgeAddress.selector, chainId),
            abi.encode(address(0))
        );

        vm.expectRevert(ChainRegistrar.BridgeIsNotRegistered.selector);
        chainRegistrar.getRegisteredChainConfig(chainId);
    }

    function test_ProposeChainRegistration_EmitsEvent() public {
        address author = makeAddr("author");
        uint256 chainId = 42;

        vm.prank(author);
        vm.expectEmit(true, true, true, true);
        emit ChainRegistrar.NewChainRegistrationProposal(chainId, author);
        chainRegistrar.proposeChainRegistration({
            _chainId: chainId,
            _pubdataPricingMode: PubdataPricingMode.Validium,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("setter"),
            _gasPriceMultiplierNominator: 1,
            _gasPriceMultiplierDenominator: 1
        });
    }

    function test_ProposeChainRegistration_RollupMode() public {
        address author = makeAddr("author");
        uint256 chainId = 100;

        vm.prank(author);
        chainRegistrar.proposeChainRegistration({
            _chainId: chainId,
            _pubdataPricingMode: PubdataPricingMode.Rollup,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("setter"),
            _gasPriceMultiplierNominator: 1,
            _gasPriceMultiplierDenominator: 1
        });

        (uint256 proposedChainId, , , , , PubdataPricingMode mode) = chainRegistrar.proposedChains(author, chainId);

        assertEq(proposedChainId, chainId);
        assertEq(uint8(mode), uint8(PubdataPricingMode.Rollup));
    }

    function test_ProposedChainsMapping() public {
        address author = makeAddr("author");
        uint256 chainId = 555;
        address blobOperator = makeAddr("blobOperator");
        address operator = makeAddr("operator");
        address governor = makeAddr("governor");
        address tokenMultiplierSetter = makeAddr("setter");

        vm.prank(author);
        chainRegistrar.proposeChainRegistration({
            _chainId: chainId,
            _pubdataPricingMode: PubdataPricingMode.Validium,
            _blobOperator: blobOperator,
            _operator: operator,
            _governor: governor,
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: tokenMultiplierSetter,
            _gasPriceMultiplierNominator: 5,
            _gasPriceMultiplierDenominator: 2
        });

        (
            uint256 proposedChainId,
            ChainRegistrar.BaseToken memory baseToken,
            address returnedBlobOperator,
            address returnedOperator,
            address returnedGovernor,
            PubdataPricingMode mode
        ) = chainRegistrar.proposedChains(author, chainId);

        assertEq(proposedChainId, chainId);
        assertEq(baseToken.tokenAddress, ETH_TOKEN_ADDRESS);
        assertEq(baseToken.tokenMultiplierSetter, tokenMultiplierSetter);
        assertEq(baseToken.gasPriceMultiplierNominator, 5);
        assertEq(baseToken.gasPriceMultiplierDenominator, 2);
        assertEq(returnedBlobOperator, blobOperator);
        assertEq(returnedOperator, operator);
        assertEq(returnedGovernor, governor);
        assertEq(uint8(mode), uint8(PubdataPricingMode.Validium));
    }

    function test_MultipleProposalsByDifferentAuthors() public {
        address author1 = makeAddr("author1");
        address author2 = makeAddr("author2");
        uint256 chainId = 777;

        // Author 1 proposes
        vm.prank(author1);
        chainRegistrar.proposeChainRegistration({
            _chainId: chainId,
            _pubdataPricingMode: PubdataPricingMode.Validium,
            _blobOperator: makeAddr("blobOperator1"),
            _operator: makeAddr("operator1"),
            _governor: makeAddr("governor1"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("setter1"),
            _gasPriceMultiplierNominator: 1,
            _gasPriceMultiplierDenominator: 1
        });

        // Author 2 can propose the same chainId
        vm.prank(author2);
        chainRegistrar.proposeChainRegistration({
            _chainId: chainId,
            _pubdataPricingMode: PubdataPricingMode.Rollup,
            _blobOperator: makeAddr("blobOperator2"),
            _operator: makeAddr("operator2"),
            _governor: makeAddr("governor2"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("setter2"),
            _gasPriceMultiplierNominator: 2,
            _gasPriceMultiplierDenominator: 1
        });

        // Verify both proposals exist
        (uint256 chainId1, , , , , ) = chainRegistrar.proposedChains(author1, chainId);
        (uint256 chainId2, , , , , ) = chainRegistrar.proposedChains(author2, chainId);

        assertEq(chainId1, chainId);
        assertEq(chainId2, chainId);
    }

    function test_ProposeChainWithCustomBaseToken_TransferFromSender() public {
        address author = makeAddr("author");
        TestnetERC20Token token = new TestnetERC20Token("Custom", "CTM", 18);
        token.mint(author, 1000 ether);

        vm.startPrank(author);
        token.approve(address(chainRegistrar), 100 ether);

        uint256 initialBalance = token.balanceOf(deployer);

        chainRegistrar.proposeChainRegistration({
            _chainId: 888,
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

        // Token transfer should have occurred
        assertTrue(token.balanceOf(deployer) > initialBalance);
    }

    function testFuzz_ProposeChainRegistration(uint256 chainId, uint128 nominator, uint128 denominator) public {
        vm.assume(chainId != 0);
        vm.assume(denominator != 0);
        vm.assume(nominator <= 1000);

        address author = makeAddr("fuzzAuthor");

        vm.prank(author);
        chainRegistrar.proposeChainRegistration({
            _chainId: chainId,
            _pubdataPricingMode: PubdataPricingMode.Validium,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("setter"),
            _gasPriceMultiplierNominator: nominator,
            _gasPriceMultiplierDenominator: denominator
        });

        (uint256 proposedId, , , , , ) = chainRegistrar.proposedChains(author, chainId);
        assertEq(proposedId, chainId);
    }
}
