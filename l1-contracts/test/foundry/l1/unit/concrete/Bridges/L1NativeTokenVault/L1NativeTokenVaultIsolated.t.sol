// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";

import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";

import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";

import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {TxStatus} from "contracts/common/Messaging.sol";

import {
    AssetIdAlreadyRegistered,
    NoFundsTransferred,
    Unauthorized,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {WrongCounterpart} from "contracts/bridge/L1BridgeContractErrors.sol";

/// @notice The vault's own state (init, registration, pause, counterpart checks, views) behind a proxy,
/// isolated from the asset router and the nullifier, which are bare addresses here. Flows that need the
/// real router and nullifier live in L1NativeTokenVault.t.sol.
contract L1NativeTokenVaultIsolatedTest is Test {
    L1NativeTokenVault public l1NTV;

    address public owner;
    address public proxyAdmin;
    address public wethToken;
    address public assetRouter;
    address public l1Nullifier;
    address public bridgedTokenBeacon;

    TestnetERC20Token public token;

    uint256 public constant CHAIN_ID = 123;

    function setUp() public {
        owner = makeAddr("owner");
        proxyAdmin = makeAddr("proxyAdmin");
        wethToken = makeAddr("wethToken");
        assetRouter = makeAddr("assetRouter");
        l1Nullifier = makeAddr("l1Nullifier");

        token = new TestnetERC20Token("MockToken", "MTK", 18);

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
    }

    /// @dev Registration notifies the asset router, which is a bare address in this file.
    function _mockAssetRouterRegistration() internal {
        vm.mockCall(
            assetRouter,
            abi.encodeWithSelector(AssetRouterBase.setAssetHandlerAddressThisChain.selector),
            abi.encode()
        );
    }

    function test_constructor() public view {
        assertEq(address(l1NTV.WETH_TOKEN()), wethToken);
        assertEq(address(l1NTV.ASSET_ROUTER()), assetRouter);
        assertEq(address(l1NTV.L1_NULLIFIER()), l1Nullifier);
        assertEq(l1NTV.L1_CHAIN_ID(), block.chainid);
        assertEq(l1NTV.BASE_TOKEN_ASSET_ID(), DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS));
    }

    function test_Initialize_SetsOwner() public view {
        assertEq(l1NTV.owner(), owner);
        assertEq(address(l1NTV.bridgedTokenBeacon()), bridgedTokenBeacon);
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

    function test_RegisterEthToken() public {
        _mockAssetRouterRegistration();

        l1NTV.registerEthToken();

        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        assertEq(l1NTV.tokenAddress(ethAssetId), ETH_TOKEN_ADDRESS);
    }

    function test_RegisterToken() public {
        _mockAssetRouterRegistration();

        l1NTV.registerToken(address(token));

        bytes32 tokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        assertEq(l1NTV.assetId(address(token)), tokenAssetId);
        assertEq(l1NTV.tokenAddress(tokenAssetId), address(token));
        assertEq(l1NTV.originToken(tokenAssetId), address(token));
        assertEq(l1NTV.bridgedTokensCount(), 1);
    }

    function test_RegisterToken_RevertWhen_AlreadyRegistered() public {
        _mockAssetRouterRegistration();
        l1NTV.registerToken(address(token));

        vm.expectRevert(AssetIdAlreadyRegistered.selector);
        l1NTV.registerToken(address(token));
    }

    function test_OriginToken_ReturnsZeroForUnknownAsset() public view {
        assertEq(l1NTV.originToken(keccak256("unknownAsset")), address(0));
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

    function test_BridgeConfirmTransferResult_RevertWhen_NoFundsTransferred() public {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        bytes memory data = abi.encode(uint256(0), address(0), address(0)); // 0 amount

        _mockAssetRouterRegistration();

        // Register the token
        vm.prank(assetRouter);
        l1NTV.ensureTokenIsRegistered(address(token));

        vm.prank(assetRouter);
        vm.expectRevert(NoFundsTransferred.selector);
        l1NTV.bridgeConfirmTransferResult(CHAIN_ID, TxStatus.Failure, assetId, makeAddr("sender"), data);
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

    function testFuzz_CalculateCreate2TokenAddress(uint256 _chainId, address _token) public view {
        address expected = vm.computeCreate2Address(
            keccak256(abi.encode(_chainId, _token)),
            keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(bridgedTokenBeacon, ""))),
            address(l1NTV)
        );
        assertEq(l1NTV.calculateCreate2TokenAddress(_chainId, _token), expected);
    }

    function test_GetERC20Getters() public view {
        bytes memory expected = DataEncoding.encodeTokenData({
            _chainId: block.chainid,
            _name: abi.encode("MockToken"),
            _symbol: abi.encode("MTK"),
            _decimals: abi.encode(uint8(18))
        });
        assertEq(l1NTV.getERC20Getters(address(token), block.chainid), expected);
    }
}
