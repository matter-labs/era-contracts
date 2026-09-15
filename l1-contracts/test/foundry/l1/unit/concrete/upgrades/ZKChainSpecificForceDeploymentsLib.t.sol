// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ZKChainSpecificForceDeploymentsLib} from "contracts/upgrades/ZKChainSpecificForceDeploymentsLib.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {ZKChainSpecificForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";

/// @dev The library is `internal`; this harness is the only way to call it from a test.
contract ZKChainSpecificForceDeploymentsLibHarness {
    function build(address _bridgehub, uint256 _chainId) external view returns (bytes memory) {
        return ZKChainSpecificForceDeploymentsLib.build(_bridgehub, _chainId);
    }
}

contract MockERC20TokenWithMetadata {
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}

/// @dev A token with no metadata methods at all: every probe reverts on the missing selector.
contract MockERC20TokenWithoutMetadata {}

/// @dev Maker-style: `name()`/`symbol()` answer with a raw `bytes32` rather than a `string`.
contract MockERC20TokenWithBytes32Metadata {
    bytes32 private immutable _NAME;
    bytes32 private immutable _SYMBOL;

    constructor(bytes32 name_, bytes32 symbol_) {
        _NAME = name_;
        _SYMBOL = symbol_;
    }

    function name() external view returns (bytes32) {
        return _NAME;
    }

    function symbol() external view returns (bytes32) {
        return _SYMBOL;
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }
}

