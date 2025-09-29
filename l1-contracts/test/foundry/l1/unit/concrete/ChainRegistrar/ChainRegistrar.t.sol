// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ChainRegistrar} from "contracts/chain-registrar/ChainRegistrar.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IL1SharedBridgeLegacy} from "contracts/bridge/interfaces/IL1SharedBridgeLegacy.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";

contract ChainRegistrarTest is Test {
    ChainRegistrar public chainRegistrar;
    ERC1967Proxy public proxy;
    address public mockBridgehub;
    address public mockChainTypeManager;
    address public mockDiamondProxy;
    address public mockAssetRouter;
    address public l2Deployer;
    address public owner;
    address public proposer;

    uint256 public constant CHAIN_ID = 123;
    uint256 public constant PROPOSER_CHAIN_ID = 456;
    address public constant BLOB_OPERATOR = address(0x111);
    address public constant OPERATOR = address(0x222);
    address public constant GOVERNOR = address(0x333);
    address public constant TOKEN_MULTIPLIER_SETTER = address(0x444);
    uint128 public constant GAS_PRICE_MULTIPLIER_NOMINATOR = 1000;
    uint128 public constant GAS_PRICE_MULTIPLIER_DENOMINATOR = 1000;

    TestnetERC20Token public testToken;

    function setUp() public {
        // Create mock addresses
        mockBridgehub = makeAddr("mockBridgehub");
        mockChainTypeManager = makeAddr("mockChainTypeManager");
        mockDiamondProxy = makeAddr("mockDiamondProxy");
        mockAssetRouter = makeAddr("mockAssetRouter");
        l2Deployer = makeAddr("l2Deployer");
        owner = makeAddr("owner");
        proposer = makeAddr("proposer");

        // Deploy test token
        testToken = new TestnetERC20Token("Test Token", "TT", 18);

        // Deploy ChainRegistrar implementation
        ChainRegistrar implementation = new ChainRegistrar();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            ChainRegistrar.initialize.selector,
            mockBridgehub,
            l2Deployer,
            owner
        );
        proxy = new ERC1967Proxy(address(implementation), initData);
        chainRegistrar = ChainRegistrar(address(proxy));

        // Set up mocks
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehub.chainTypeManager.selector, CHAIN_ID),
            abi.encode(address(0)) // Not deployed yet
        );

        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehub.chainTypeManager.selector, PROPOSER_CHAIN_ID),
            abi.encode(mockChainTypeManager) // Already deployed
        );

        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehub.assetRouter.selector),
            abi.encode(mockAssetRouter)
        );

        vm.mockCall(
            mockChainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.getZKChain.selector, CHAIN_ID),
            abi.encode(mockDiamondProxy)
        );

        vm.mockCall(
            mockDiamondProxy,
            abi.encodeWithSelector(IGetters.getPendingAdmin.selector),
            abi.encode(address(0x555))
        );

        vm.mockCall(mockDiamondProxy, abi.encodeWithSelector(IGetters.getAdmin.selector), abi.encode(address(0x666)));

        vm.mockCall(
            mockAssetRouter,
            abi.encodeWithSelector(IL1SharedBridgeLegacy.l2BridgeAddress.selector, CHAIN_ID),
            abi.encode(address(0x777))
        );

        // Give proposer some test tokens
        testToken.mint(proposer, 1000 ether);
    }

    function test_Initialize() public {
        assertEq(address(chainRegistrar.bridgehub()), mockBridgehub);
        assertEq(chainRegistrar.l2Deployer(), l2Deployer);
        assertEq(chainRegistrar.owner(), owner);
    }

    function test_ProposeChainRegistration_ETH() public {
        vm.prank(proposer);
        chainRegistrar.proposeChainRegistration(
            CHAIN_ID,
            PubdataPricingMode.Rollup,
            BLOB_OPERATOR,
            OPERATOR,
            GOVERNOR,
            ETH_TOKEN_ADDRESS,
            TOKEN_MULTIPLIER_SETTER,
            GAS_PRICE_MULTIPLIER_NOMINATOR,
            GAS_PRICE_MULTIPLIER_DENOMINATOR
        );

        // Check that the proposal was stored
        (
            uint256 chainId,
            ChainRegistrar.BaseToken memory baseToken,
            address blobOperator,
            address operator,
            address governor,
            PubdataPricingMode pubdataPricingMode
        ) = chainRegistrar.proposedChains(proposer, CHAIN_ID);
        assertEq(chainId, CHAIN_ID);
        assertEq(blobOperator, BLOB_OPERATOR);
        assertEq(operator, OPERATOR);
        assertEq(governor, GOVERNOR);
        assertEq(uint256(pubdataPricingMode), uint256(PubdataPricingMode.Rollup));
        assertEq(baseToken.tokenAddress, ETH_TOKEN_ADDRESS);
        assertEq(baseToken.tokenMultiplierSetter, TOKEN_MULTIPLIER_SETTER);
        assertEq(baseToken.gasPriceMultiplierNominator, GAS_PRICE_MULTIPLIER_NOMINATOR);
        assertEq(baseToken.gasPriceMultiplierDenominator, GAS_PRICE_MULTIPLIER_DENOMINATOR);
    }

    function test_ProposeChainRegistration_ERC20() public {
        // Calculate exact amount needed
        uint256 amount = (1 ether * GAS_PRICE_MULTIPLIER_NOMINATOR) / GAS_PRICE_MULTIPLIER_DENOMINATOR;

        // Approve tokens for transfer to the ChainRegistrar contract
        vm.prank(proposer);
        testToken.approve(address(chainRegistrar), amount);

        vm.prank(proposer);
        chainRegistrar.proposeChainRegistration(
            CHAIN_ID,
            PubdataPricingMode.Rollup,
            BLOB_OPERATOR,
            OPERATOR,
            GOVERNOR,
            address(testToken),
            TOKEN_MULTIPLIER_SETTER,
            GAS_PRICE_MULTIPLIER_NOMINATOR,
            GAS_PRICE_MULTIPLIER_DENOMINATOR
        );

        // Check that the proposal was stored
        (uint256 chainId, ChainRegistrar.BaseToken memory baseToken, , , , ) = chainRegistrar.proposedChains(
            proposer,
            CHAIN_ID
        );
        assertEq(chainId, CHAIN_ID);
        assertEq(baseToken.tokenAddress, address(testToken));
    }

    function test_ProposeChainRegistration_ERC20_InsufficientBalance() public {
        // Don't approve tokens
        vm.prank(proposer);
        vm.expectRevert();
        chainRegistrar.proposeChainRegistration(
            CHAIN_ID,
            PubdataPricingMode.Rollup,
            BLOB_OPERATOR,
            OPERATOR,
            GOVERNOR,
            address(testToken),
            TOKEN_MULTIPLIER_SETTER,
            GAS_PRICE_MULTIPLIER_NOMINATOR,
            GAS_PRICE_MULTIPLIER_DENOMINATOR
        );
    }

    function test_ProposeChainRegistration_ChainAlreadyDeployed() public {
        vm.expectRevert(abi.encodeWithSelector(ChainRegistrar.ChainIsAlreadyDeployed.selector));
        vm.prank(proposer);
        chainRegistrar.proposeChainRegistration(
            PROPOSER_CHAIN_ID, // This chain is already deployed
            PubdataPricingMode.Rollup,
            BLOB_OPERATOR,
            OPERATOR,
            GOVERNOR,
            ETH_TOKEN_ADDRESS,
            TOKEN_MULTIPLIER_SETTER,
            GAS_PRICE_MULTIPLIER_NOMINATOR,
            GAS_PRICE_MULTIPLIER_DENOMINATOR
        );
    }

    function test_ProposeChainRegistration_ChainAlreadyProposed() public {
        // First proposal
        vm.prank(proposer);
        chainRegistrar.proposeChainRegistration(
            CHAIN_ID,
            PubdataPricingMode.Rollup,
            BLOB_OPERATOR,
            OPERATOR,
            GOVERNOR,
            ETH_TOKEN_ADDRESS,
            TOKEN_MULTIPLIER_SETTER,
            GAS_PRICE_MULTIPLIER_NOMINATOR,
            GAS_PRICE_MULTIPLIER_DENOMINATOR
        );

        // Second proposal should fail
        vm.expectRevert(abi.encodeWithSelector(ChainRegistrar.ChainIsAlreadyProposed.selector));
        vm.prank(proposer);
        chainRegistrar.proposeChainRegistration(
            CHAIN_ID,
            PubdataPricingMode.Rollup,
            BLOB_OPERATOR,
            OPERATOR,
            GOVERNOR,
            ETH_TOKEN_ADDRESS,
            TOKEN_MULTIPLIER_SETTER,
            GAS_PRICE_MULTIPLIER_NOMINATOR,
            GAS_PRICE_MULTIPLIER_DENOMINATOR
        );
    }

    function test_ProposeChainRegistration_Event() public {
        vm.expectEmit(true, false, false, true);
        emit ChainRegistrar.NewChainRegistrationProposal(CHAIN_ID, proposer);

        vm.prank(proposer);
        chainRegistrar.proposeChainRegistration(
            CHAIN_ID,
            PubdataPricingMode.Rollup,
            BLOB_OPERATOR,
            OPERATOR,
            GOVERNOR,
            ETH_TOKEN_ADDRESS,
            TOKEN_MULTIPLIER_SETTER,
            GAS_PRICE_MULTIPLIER_NOMINATOR,
            GAS_PRICE_MULTIPLIER_DENOMINATOR
        );
    }

    function test_ChangeDeployer() public {
        address newDeployer = makeAddr("newDeployer");

        vm.expectEmit(true, false, false, true);
        emit ChainRegistrar.L2DeployerChanged(newDeployer);

        vm.prank(owner);
        chainRegistrar.changeDeployer(newDeployer);

        assertEq(chainRegistrar.l2Deployer(), newDeployer);
    }

    function test_ChangeDeployer_Unauthorized() public {
        address newDeployer = makeAddr("newDeployer");

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(proposer);
        chainRegistrar.changeDeployer(newDeployer);
    }

    function test_GetRegisteredChainConfig() public {
        // Mock the chain as deployed
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehub.chainTypeManager.selector, CHAIN_ID),
            abi.encode(mockChainTypeManager)
        );

        ChainRegistrar.RegisteredChainConfig memory config = chainRegistrar.getRegisteredChainConfig(CHAIN_ID);

        assertEq(config.pendingChainAdmin, address(0x555));
        assertEq(config.chainAdmin, address(0x666));
        assertEq(config.diamondProxy, mockDiamondProxy);
        assertEq(config.l2BridgeAddress, address(0x777));
    }

    function test_GetRegisteredChainConfig_ChainNotDeployed() public {
        uint256 nonExistentChainId = 999;

        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehub.chainTypeManager.selector, nonExistentChainId),
            abi.encode(address(0))
        );

        vm.expectRevert(abi.encodeWithSelector(ChainRegistrar.ChainIsNotYetDeployed.selector));
        chainRegistrar.getRegisteredChainConfig(nonExistentChainId);
    }

    function test_GetRegisteredChainConfig_BridgeNotRegistered() public {
        // Mock the chain as deployed
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehub.chainTypeManager.selector, CHAIN_ID),
            abi.encode(mockChainTypeManager)
        );

        vm.mockCall(
            mockAssetRouter,
            abi.encodeWithSelector(IL1SharedBridgeLegacy.l2BridgeAddress.selector, CHAIN_ID),
            abi.encode(address(0)) // No bridge registered
        );

        vm.expectRevert(abi.encodeWithSelector(ChainRegistrar.BridgeIsNotRegistered.selector));
        chainRegistrar.getRegisteredChainConfig(CHAIN_ID);
    }

    function test_ProposeChainRegistration_ValidiumMode() public {
        vm.prank(proposer);
        chainRegistrar.proposeChainRegistration(
            CHAIN_ID,
            PubdataPricingMode.Validium,
            BLOB_OPERATOR,
            OPERATOR,
            GOVERNOR,
            ETH_TOKEN_ADDRESS,
            TOKEN_MULTIPLIER_SETTER,
            GAS_PRICE_MULTIPLIER_NOMINATOR,
            GAS_PRICE_MULTIPLIER_DENOMINATOR
        );

        (uint256 chainId, , , , , PubdataPricingMode pubdataPricingMode) = chainRegistrar.proposedChains(
            proposer,
            CHAIN_ID
        );
        assertEq(chainId, CHAIN_ID);
        assertEq(uint256(pubdataPricingMode), uint256(PubdataPricingMode.Validium));
    }

    function test_ProposeChainRegistration_DifferentGasMultipliers() public {
        uint128 nominator = 2000;
        uint128 denominator = 1000;

        vm.prank(proposer);
        chainRegistrar.proposeChainRegistration(
            CHAIN_ID,
            PubdataPricingMode.Rollup,
            BLOB_OPERATOR,
            OPERATOR,
            GOVERNOR,
            ETH_TOKEN_ADDRESS,
            TOKEN_MULTIPLIER_SETTER,
            nominator,
            denominator
        );

        (uint256 chainId, ChainRegistrar.BaseToken memory baseToken, , , , ) = chainRegistrar.proposedChains(
            proposer,
            CHAIN_ID
        );
        assertEq(chainId, CHAIN_ID);
        assertEq(baseToken.gasPriceMultiplierNominator, nominator);
        assertEq(baseToken.gasPriceMultiplierDenominator, denominator);
    }

    function test_ProposeChainRegistration_ZeroAddresses() public {
        vm.prank(proposer);
        chainRegistrar.proposeChainRegistration(
            CHAIN_ID,
            PubdataPricingMode.Rollup,
            address(0), // Zero blob operator
            address(0), // Zero operator
            address(0), // Zero governor
            ETH_TOKEN_ADDRESS,
            address(0), // Zero token multiplier setter
            GAS_PRICE_MULTIPLIER_NOMINATOR,
            GAS_PRICE_MULTIPLIER_DENOMINATOR
        );

        (
            uint256 chainId,
            ChainRegistrar.BaseToken memory baseToken,
            address blobOperator,
            address operator,
            address governor,

        ) = chainRegistrar.proposedChains(proposer, CHAIN_ID);
        assertEq(chainId, CHAIN_ID);
        assertEq(blobOperator, address(0));
        assertEq(operator, address(0));
        assertEq(governor, address(0));
        assertEq(baseToken.tokenMultiplierSetter, address(0));
    }

    function test_ProposeChainRegistration_ERC20_ExactAmount() public {
        // Calculate exact amount needed
        uint256 amount = (1 ether * GAS_PRICE_MULTIPLIER_NOMINATOR) / GAS_PRICE_MULTIPLIER_DENOMINATOR;

        // Approve exact amount to the ChainRegistrar contract
        vm.prank(proposer);
        testToken.approve(address(chainRegistrar), amount);

        vm.prank(proposer);
        chainRegistrar.proposeChainRegistration(
            CHAIN_ID,
            PubdataPricingMode.Rollup,
            BLOB_OPERATOR,
            OPERATOR,
            GOVERNOR,
            address(testToken),
            TOKEN_MULTIPLIER_SETTER,
            GAS_PRICE_MULTIPLIER_NOMINATOR,
            GAS_PRICE_MULTIPLIER_DENOMINATOR
        );

        // Check that the proposal was stored
        (uint256 chainId, , , , , ) = chainRegistrar.proposedChains(proposer, CHAIN_ID);
        assertEq(chainId, CHAIN_ID);
    }

    function test_ProposeChainRegistration_ERC20_MoreThanNeeded() public {
        // Calculate exact amount needed
        uint256 amount = (1 ether * GAS_PRICE_MULTIPLIER_NOMINATOR) / GAS_PRICE_MULTIPLIER_DENOMINATOR;

        // Approve more than needed to the ChainRegistrar contract
        vm.prank(proposer);
        testToken.approve(address(chainRegistrar), amount * 2);

        vm.prank(proposer);
        chainRegistrar.proposeChainRegistration(
            CHAIN_ID,
            PubdataPricingMode.Rollup,
            BLOB_OPERATOR,
            OPERATOR,
            GOVERNOR,
            address(testToken),
            TOKEN_MULTIPLIER_SETTER,
            GAS_PRICE_MULTIPLIER_NOMINATOR,
            GAS_PRICE_MULTIPLIER_DENOMINATOR
        );

        // Check that the proposal was stored
        (uint256 chainId, , , , , ) = chainRegistrar.proposedChains(proposer, CHAIN_ID);
        assertEq(chainId, CHAIN_ID);
    }

    function test_ProposeChainRegistration_ERC20_AlreadyHasBalance() public {
        // Give l2Deployer some tokens
        testToken.mint(l2Deployer, 1 ether);

        vm.prank(proposer);
        chainRegistrar.proposeChainRegistration(
            CHAIN_ID,
            PubdataPricingMode.Rollup,
            BLOB_OPERATOR,
            OPERATOR,
            GOVERNOR,
            address(testToken),
            TOKEN_MULTIPLIER_SETTER,
            GAS_PRICE_MULTIPLIER_NOMINATOR,
            GAS_PRICE_MULTIPLIER_DENOMINATOR
        );

        // Check that the proposal was stored
        (uint256 chainId, , , , , ) = chainRegistrar.proposedChains(proposer, CHAIN_ID);
        assertEq(chainId, CHAIN_ID);
    }

    function test_ProposeChainRegistration_MultipleProposers() public {
        address proposer2 = makeAddr("proposer2");

        // Mock the second chain ID as not deployed
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehub.chainTypeManager.selector, CHAIN_ID + 1),
            abi.encode(address(0))
        );

        // First proposer
        vm.prank(proposer);
        chainRegistrar.proposeChainRegistration(
            CHAIN_ID,
            PubdataPricingMode.Rollup,
            BLOB_OPERATOR,
            OPERATOR,
            GOVERNOR,
            ETH_TOKEN_ADDRESS,
            TOKEN_MULTIPLIER_SETTER,
            GAS_PRICE_MULTIPLIER_NOMINATOR,
            GAS_PRICE_MULTIPLIER_DENOMINATOR
        );

        // Second proposer with different chain ID
        vm.prank(proposer2);
        chainRegistrar.proposeChainRegistration(
            CHAIN_ID + 1,
            PubdataPricingMode.Validium,
            address(0x888),
            address(0x999),
            address(0xAAA),
            ETH_TOKEN_ADDRESS,
            address(0xBBB),
            GAS_PRICE_MULTIPLIER_NOMINATOR,
            GAS_PRICE_MULTIPLIER_DENOMINATOR
        );

        // Check both proposals
        (uint256 chainId1, , , , , PubdataPricingMode pubdataPricingMode1) = chainRegistrar.proposedChains(
            proposer,
            CHAIN_ID
        );
        (uint256 chainId2, , , , , PubdataPricingMode pubdataPricingMode2) = chainRegistrar.proposedChains(
            proposer2,
            CHAIN_ID + 1
        );

        assertEq(chainId1, CHAIN_ID);
        assertEq(chainId2, CHAIN_ID + 1);
        assertEq(uint256(pubdataPricingMode1), uint256(PubdataPricingMode.Rollup));
        assertEq(uint256(pubdataPricingMode2), uint256(PubdataPricingMode.Validium));
    }
}
