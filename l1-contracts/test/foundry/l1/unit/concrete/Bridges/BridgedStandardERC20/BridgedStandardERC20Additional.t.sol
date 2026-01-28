// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ZeroAddress, Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract MockNTVForAdditional {
    function L1_CHAIN_ID() external view returns (uint256) {
        return block.chainid;
    }
}

/// @notice Additional unit tests for BridgedStandardERC20 contract
contract BridgedStandardERC20AdditionalTest is Test {
    using stdStorage for StdStorage;

    BridgedStandardERC20 implementation;
    address originToken = address(0xBEEF);
    bytes32 assetId = keccak256(abi.encode("assetId"));

    function setUp() public {
        implementation = new BridgedStandardERC20();
    }

    function _deployProxy() internal returns (BridgedStandardERC20 token) {
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), bytes(""));
        token = BridgedStandardERC20(address(proxy));
    }

    function _init(BridgedStandardERC20 token) internal {
        bytes memory data = DataEncoding.encodeTokenData({
            _chainId: 1,
            _name: abi.encode("TestToken"),
            _symbol: abi.encode("TT"),
            _decimals: abi.encode(uint8(18))
        });
        token.bridgeInitialize(assetId, originToken, data);
    }

    function _installMockNTV() internal {
        MockNTVForAdditional mock = new MockNTVForAdditional();
        bytes memory code = address(mock).code;
        vm.etch(L2_NATIVE_TOKEN_VAULT_ADDR, code);
    }

    // ============ bridgeInitialize Tests ============

    function test_bridgeInitialize_setsOriginToken() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        assertEq(token.originToken(), originToken);
    }

    function test_bridgeInitialize_setsAssetId() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        assertEq(token.assetId(), assetId);
    }

    function test_bridgeInitialize_setsNativeTokenVault() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        assertEq(token.nativeTokenVault(), address(this));
    }

    function test_bridgeInitialize_setsName() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        assertEq(token.name(), "TestToken");
    }

    function test_bridgeInitialize_setsSymbol() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        assertEq(token.symbol(), "TT");
    }

    function test_bridgeInitialize_setsDecimals() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        assertEq(token.decimals(), 18);
    }

    function test_bridgeInitialize_revertsOnZeroOriginToken() public {
        BridgedStandardERC20 token = _deployProxy();
        bytes memory data = DataEncoding.encodeTokenData({
            _chainId: 1,
            _name: abi.encode("N"),
            _symbol: abi.encode("S"),
            _decimals: abi.encode(uint8(18))
        });

        vm.expectRevert(ZeroAddress.selector);
        token.bridgeInitialize(assetId, address(0), data);
    }

    function test_bridgeInitialize_cannotBeCalledTwice() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        bytes memory data = DataEncoding.encodeTokenData({
            _chainId: 1,
            _name: abi.encode("N"),
            _symbol: abi.encode("S"),
            _decimals: abi.encode(uint8(18))
        });

        vm.expectRevert();
        token.bridgeInitialize(assetId, originToken, data);
    }

    // ============ bridgeMint Tests ============

    function test_bridgeMint_mintsTokens() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        address recipient = address(0xCAFE);
        uint256 amount = 1000 ether;

        token.bridgeMint(recipient, amount);

        assertEq(token.balanceOf(recipient), amount);
    }

    function test_bridgeMint_increasesTotalSupply() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        uint256 amount = 500 ether;
        token.bridgeMint(address(0xCAFE), amount);

        assertEq(token.totalSupply(), amount);
    }

    function test_bridgeMint_multipleRecipients() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        address recipient1 = address(0xCAFE);
        address recipient2 = address(0xBEEF);

        token.bridgeMint(recipient1, 100 ether);
        token.bridgeMint(recipient2, 200 ether);

        assertEq(token.balanceOf(recipient1), 100 ether);
        assertEq(token.balanceOf(recipient2), 200 ether);
        assertEq(token.totalSupply(), 300 ether);
    }

    // ============ bridgeBurn Tests ============

    function test_bridgeBurn_burnsTokens() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        address holder = address(0xCAFE);
        token.bridgeMint(holder, 1000 ether);
        token.bridgeBurn(holder, 400 ether);

        assertEq(token.balanceOf(holder), 600 ether);
    }

    function test_bridgeBurn_decreasesTotalSupply() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        address holder = address(0xCAFE);
        token.bridgeMint(holder, 1000 ether);
        token.bridgeBurn(holder, 300 ether);

        assertEq(token.totalSupply(), 700 ether);
    }

    function test_bridgeBurn_revertsOnInsufficientBalance() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        address holder = address(0xCAFE);
        token.bridgeMint(holder, 100 ether);

        vm.expectRevert();
        token.bridgeBurn(holder, 200 ether);
    }

    // ============ decodeString Tests ============

    function test_decodeString_validInput() public view {
        string memory result = implementation.decodeString(abi.encode("Hello World"));
        assertEq(result, "Hello World");
    }

    function test_decodeString_emptyString() public view {
        string memory result = implementation.decodeString(abi.encode(""));
        assertEq(result, "");
    }

    function test_decodeString_revertsOnInvalidInput() public {
        vm.expectRevert();
        implementation.decodeString(hex"1234");
    }

    // ============ decodeUint8 Tests ============

    function test_decodeUint8_validInput() public view {
        uint8 result = implementation.decodeUint8(abi.encode(uint8(18)));
        assertEq(result, 18);
    }

    function test_decodeUint8_zero() public view {
        uint8 result = implementation.decodeUint8(abi.encode(uint8(0)));
        assertEq(result, 0);
    }

    function test_decodeUint8_maxValue() public view {
        uint8 result = implementation.decodeUint8(abi.encode(type(uint8).max));
        assertEq(result, 255);
    }

    function test_decodeUint8_revertsOnInvalidInput() public {
        vm.expectRevert();
        implementation.decodeUint8(hex"1234");
    }

    // ============ l2Bridge Tests (deprecated) ============

    function test_l2Bridge_isZeroByDefault() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        assertEq(token.l2Bridge(), address(0));
    }

    // ============ ERC20 Standard Tests ============

    function test_transfer_works() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        address sender = address(0xCAFE);
        address recipient = address(0xBEEF);

        token.bridgeMint(sender, 1000 ether);

        vm.prank(sender);
        bool success = token.transfer(recipient, 300 ether);

        assertTrue(success);
        assertEq(token.balanceOf(sender), 700 ether);
        assertEq(token.balanceOf(recipient), 300 ether);
    }

    function test_approve_and_transferFrom() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        address owner = address(0xCAFE);
        address spender = address(0xDEAD);
        address recipient = address(0xBEEF);

        token.bridgeMint(owner, 1000 ether);

        vm.prank(owner);
        token.approve(spender, 500 ether);

        assertEq(token.allowance(owner, spender), 500 ether);

        vm.prank(spender);
        bool success = token.transferFrom(owner, recipient, 200 ether);

        assertTrue(success);
        assertEq(token.balanceOf(owner), 800 ether);
        assertEq(token.balanceOf(recipient), 200 ether);
        assertEq(token.allowance(owner, spender), 300 ether);
    }

    // ============ Fuzz Tests ============

    function testFuzz_bridgeMint(address recipient, uint256 amount) public {
        vm.assume(recipient != address(0));
        vm.assume(amount < type(uint128).max);

        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        token.bridgeMint(recipient, amount);

        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.totalSupply(), amount);
    }

    function testFuzz_bridgeBurn(address holder, uint256 mintAmount, uint256 burnAmount) public {
        vm.assume(holder != address(0));
        vm.assume(mintAmount < type(uint128).max);
        vm.assume(burnAmount <= mintAmount);

        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        token.bridgeMint(holder, mintAmount);
        token.bridgeBurn(holder, burnAmount);

        assertEq(token.balanceOf(holder), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function testFuzz_decodeString(string memory input) public view {
        string memory result = implementation.decodeString(abi.encode(input));
        assertEq(keccak256(bytes(result)), keccak256(bytes(input)));
    }

    function testFuzz_decodeUint8(uint8 input) public view {
        uint8 result = implementation.decodeUint8(abi.encode(input));
        assertEq(result, input);
    }
}