/// @notice The one builder of a chain's `ZKChainSpecificForceDeploymentsData`, shared by the
///         genesis engine and the upgrade-path delegate composers.
/// @dev The ecosystem behind the Bridgehub (asset router, native token vault) is mocked: this unit
///      has no live vault, and what is under test is which values land in the struct. The base
///      tokens themselves are REAL contracts, since their metadata is exactly what is probed.
contract ZKChainSpecificForceDeploymentsLibTest is Test {
    ZKChainSpecificForceDeploymentsLibHarness internal lib;

    address internal bridgehubMock;
    address internal assetRouterMock;
    address internal nativeTokenVaultMock;

    uint256 internal constant CHAIN_ID = 123;
    uint256 internal constant ORIGIN_CHAIN_ID = 300;
    bytes32 internal constant BASE_TOKEN_ASSET_ID = bytes32("baseTokenAssetId");

    function setUp() public {
        bridgehubMock = makeAddr("bridgehubMock");
        assetRouterMock = makeAddr("assetRouterMock");
        nativeTokenVaultMock = makeAddr("nativeTokenVaultMock");
        lib = new ZKChainSpecificForceDeploymentsLibHarness();

        vm.mockCall(bridgehubMock, abi.encodeCall(IBridgehubBase.assetRouter, ()), abi.encode(assetRouterMock));
        vm.mockCall(
            bridgehubMock,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (CHAIN_ID)),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );
        vm.mockCall(
            assetRouterMock,
            abi.encodeCall(IL1AssetRouter.nativeTokenVault, ()),
            abi.encode(nativeTokenVaultMock)
        );
        vm.mockCall(
            nativeTokenVaultMock,
            abi.encodeCall(INativeTokenVaultBase.originChainId, (BASE_TOKEN_ASSET_ID)),
            abi.encode(block.chainid)
        );
        _setBaseToken(ETH_TOKEN_ADDRESS, ETH_TOKEN_ADDRESS);
    }

    /// @dev Points the ecosystem's base-token lookups at `_localToken` (what `baseToken` resolves
    ///      to on this layer) and `_originToken` (what the vault records as the origin).
    function _setBaseToken(address _localToken, address _originToken) internal {
        vm.mockCall(bridgehubMock, abi.encodeCall(IBridgehubBase.baseToken, (CHAIN_ID)), abi.encode(_localToken));
        vm.mockCall(
            nativeTokenVaultMock,
            abi.encodeCall(INativeTokenVaultBase.originToken, (BASE_TOKEN_ASSET_ID)),
            abi.encode(_originToken)
        );
    }

    function _build() internal view returns (ZKChainSpecificForceDeploymentsData memory) {
        return abi.decode(lib.build(bridgehubMock, CHAIN_ID), (ZKChainSpecificForceDeploymentsData));
    }

    // ─────────────────────────── metadata ───────────────────────────

    function test_ethBaseTokenUsesTheHardcodedEtherMetadata() public {
        ZKChainSpecificForceDeploymentsData memory chainData = _build();

        assertEq(chainData.baseTokenBridgingData.assetId, BASE_TOKEN_ASSET_ID);
        assertEq(chainData.baseTokenBridgingData.originChainId, block.chainid);
        assertEq(chainData.baseTokenBridgingData.originToken, ETH_TOKEN_ADDRESS);
        // The legacy shared bridge has been removed; this ABI placeholder is always address(0).
        assertEq(chainData.l2LegacySharedBridge, address(0));
        assertEq(chainData.predeployedL2WethAddress, address(0));
        assertEq(chainData.baseTokenL1Address, ETH_TOKEN_ADDRESS);
        assertEq(chainData.baseTokenMetadata.name, "Ether");
        assertEq(chainData.baseTokenMetadata.symbol, "ETH");
        assertEq(chainData.baseTokenMetadata.decimals, 18);
    }

    function test_erc20BaseTokenMetadataIsReadFromTheToken() public {
        MockERC20TokenWithMetadata token = new MockERC20TokenWithMetadata("Test Token", "TTK", 6);
        _setBaseToken(address(token), address(token));

        ZKChainSpecificForceDeploymentsData memory chainData = _build();

        assertEq(chainData.baseTokenL1Address, address(token));
        assertEq(chainData.baseTokenMetadata.name, "Test Token");
        assertEq(chainData.baseTokenMetadata.symbol, "TTK");
        // Not the token's own 6: a conforming 32-byte `decimals()` answer is filtered by the
        // `bytes32` guard the probes share, so the ERC20 default stands for every token.
        assertEq(chainData.baseTokenMetadata.decimals, 18);
    }

    /// @dev Tolerance, not leniency for its own sake: a chain may be created on a token that serves
    ///      no metadata, and every later upgrade recomposes these same values.
    function test_baseTokenWithoutMetadataFallsBackToTheDefaults() public {
        MockERC20TokenWithoutMetadata token = new MockERC20TokenWithoutMetadata();
        _setBaseToken(address(token), address(token));

        ZKChainSpecificForceDeploymentsData memory chainData = _build();

        assertEq(chainData.baseTokenL1Address, address(token));
        assertEq(chainData.baseTokenMetadata.name, "Base Token");
        assertEq(chainData.baseTokenMetadata.symbol, "BT");
        assertEq(chainData.baseTokenMetadata.decimals, 18);
    }

    /// @dev A `bytes32`-returning (Maker-style) token is treated as having no string metadata.
    function test_baseTokenReturningBytes32MetadataFallsBackToTheDefaults() public {
        MockERC20TokenWithBytes32Metadata token = new MockERC20TokenWithBytes32Metadata(
            bytes32("Maker"),
            bytes32("MKR")
        );
        _setBaseToken(address(token), address(token));

        ZKChainSpecificForceDeploymentsData memory chainData = _build();

        assertEq(chainData.baseTokenL1Address, address(token));
        assertEq(chainData.baseTokenMetadata.name, "Base Token");
        assertEq(chainData.baseTokenMetadata.symbol, "BT");
        assertEq(chainData.baseTokenMetadata.decimals, 18);
    }

    // ─────────────────────────── the base token's recorded address ───────────────────────────

    /// @dev The deliberate choice for a base token that originates on another chain:
    ///      `baseTokenL1Address` is the LOCAL representation the metadata was read from, while the
    ///      origin identity travels in `baseTokenBridgingData`. The two fields are not
    ///      interchangeable and the struct carries both.
    function test_baseTokenL1AddressIsTheLocalRepresentationNotTheOriginToken() public {
        MockERC20TokenWithMetadata localToken = new MockERC20TokenWithMetadata("Bridged Token", "BRG", 8);
        address originToken = makeAddr("originTokenOnAnotherChain");
        _setBaseToken(address(localToken), originToken);
        vm.mockCall(
            nativeTokenVaultMock,
            abi.encodeCall(INativeTokenVaultBase.originChainId, (BASE_TOKEN_ASSET_ID)),
            abi.encode(ORIGIN_CHAIN_ID)
        );

        ZKChainSpecificForceDeploymentsData memory chainData = _build();

        assertEq(chainData.baseTokenL1Address, address(localToken), "the local representation is recorded");
        assertEq(chainData.baseTokenMetadata.name, "Bridged Token", "the metadata comes from that same token");
        assertEq(chainData.baseTokenMetadata.symbol, "BRG");
        assertEq(chainData.baseTokenMetadata.decimals, 18);
        assertEq(chainData.baseTokenBridgingData.originToken, originToken, "the origin identity is kept separately");
        assertEq(chainData.baseTokenBridgingData.originChainId, ORIGIN_CHAIN_ID);
    }

    // ─────────────────────────── failure ───────────────────────────

    /// @dev A chain the ecosystem does not know has no base token to resolve: the build reverts
    ///      rather than composing data for nobody.
    function test_revertWhen_chainIsNotRegistered() public {
        uint256 unknownChainId = 999;

        vm.expectRevert();
        lib.build(bridgehubMock, unknownChainId);
    }
}
