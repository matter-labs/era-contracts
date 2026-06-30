// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20} from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";

import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";

import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";

import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";

import {AddressAlreadySet, DepositExists, Unauthorized, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {NativeTokenVaultAlreadySet} from "contracts/bridge/L1BridgeContractErrors.sol";

contract TestERC20 is ERC20 {
    constructor() ERC20("Test Token", "TEST") {
        _mint(msg.sender, 1_000_000 * 10 ** decimals());
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract L1NullifierTest is Test {
    using stdStorage for StdStorage;

    L1Nullifier public l1Nullifier;
    L1NullifierDev public l1NullifierImpl;

    address public owner;
    address public proxyAdmin;
    address public bridgehub;
    address public messageRoot;
    address public interopCenter;
    address public assetRouter;
    address public nativeTokenVault;

    uint256 public constant ERA_CHAIN_ID = 9;
    address public eraDiamondProxy;

    TestERC20 public token;

    function setUp() public {
        owner = makeAddr("owner");
        proxyAdmin = makeAddr("proxyAdmin");
        bridgehub = makeAddr("bridgehub");
        messageRoot = makeAddr("messageRoot");
        interopCenter = makeAddr("interopCenter");
        assetRouter = makeAddr("assetRouter");
        nativeTokenVault = makeAddr("nativeTokenVault");
        eraDiamondProxy = makeAddr("eraDiamondProxy");

        token = new TestERC20();

        l1NullifierImpl = new L1NullifierDev({
            _bridgehub: IL1Bridgehub(bridgehub),
            _messageRoot: IMessageRootBase(messageRoot),
            _eraChainId: ERA_CHAIN_ID,
            _eraDiamondProxy: eraDiamondProxy
        });

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(l1NullifierImpl),
            proxyAdmin,
            abi.encodeWithSelector(L1Nullifier.initialize.selector, owner, 1, 1, 1, 0)
        );

        l1Nullifier = L1Nullifier(payable(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialize_SetsOwner() public view {
        assertEq(l1Nullifier.owner(), owner);
    }

    function test_Initialize_RevertWhen_OwnerIsZeroAddress() public {
        L1NullifierDev impl = new L1NullifierDev({
            _bridgehub: IL1Bridgehub(bridgehub),
            _messageRoot: IMessageRootBase(messageRoot),
            _eraChainId: ERA_CHAIN_ID,
            _eraDiamondProxy: eraDiamondProxy
        });

        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            proxyAdmin,
            abi.encodeWithSelector(L1Nullifier.initialize.selector, address(0), 1, 1, 1, 0)
        );
    }

    function test_BRIDGE_HUB() public view {
        assertEq(address(l1Nullifier.BRIDGE_HUB()), bridgehub);
    }

    function test_MESSAGE_ROOT() public view {
        assertEq(address(l1Nullifier.MESSAGE_ROOT()), messageRoot);
    }

    /*//////////////////////////////////////////////////////////////
                            SETTER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetL1NativeTokenVault_Success() public {
        vm.prank(owner);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(nativeTokenVault));
        assertEq(address(l1Nullifier.l1NativeTokenVault()), nativeTokenVault);
    }

    function test_SetL1NativeTokenVault_RevertWhen_NotOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(nativeTokenVault));
    }

    function test_SetL1NativeTokenVault_RevertWhen_AlreadySet() public {
        vm.prank(owner);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(nativeTokenVault));

        vm.prank(owner);
        vm.expectRevert(NativeTokenVaultAlreadySet.selector);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(makeAddr("newNTV")));
    }

    function test_SetL1NativeTokenVault_RevertWhen_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ZeroAddress.selector);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(address(0)));
    }

    function test_SetL1AssetRouter_Success() public {
        vm.prank(owner);
        l1Nullifier.setL1AssetRouter(assetRouter);
        assertEq(address(l1Nullifier.l1AssetRouter()), assetRouter);
    }

    function test_SetL1AssetRouter_RevertWhen_NotOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        l1Nullifier.setL1AssetRouter(assetRouter);
    }

    function test_SetL1AssetRouter_RevertWhen_AlreadySet() public {
        vm.prank(owner);
        l1Nullifier.setL1AssetRouter(assetRouter);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AddressAlreadySet.selector, assetRouter));
        l1Nullifier.setL1AssetRouter(makeAddr("newRouter"));
    }

    function test_SetL1AssetRouter_RevertWhen_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ZeroAddress.selector);
        l1Nullifier.setL1AssetRouter(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        ASSET ROUTER FUNCTIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BridgehubConfirmL2TransactionForwarded_RevertWhen_NotAssetRouter() public {
        address notRouter = makeAddr("notRouter");
        vm.prank(notRouter);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notRouter));
        l1Nullifier.bridgehubConfirmL2TransactionForwarded(1, bytes32(0), bytes32(0));
    }

    function test_BridgehubConfirmL2TransactionForwarded_RevertWhen_DepositExists() public {
        vm.prank(owner);
        l1Nullifier.setL1AssetRouter(assetRouter);

        uint256 chainId = 123;
        bytes32 txDataHash = keccak256("txDataHash");
        bytes32 txHash = keccak256("txHash");

        // First call succeeds
        vm.prank(assetRouter);
        l1Nullifier.bridgehubConfirmL2TransactionForwarded(chainId, txDataHash, txHash);

        // Second call should fail
        vm.prank(assetRouter);
        vm.expectRevert(DepositExists.selector);
        l1Nullifier.bridgehubConfirmL2TransactionForwarded(chainId, txDataHash, txHash);
    }

    function test_BridgehubConfirmL2TransactionForwarded_Success() public {
        vm.prank(owner);
        l1Nullifier.setL1AssetRouter(assetRouter);

        uint256 chainId = 123;
        bytes32 txDataHash = keccak256("txDataHash");
        bytes32 txHash = keccak256("txHash");

        assertEq(l1Nullifier.depositHappened(chainId, txHash), bytes32(0));

        vm.prank(assetRouter);
        l1Nullifier.bridgehubConfirmL2TransactionForwarded(chainId, txDataHash, txHash);

        assertEq(l1Nullifier.depositHappened(chainId, txHash), txDataHash);
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Pause_Success() public {
        vm.prank(owner);
        l1Nullifier.pause();
        assertTrue(l1Nullifier.paused());
    }

    function test_Pause_RevertWhen_NotOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        l1Nullifier.pause();
    }

    function test_Unpause_Success() public {
        vm.prank(owner);
        l1Nullifier.pause();
        assertTrue(l1Nullifier.paused());

        vm.prank(owner);
        l1Nullifier.unpause();
        assertFalse(l1Nullifier.paused());
    }

    function test_Unpause_RevertWhen_NotOwner() public {
        vm.prank(owner);
        l1Nullifier.pause();

        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        l1Nullifier.unpause();
    }

    function test_BridgehubConfirmL2TransactionForwarded_RevertWhen_Paused() public {
        vm.prank(owner);
        l1Nullifier.setL1AssetRouter(assetRouter);

        vm.prank(owner);
        l1Nullifier.pause();

        vm.prank(assetRouter);
        vm.expectRevert("Pausable: paused");
        l1Nullifier.bridgehubConfirmL2TransactionForwarded(1, bytes32(0), bytes32(uint256(1)));
    }

    /*//////////////////////////////////////////////////////////////
                        TRANSIENT SETTLEMENT LAYER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetTransientSettlementLayer() public view {
        (uint256 settlementLayer, uint256 batchNumber) = l1Nullifier.getTransientSettlementLayer();
        // Should return 0 initially since no transaction has set it
        assertEq(settlementLayer, 0);
        assertEq(batchNumber, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SetL1NativeTokenVault(address _ntv) public {
        vm.assume(_ntv != address(0));

        vm.prank(owner);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(_ntv));
        assertEq(address(l1Nullifier.l1NativeTokenVault()), _ntv);
    }

    function testFuzz_SetL1AssetRouter(address _router) public {
        vm.assume(_router != address(0));

        vm.prank(owner);
        l1Nullifier.setL1AssetRouter(_router);
        assertEq(address(l1Nullifier.l1AssetRouter()), _router);
    }

    function testFuzz_BridgehubConfirmL2TransactionForwarded(
        uint256 _chainId,
        bytes32 _txDataHash,
        bytes32 _txHash
    ) public {
        vm.assume(_txHash != bytes32(0));

        vm.prank(owner);
        l1Nullifier.setL1AssetRouter(assetRouter);

        vm.prank(assetRouter);
        l1Nullifier.bridgehubConfirmL2TransactionForwarded(_chainId, _txDataHash, _txHash);

        assertEq(l1Nullifier.depositHappened(_chainId, _txHash), _txDataHash);
    }
}
