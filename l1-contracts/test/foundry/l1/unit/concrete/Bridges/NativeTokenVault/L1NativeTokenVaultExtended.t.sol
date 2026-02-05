// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {ERC20} from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";

import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IL1AssetTracker} from "contracts/bridge/asset-tracker/IL1AssetTracker.sol";
import {IAssetTrackerBase} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {IBridgedStandardToken} from "contracts/bridge/interfaces/IBridgedStandardToken.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {TxStatus} from "contracts/common/Messaging.sol";

import {NoFundsTransferred, OriginChainIdNotFound, Unauthorized, WithdrawFailed, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {ClaimFailedDepositFailed, WrongCounterpart, OnlyFailureStatusAllowed} from "contracts/bridge/L1BridgeContractErrors.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("MockToken", "MTK") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockBridgedToken is ERC20 {
    address public ntv;

    constructor(address _ntv) ERC20("BridgedToken", "BRD") {
        ntv = _ntv;
    }

    function bridgeMint(address to, uint256 amount) external {
        require(msg.sender == ntv, "Only NTV");
        _mint(to, amount);
    }

    function bridgeBurn(address from, uint256 amount) external {
        require(msg.sender == ntv, "Only NTV");
        _burn(from, amount);
    }
}

contract L1NativeTokenVaultExtendedTest is Test {
    using stdStorage for StdStorage;

    L1NativeTokenVault public l1NTV;

    address public owner;
    address public proxyAdmin;
    address public wethToken;
    address public assetRouter;
    address public l1Nullifier;
    address public assetTracker;
    address public bridgedTokenBeacon;

    MockERC20 public token;

    uint256 public constant CHAIN_ID = 123;
    bytes32 public baseTokenAssetId;

    function setUp() public {
        owner = makeAddr("owner");
        proxyAdmin = makeAddr("proxyAdmin");
        wethToken = makeAddr("wethToken");
        assetRouter = makeAddr("assetRouter");
        l1Nullifier = makeAddr("l1Nullifier");
        assetTracker = makeAddr("assetTracker");

        token = new MockERC20();
        baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);

        // Create a mock bridged token beacon
        BridgedStandardERC20 bridgedTokenImpl = new BridgedStandardERC20();
        bridgedTokenBeacon = address(new UpgradeableBeacon(address(bridgedTokenImpl)));

        L1NativeTokenVault l1NTVImpl = new L1NativeTokenVault({
            _wethToken: wethToken,
            _assetRouter: assetRouter,
            _l1Nullifier: IL1Nullifier(l1Nullifier)
        });

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(l1NTVImpl),
            proxyAdmin,
            abi.encodeWithSelector(L1NativeTokenVault.initialize.selector, owner, bridgedTokenBeacon)
        );

        l1NTV = L1NativeTokenVault(payable(proxy));

        // Set asset tracker
        vm.prank(owner);
        l1NTV.setAssetTracker(assetTracker);
    }

    function test_Initialize_SetsOwner() public view {
        assertEq(l1NTV.owner(), owner);
    }

    function test_Initialize_RevertWhen_OwnerIsZeroAddress() public {
        L1NativeTokenVault l1NTVImpl = new L1NativeTokenVault({
            _wethToken: wethToken,
            _assetRouter: assetRouter,
            _l1Nullifier: IL1Nullifier(l1Nullifier)
        });

        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(l1NTVImpl),
            proxyAdmin,
            abi.encodeWithSelector(L1NativeTokenVault.initialize.selector, address(0), bridgedTokenBeacon)
        );
    }

    function test_SetAssetTracker_Success() public {
        L1NativeTokenVault freshNTV = _deployFreshNTV();
        address newAssetTracker = makeAddr("newAssetTracker");

        vm.prank(owner);
        freshNTV.setAssetTracker(newAssetTracker);

        assertEq(address(freshNTV.l1AssetTracker()), newAssetTracker);
    }

    function test_SetAssetTracker_RevertWhen_NotOwner() public {
        L1NativeTokenVault freshNTV = _deployFreshNTV();
        address notOwner = makeAddr("notOwner");
        address newAssetTracker = makeAddr("newAssetTracker");

        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        freshNTV.setAssetTracker(newAssetTracker);
    }

    function test_RegisterEthToken() public {
        vm.mockCall(
            assetRouter,
            abi.encodeWithSelector(AssetRouterBase.setAssetHandlerAddressThisChain.selector),
            abi.encode()
        );

        vm.mockCall(assetTracker, abi.encodeWithSelector(IAssetTrackerBase.registerNewToken.selector), abi.encode());

        l1NTV.registerEthToken();

        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        assertEq(l1NTV.tokenAddress(ethAssetId), ETH_TOKEN_ADDRESS);
    }

    function test_BridgeCheckCounterpartAddress_Success() public {
        vm.prank(assetRouter);
        l1NTV.bridgeCheckCounterpartAddress(CHAIN_ID, bytes32(0), address(0), L2_NATIVE_TOKEN_VAULT_ADDR);
    }

    function test_BridgeCheckCounterpartAddress_RevertWhen_WrongCounterpart() public {
        address wrongCounterpart = makeAddr("wrongCounterpart");

        vm.prank(assetRouter);
        vm.expectRevert(WrongCounterpart.selector);
        l1NTV.bridgeCheckCounterpartAddress(CHAIN_ID, bytes32(0), address(0), wrongCounterpart);
    }

    function test_BridgeCheckCounterpartAddress_RevertWhen_NotAssetRouter() public {
        address notAssetRouter = makeAddr("notAssetRouter");

        vm.prank(notAssetRouter);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notAssetRouter));
        l1NTV.bridgeCheckCounterpartAddress(CHAIN_ID, bytes32(0), address(0), L2_NATIVE_TOKEN_VAULT_ADDR);
    }

    function test_ChainBalance() public view {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        uint256 balance = l1NTV.chainBalance(CHAIN_ID, assetId);
        assertEq(balance, 0);
    }

    function test_MigrateTokenBalanceToAssetTracker() public {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));

        // Only asset tracker can call this
        vm.prank(assetTracker);
        uint256 migratedAmount = l1NTV.migrateTokenBalanceToAssetTracker(CHAIN_ID, assetId);

        // Since we didn't set a balance, it should be 0
        assertEq(migratedAmount, 0);
    }

    function test_MigrateTokenBalanceToAssetTracker_RevertWhen_NotAssetTracker() public {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        address notAssetTracker = makeAddr("notAssetTracker");

        vm.prank(notAssetTracker);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notAssetTracker));
        l1NTV.migrateTokenBalanceToAssetTracker(CHAIN_ID, assetId);
    }

    function test_BridgeConfirmTransferResult_RevertWhen_NotFailure() public {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        bytes memory data = abi.encode(uint256(1000), address(0), address(0));

        vm.prank(assetRouter);
        vm.expectRevert(OnlyFailureStatusAllowed.selector);
        l1NTV.bridgeConfirmTransferResult(CHAIN_ID, TxStatus.Success, assetId, makeAddr("sender"), data);
    }

    function test_BridgeConfirmTransferResult_RevertWhen_NoFundsTransferred() public {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        bytes memory data = abi.encode(uint256(0), address(0), address(0)); // 0 amount

        vm.mockCall(
            assetTracker,
            abi.encodeWithSelector(IL1AssetTracker.handleChainBalanceDecreaseOnL1.selector),
            abi.encode()
        );

        vm.mockCall(assetTracker, abi.encodeWithSelector(IAssetTrackerBase.registerNewToken.selector), abi.encode());

        vm.mockCall(
            assetRouter,
            abi.encodeWithSelector(AssetRouterBase.setAssetHandlerAddressThisChain.selector),
            abi.encode()
        );

        // Register the token
        vm.prank(assetRouter);
        l1NTV.ensureTokenIsRegistered(address(token));

        vm.prank(assetRouter);
        vm.expectRevert(NoFundsTransferred.selector);
        l1NTV.bridgeConfirmTransferResult(CHAIN_ID, TxStatus.Failure, assetId, makeAddr("sender"), data);
    }

    function test_CalculateCreate2TokenAddress() public {
        uint256 originChainId = 1;
        address nonNativeToken = makeAddr("nonNativeToken");

        address expectedAddress = l1NTV.calculateCreate2TokenAddress(originChainId, nonNativeToken);

        // Just verify it returns a valid address
        assertTrue(expectedAddress != address(0));
    }

    function test_Pause_Success() public {
        vm.prank(owner);
        l1NTV.pause();
        assertTrue(l1NTV.paused());
    }

    function test_Pause_RevertWhen_NotOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        l1NTV.pause();
    }

    function test_Unpause_Success() public {
        vm.prank(owner);
        l1NTV.pause();
        assertTrue(l1NTV.paused());

        vm.prank(owner);
        l1NTV.unpause();
        assertFalse(l1NTV.paused());
    }

    function test_Unpause_RevertWhen_NotOwner() public {
        vm.prank(owner);
        l1NTV.pause();

        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        l1NTV.unpause();
    }

    function testFuzz_CalculateCreate2TokenAddress(uint256 chainId, address tokenAddr) public view {
        vm.assume(chainId != 0);
        vm.assume(tokenAddr != address(0));

        address result = l1NTV.calculateCreate2TokenAddress(chainId, tokenAddr);
        assertTrue(result != address(0));
    }

    function _deployFreshNTV() internal returns (L1NativeTokenVault) {
        L1NativeTokenVault l1NTVImpl = new L1NativeTokenVault({
            _wethToken: wethToken,
            _assetRouter: assetRouter,
            _l1Nullifier: IL1Nullifier(l1Nullifier)
        });

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(l1NTVImpl),
            proxyAdmin,
            abi.encodeWithSelector(L1NativeTokenVault.initialize.selector, owner, bridgedTokenBeacon)
        );

        return L1NativeTokenVault(payable(proxy));
    }
}
