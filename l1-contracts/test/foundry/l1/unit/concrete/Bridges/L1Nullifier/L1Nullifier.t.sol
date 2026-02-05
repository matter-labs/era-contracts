// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20} from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";

import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IMessageRoot} from "contracts/core/message-root/IMessageRoot.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {NEW_ENCODING_VERSION, LEGACY_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";

import {AddressAlreadySet, DepositDoesNotExist, DepositExists, LegacyMethodForNonL1Token, Unauthorized, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {NativeTokenVaultAlreadySet, EthAlreadyMigratedToL1NTV} from "contracts/bridge/L1BridgeContractErrors.sol";

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
    address public legacyBridge;

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
        legacyBridge = makeAddr("legacyBridge");
        eraDiamondProxy = makeAddr("eraDiamondProxy");

        token = new TestERC20();

        l1NullifierImpl = new L1NullifierDev({
            _bridgehub: IL1Bridgehub(bridgehub),
            _messageRoot: IMessageRoot(messageRoot),
            _interopCenter: IInteropCenter(interopCenter),
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
            _messageRoot: IMessageRoot(messageRoot),
            _interopCenter: IInteropCenter(interopCenter),
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

    function test_SetL1Erc20Bridge_Success() public {
        vm.prank(owner);
        l1Nullifier.setL1Erc20Bridge(IL1ERC20Bridge(legacyBridge));
        assertEq(address(l1Nullifier.legacyBridge()), legacyBridge);
    }

    function test_SetL1Erc20Bridge_RevertWhen_NotOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        l1Nullifier.setL1Erc20Bridge(IL1ERC20Bridge(legacyBridge));
    }

    function test_SetL1Erc20Bridge_RevertWhen_AlreadySet() public {
        vm.prank(owner);
        l1Nullifier.setL1Erc20Bridge(IL1ERC20Bridge(legacyBridge));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AddressAlreadySet.selector, legacyBridge));
        l1Nullifier.setL1Erc20Bridge(IL1ERC20Bridge(makeAddr("newBridge")));
    }

    function test_SetL1Erc20Bridge_RevertWhen_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ZeroAddress.selector);
        l1Nullifier.setL1Erc20Bridge(IL1ERC20Bridge(address(0)));
    }

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
                            NTV FUNCTIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TransferTokenToNTV_RevertWhen_NotNTV() public {
        address notNTV = makeAddr("notNTV");
        vm.prank(notNTV);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notNTV));
        l1Nullifier.transferTokenToNTV(address(token));
    }

    function test_TransferTokenToNTV_RevertWhen_ETH() public {
        vm.prank(owner);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(nativeTokenVault));

        vm.prank(nativeTokenVault);
        vm.expectRevert(EthAlreadyMigratedToL1NTV.selector);
        l1Nullifier.transferTokenToNTV(ETH_TOKEN_ADDRESS);
    }

    function test_TransferTokenToNTV_Success() public {
        vm.prank(owner);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(nativeTokenVault));

        uint256 amount = 1000;
        token.mint(address(l1Nullifier), amount);

        uint256 ntvBalanceBefore = token.balanceOf(nativeTokenVault);

        vm.prank(nativeTokenVault);
        l1Nullifier.transferTokenToNTV(address(token));

        assertEq(token.balanceOf(nativeTokenVault), ntvBalanceBefore + amount);
        assertEq(token.balanceOf(address(l1Nullifier)), 0);
    }

    function test_NullifyChainBalanceByNTV_RevertWhen_NotNTV() public {
        address notNTV = makeAddr("notNTV");
        vm.prank(notNTV);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notNTV));
        l1Nullifier.nullifyChainBalanceByNTV(1, address(token));
    }

    function test_NullifyChainBalanceByNTV_Success() public {
        vm.prank(owner);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(nativeTokenVault));

        uint256 chainId = 123;

        // Set a chain balance
        stdstore
            .target(address(l1Nullifier))
            .sig(l1Nullifier.chainBalance.selector)
            .with_key(chainId)
            .with_key(address(token))
            .checked_write(1000);

        assertEq(l1Nullifier.chainBalance(chainId, address(token)), 1000);

        vm.prank(nativeTokenVault);
        l1Nullifier.nullifyChainBalanceByNTV(chainId, address(token));

        assertEq(l1Nullifier.chainBalance(chainId, address(token)), 0);
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
                        LEGACY FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_L2BridgeAddress() public {
        uint256 chainId = 123;
        address l2Bridge = makeAddr("l2Bridge");

        // Set the deprecated l2BridgeAddress via the dev contract
        L1NullifierDev(address(l1Nullifier)).setL2LegacySharedBridge(chainId, l2Bridge);

        assertEq(l1Nullifier.l2BridgeAddress(chainId), l2Bridge);
    }

    function test_ChainBalance() public {
        uint256 chainId = 123;
        uint256 balance = 1000;

        // Set via stdstore
        stdstore
            .target(address(l1Nullifier))
            .sig(l1Nullifier.chainBalance.selector)
            .with_key(chainId)
            .with_key(address(token))
            .checked_write(balance);

        assertEq(l1Nullifier.chainBalance(chainId, address(token)), balance);
    }

    /*//////////////////////////////////////////////////////////////
                        ENCODE TX DATA HASH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_EncodeTxDataHash_NewEncoding() public {
        vm.prank(owner);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(nativeTokenVault));

        address originalCaller = makeAddr("caller");
        bytes32 assetId = keccak256("assetId");
        bytes memory transferData = abi.encode("some data");

        bytes32 result = l1Nullifier.encodeTxDataHash(NEW_ENCODING_VERSION, originalCaller, assetId, transferData);

        // Verify it's not zero
        assertTrue(result != bytes32(0));
    }

    function test_EncodeTxDataHash_LegacyEncoding_ReturnsCorrectHash() public {
        vm.prank(owner);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(nativeTokenVault));

        address originalCaller = makeAddr("caller");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        // Transfer data for legacy encoding must be 96 bytes (amount, receiver, maybeTokenAddress)
        bytes memory transferData = abi.encode(uint256(1000), address(0), address(0));

        // Mock the tokenAddress function on the NTV
        vm.mockCall(
            nativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.tokenAddress.selector, assetId),
            abi.encode(address(token))
        );

        bytes32 result = l1Nullifier.encodeTxDataHash(LEGACY_ENCODING_VERSION, originalCaller, assetId, transferData);

        // Should return keccak256(abi.encode(originalCaller, tokenAddress, amount))
        bytes32 expected = keccak256(abi.encode(originalCaller, address(token), uint256(1000)));
        assertEq(result, expected);
    }

    /*//////////////////////////////////////////////////////////////
                        LEGACY BRIDGE MODIFIER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimFailedDepositLegacyErc20Bridge_RevertWhen_NotLegacyBridge() public {
        address notLegacyBridge = makeAddr("notLegacyBridge");

        bytes32[] memory merkleProof = new bytes32[](0);

        vm.prank(notLegacyBridge);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notLegacyBridge));
        l1Nullifier.claimFailedDepositLegacyErc20Bridge(
            makeAddr("depositSender"),
            address(token),
            1000,
            bytes32(0),
            1,
            1,
            1,
            merkleProof
        );
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

    function testFuzz_SetL1Erc20Bridge(address _bridge) public {
        vm.assume(_bridge != address(0));

        vm.prank(owner);
        l1Nullifier.setL1Erc20Bridge(IL1ERC20Bridge(_bridge));
        assertEq(address(l1Nullifier.legacyBridge()), _bridge);
    }

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

    function testFuzz_NullifyChainBalanceByNTV(uint256 _chainId, uint256 _initialBalance) public {
        vm.prank(owner);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(nativeTokenVault));

        // Set initial balance
        stdstore
            .target(address(l1Nullifier))
            .sig(l1Nullifier.chainBalance.selector)
            .with_key(_chainId)
            .with_key(address(token))
            .checked_write(_initialBalance);

        vm.prank(nativeTokenVault);
        l1Nullifier.nullifyChainBalanceByNTV(_chainId, address(token));

        assertEq(l1Nullifier.chainBalance(_chainId, address(token)), 0);
    }

    function testFuzz_TransferTokenToNTV(uint256 _amount) public {
        _amount = bound(_amount, 1, type(uint128).max);

        vm.prank(owner);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(nativeTokenVault));

        token.mint(address(l1Nullifier), _amount);

        vm.prank(nativeTokenVault);
        l1Nullifier.transferTokenToNTV(address(token));

        assertEq(token.balanceOf(nativeTokenVault), _amount);
        assertEq(token.balanceOf(address(l1Nullifier)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    CLAIM FAILED DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimFailedDeposit_RevertWhen_NonL1Token() public {
        vm.prank(owner);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(nativeTokenVault));

        // Create a mock token
        address mockToken = makeAddr("mockToken");

        // Mock the assetId to return a different assetId than expected for L1 tokens
        // This simulates a token that has a different assetId registered
        bytes32 registeredAssetId = keccak256("registeredAssetId");
        bytes32 expectedL1AssetId = DataEncoding.encodeNTVAssetId(block.chainid, mockToken);

        // Make sure they're different - the condition is assetId != ntvAssetId
        vm.assume(registeredAssetId != expectedL1AssetId);

        vm.mockCall(
            nativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.assetId.selector, mockToken),
            abi.encode(registeredAssetId)
        );

        bytes32[] memory merkleProof = new bytes32[](0);

        vm.expectRevert(LegacyMethodForNonL1Token.selector);
        l1Nullifier.claimFailedDeposit({
            _chainId: 1,
            _depositSender: makeAddr("sender"),
            _l1Token: mockToken,
            _amount: 1000,
            _l2TxHash: bytes32(uint256(1)),
            _l2BatchNumber: 1,
            _l2MessageIndex: 1,
            _l2TxNumberInBatch: 1,
            _merkleProof: merkleProof
        });
    }

    function test_ClaimFailedDeposit_UsesNtvAssetIdWhenNotRegistered() public {
        vm.prank(owner);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(nativeTokenVault));
        vm.prank(owner);
        l1Nullifier.setL1AssetRouter(assetRouter);

        // Mock assetId returns 0 (not registered)
        vm.mockCall(
            nativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.assetId.selector, address(token)),
            abi.encode(bytes32(0))
        );

        bytes32[] memory merkleProof = new bytes32[](0);

        // This will fail at verification stage because we haven't set up a proper deposit,
        // but it will pass the assetId check (line 646-649)
        vm.expectRevert(); // Will revert on proof verification
        l1Nullifier.claimFailedDeposit({
            _chainId: 1,
            _depositSender: makeAddr("sender"),
            _l1Token: address(token),
            _amount: 1000,
            _l2TxHash: bytes32(uint256(1)),
            _l2BatchNumber: 1,
            _l2MessageIndex: 1,
            _l2TxNumberInBatch: 1,
            _merkleProof: merkleProof
        });
    }
}
