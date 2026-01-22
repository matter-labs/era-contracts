// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {ChainRegistrar} from "contracts/chain-registrar/ChainRegistrar.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

/// @notice Mock bridgehub for testing
contract MockBridgehub {
    mapping(uint256 => address) public chainTypeManagers;
    address public assetRouterAddr;

    function chainTypeManager(uint256 _chainId) external view returns (address) {
        return chainTypeManagers[_chainId];
    }

    function setChainTypeManager(uint256 _chainId, address _ctm) external {
        chainTypeManagers[_chainId] = _ctm;
    }

    function assetRouter() external view returns (address) {
        return assetRouterAddr;
    }

    function setAssetRouter(address _assetRouter) external {
        assetRouterAddr = _assetRouter;
    }
}

/// @notice Mock ERC20 token for testing
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function setBalance(address _account, uint256 _balance) external {
        balanceOf[_account] = _balance;
    }

    function approve(address _spender, uint256 _amount) external returns (bool) {
        allowance[msg.sender][_spender] = _amount;
        return true;
    }

    function transferFrom(address _from, address _to, uint256 _amount) external returns (bool) {
        require(allowance[_from][msg.sender] >= _amount, "Insufficient allowance");
        require(balanceOf[_from] >= _amount, "Insufficient balance");
        allowance[_from][msg.sender] -= _amount;
        balanceOf[_from] -= _amount;
        balanceOf[_to] += _amount;
        return true;
    }
}

/// @notice Unit tests for ChainRegistrar
contract ChainRegistrarTest is Test {
    ChainRegistrar public chainRegistrar;
    MockBridgehub public bridgehub;
    MockERC20 public mockToken;

    address public owner = makeAddr("owner");
    address public l2Deployer = makeAddr("l2Deployer");
    address public admin = makeAddr("admin");
    address public user = makeAddr("user");

    uint256 public testChainId = 12345;

    event NewChainRegistrationProposal(uint256 indexed chainId, address author);
    event L2DeployerChanged(address newDeployer);

    function setUp() public {
        bridgehub = new MockBridgehub();
        mockToken = new MockERC20();

        ChainRegistrar implementation = new ChainRegistrar();

        chainRegistrar = ChainRegistrar(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    admin,
                    abi.encodeCall(ChainRegistrar.initialize, (address(bridgehub), l2Deployer, owner))
                )
            )
        );
    }

    // ============ Initialize Tests ============

    function test_initialize_setsBridgehub() public view {
        assertEq(address(chainRegistrar.bridgehub()), address(bridgehub));
    }

    function test_initialize_setsL2Deployer() public view {
        assertEq(chainRegistrar.l2Deployer(), l2Deployer);
    }

    function test_initialize_setsOwner() public view {
        assertEq(chainRegistrar.owner(), owner);
    }

    // ============ proposeChainRegistration Tests ============

    function test_proposeChainRegistration_succeedsForEthBasedChain() public {
        vm.prank(user);

        vm.expectEmit(true, false, false, true);
        emit NewChainRegistrationProposal(testChainId, user);

        chainRegistrar.proposeChainRegistration({
            _chainId: testChainId,
            _pubdataPricingMode: PubdataPricingMode.Rollup,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("tokenMultiplierSetter"),
            _gasPriceMultiplierNominator: 1,
            _gasPriceMultiplierDenominator: 1
        });

        (
            uint256 chainId,
            ChainRegistrar.BaseToken memory baseToken,
            address blobOperator,
            address operator,
            address governor,
            PubdataPricingMode pubdataPricingMode
        ) = chainRegistrar.proposedChains(user, testChainId);

        assertEq(chainId, testChainId);
        assertEq(baseToken.tokenAddress, ETH_TOKEN_ADDRESS);
        assertTrue(blobOperator != address(0));
        assertTrue(operator != address(0));
        assertTrue(governor != address(0));
        assertEq(uint8(pubdataPricingMode), uint8(PubdataPricingMode.Rollup));
    }

    function test_proposeChainRegistration_revertsIfChainAlreadyDeployed() public {
        // Set the chain as already deployed
        bridgehub.setChainTypeManager(testChainId, makeAddr("ctm"));

        vm.prank(user);
        vm.expectRevert(ChainRegistrar.ChainIsAlreadyDeployed.selector);
        chainRegistrar.proposeChainRegistration({
            _chainId: testChainId,
            _pubdataPricingMode: PubdataPricingMode.Rollup,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("tokenMultiplierSetter"),
            _gasPriceMultiplierNominator: 1,
            _gasPriceMultiplierDenominator: 1
        });
    }

    function test_proposeChainRegistration_revertsIfChainAlreadyProposed() public {
        // First proposal
        vm.prank(user);
        chainRegistrar.proposeChainRegistration({
            _chainId: testChainId,
            _pubdataPricingMode: PubdataPricingMode.Rollup,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("tokenMultiplierSetter"),
            _gasPriceMultiplierNominator: 1,
            _gasPriceMultiplierDenominator: 1
        });

        // Second proposal should fail
        vm.prank(user);
        vm.expectRevert(ChainRegistrar.ChainIsAlreadyProposed.selector);
        chainRegistrar.proposeChainRegistration({
            _chainId: testChainId,
            _pubdataPricingMode: PubdataPricingMode.Validium,
            _blobOperator: makeAddr("blobOperator2"),
            _operator: makeAddr("operator2"),
            _governor: makeAddr("governor2"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("tokenMultiplierSetter2"),
            _gasPriceMultiplierNominator: 2,
            _gasPriceMultiplierDenominator: 1
        });
    }

    function test_proposeChainRegistration_transfersBaseTokenIfNeeded() public {
        uint128 nominator = 2;
        uint128 denominator = 1;
        uint256 expectedAmount = (1 ether * nominator) / denominator;

        // Give user some tokens and approve
        mockToken.setBalance(user, expectedAmount * 2);

        vm.startPrank(user);
        mockToken.approve(address(chainRegistrar), expectedAmount);

        chainRegistrar.proposeChainRegistration({
            _chainId: testChainId,
            _pubdataPricingMode: PubdataPricingMode.Rollup,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: address(mockToken),
            _tokenMultiplierSetter: makeAddr("tokenMultiplierSetter"),
            _gasPriceMultiplierNominator: nominator,
            _gasPriceMultiplierDenominator: denominator
        });
        vm.stopPrank();

        assertEq(mockToken.balanceOf(l2Deployer), expectedAmount);
    }

    function test_proposeChainRegistration_skipsTransferIfL2DeployerHasEnoughTokens() public {
        uint128 nominator = 2;
        uint128 denominator = 1;
        uint256 expectedAmount = (1 ether * nominator) / denominator;

        // Give l2Deployer enough tokens already
        mockToken.setBalance(l2Deployer, expectedAmount);

        vm.prank(user);
        chainRegistrar.proposeChainRegistration({
            _chainId: testChainId,
            _pubdataPricingMode: PubdataPricingMode.Rollup,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: address(mockToken),
            _tokenMultiplierSetter: makeAddr("tokenMultiplierSetter"),
            _gasPriceMultiplierNominator: nominator,
            _gasPriceMultiplierDenominator: denominator
        });

        // Balance should remain unchanged
        assertEq(mockToken.balanceOf(l2Deployer), expectedAmount);
    }

    // ============ changeDeployer Tests ============

    function test_changeDeployer_succeedsAsOwner() public {
        address newDeployer = makeAddr("newDeployer");

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit L2DeployerChanged(newDeployer);
        chainRegistrar.changeDeployer(newDeployer);

        assertEq(chainRegistrar.l2Deployer(), newDeployer);
    }

    function test_changeDeployer_revertsIfNotOwner() public {
        address newDeployer = makeAddr("newDeployer");

        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        chainRegistrar.changeDeployer(newDeployer);
    }

    // ============ getRegisteredChainConfig Tests ============

    function test_getRegisteredChainConfig_revertsIfChainNotDeployed() public {
        vm.expectRevert(ChainRegistrar.ChainIsNotYetDeployed.selector);
        chainRegistrar.getRegisteredChainConfig(testChainId);
    }

    function test_getRegisteredChainConfig_revertsIfBridgeNotRegistered() public {
        // Set up chain as deployed
        address ctm = makeAddr("ctm");
        address diamondProxy = makeAddr("diamondProxy");
        address assetRouter = makeAddr("assetRouter");

        bridgehub.setChainTypeManager(testChainId, ctm);
        bridgehub.setAssetRouter(assetRouter);

        // Mock CTM to return diamondProxy
        vm.mockCall(ctm, abi.encodeWithSignature("getZKChain(uint256)", testChainId), abi.encode(diamondProxy));

        // Mock getters on diamondProxy
        vm.mockCall(diamondProxy, abi.encodeWithSignature("getPendingAdmin()"), abi.encode(makeAddr("pendingAdmin")));
        vm.mockCall(diamondProxy, abi.encodeWithSignature("getAdmin()"), abi.encode(makeAddr("admin")));

        // Mock assetRouter.l2BridgeAddress to return address(0)
        vm.mockCall(
            assetRouter,
            abi.encodeWithSignature("l2BridgeAddress(uint256)", testChainId),
            abi.encode(address(0))
        );

        vm.expectRevert(ChainRegistrar.BridgeIsNotRegistered.selector);
        chainRegistrar.getRegisteredChainConfig(testChainId);
    }

    function test_getRegisteredChainConfig_succeedsWhenFullyRegistered() public {
        // Set up chain as deployed
        address ctm = makeAddr("ctm");
        address diamondProxy = makeAddr("diamondProxy");
        address assetRouter = makeAddr("assetRouter");
        address pendingAdmin = makeAddr("pendingAdmin");
        address chainAdmin = makeAddr("chainAdmin");
        address l2Bridge = makeAddr("l2Bridge");

        bridgehub.setChainTypeManager(testChainId, ctm);
        bridgehub.setAssetRouter(assetRouter);

        // Mock CTM to return diamondProxy
        vm.mockCall(ctm, abi.encodeWithSignature("getZKChain(uint256)", testChainId), abi.encode(diamondProxy));

        // Mock getters on diamondProxy
        vm.mockCall(diamondProxy, abi.encodeWithSignature("getPendingAdmin()"), abi.encode(pendingAdmin));
        vm.mockCall(diamondProxy, abi.encodeWithSignature("getAdmin()"), abi.encode(chainAdmin));

        // Mock assetRouter.l2BridgeAddress to return l2Bridge
        vm.mockCall(
            assetRouter,
            abi.encodeWithSignature("l2BridgeAddress(uint256)", testChainId),
            abi.encode(l2Bridge)
        );

        ChainRegistrar.RegisteredChainConfig memory config = chainRegistrar.getRegisteredChainConfig(testChainId);

        assertEq(config.pendingChainAdmin, pendingAdmin);
        assertEq(config.chainAdmin, chainAdmin);
        assertEq(config.diamondProxy, diamondProxy);
        assertEq(config.l2BridgeAddress, l2Bridge);
    }

    // ============ Fuzz Tests ============

    function testFuzz_proposeChainRegistration_withDifferentChainIds(uint256 _chainId) public {
        vm.assume(_chainId != 0);

        vm.prank(user);
        chainRegistrar.proposeChainRegistration({
            _chainId: _chainId,
            _pubdataPricingMode: PubdataPricingMode.Rollup,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("tokenMultiplierSetter"),
            _gasPriceMultiplierNominator: 1,
            _gasPriceMultiplierDenominator: 1
        });

        (uint256 chainId, , , , , ) = chainRegistrar.proposedChains(user, _chainId);
        assertEq(chainId, _chainId);
    }

    function testFuzz_proposeChainRegistration_withDifferentGasMultipliers(
        uint128 _nominator,
        uint128 _denominator
    ) public {
        vm.assume(_denominator > 0);
        vm.assume(_nominator > 0);

        vm.prank(user);
        chainRegistrar.proposeChainRegistration({
            _chainId: testChainId,
            _pubdataPricingMode: PubdataPricingMode.Rollup,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("tokenMultiplierSetter"),
            _gasPriceMultiplierNominator: _nominator,
            _gasPriceMultiplierDenominator: _denominator
        });

        (, ChainRegistrar.BaseToken memory baseToken, , , , ) = chainRegistrar.proposedChains(user, testChainId);
        assertEq(baseToken.gasPriceMultiplierNominator, _nominator);
        assertEq(baseToken.gasPriceMultiplierDenominator, _denominator);
    }

    function testFuzz_changeDeployer(address _newDeployer) public {
        vm.prank(owner);
        chainRegistrar.changeDeployer(_newDeployer);
        assertEq(chainRegistrar.l2Deployer(), _newDeployer);
    }

    // ============ PubdataPricingMode Tests ============

    function test_proposeChainRegistration_withValidiumMode() public {
        vm.prank(user);
        chainRegistrar.proposeChainRegistration({
            _chainId: testChainId,
            _pubdataPricingMode: PubdataPricingMode.Validium,
            _blobOperator: makeAddr("blobOperator"),
            _operator: makeAddr("operator"),
            _governor: makeAddr("governor"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("tokenMultiplierSetter"),
            _gasPriceMultiplierNominator: 1,
            _gasPriceMultiplierDenominator: 1
        });

        (, , , , , PubdataPricingMode pubdataPricingMode) = chainRegistrar.proposedChains(user, testChainId);
        assertEq(uint8(pubdataPricingMode), uint8(PubdataPricingMode.Validium));
    }

    // ============ Multiple Proposers Tests ============

    function test_proposeChainRegistration_differentUsersCanProposeSameChainId() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // User1 proposes
        vm.prank(user1);
        chainRegistrar.proposeChainRegistration({
            _chainId: testChainId,
            _pubdataPricingMode: PubdataPricingMode.Rollup,
            _blobOperator: makeAddr("blobOperator1"),
            _operator: makeAddr("operator1"),
            _governor: makeAddr("governor1"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("tokenMultiplierSetter1"),
            _gasPriceMultiplierNominator: 1,
            _gasPriceMultiplierDenominator: 1
        });

        // User2 proposes same chain ID - should succeed (different proposer)
        vm.prank(user2);
        chainRegistrar.proposeChainRegistration({
            _chainId: testChainId,
            _pubdataPricingMode: PubdataPricingMode.Validium,
            _blobOperator: makeAddr("blobOperator2"),
            _operator: makeAddr("operator2"),
            _governor: makeAddr("governor2"),
            _baseTokenAddress: ETH_TOKEN_ADDRESS,
            _tokenMultiplierSetter: makeAddr("tokenMultiplierSetter2"),
            _gasPriceMultiplierNominator: 2,
            _gasPriceMultiplierDenominator: 1
        });

        // Verify both proposals exist
        (uint256 chainId1, , , , , ) = chainRegistrar.proposedChains(user1, testChainId);
        (uint256 chainId2, , , , , ) = chainRegistrar.proposedChains(user2, testChainId);

        assertEq(chainId1, testChainId);
        assertEq(chainId2, testChainId);
    }
}
