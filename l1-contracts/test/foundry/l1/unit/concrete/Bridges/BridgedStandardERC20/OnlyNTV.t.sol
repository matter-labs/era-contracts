// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

contract MockNTV {
    function L1_CHAIN_ID() external view returns (uint256) {
        return block.chainid;
    }
}

contract BridgedStandardERC20_OnlyNTV_Test is Test {
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
            _name: abi.encode("N"),
            _symbol: abi.encode("S"),
            _decimals: abi.encode(uint8(18))
        });
        token.bridgeInitialize(assetId, originToken, data);
    }

    function _installMockNTV() internal {
        MockNTV mock = new MockNTV();
        bytes memory code = address(mock).code;
        vm.etch(L2_NATIVE_TOKEN_VAULT_ADDR, code);
    }

    function _zeroOutNTVAndAssetId(BridgedStandardERC20 token) internal {
        // discover slots by getter selectors and zero them
        uint256 ntvSlot = stdstore.target(address(token)).sig("nativeTokenVault()").find();
        vm.store(address(token), bytes32(ntvSlot), bytes32(uint256(0)));
        uint256 assetSlot = stdstore.target(address(token)).sig("assetId()").find();
        vm.store(address(token), bytes32(assetSlot), bytes32(0));
    }

    function test_LazyInitSetsDefaultNTVAndAssetId_OnFirstMint() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);
        _installMockNTV();

        // Force the lazy-init path
        _zeroOutNTVAndAssetId(token);
        assertEq(token.nativeTokenVault(), address(0));
        assertEq(token.assetId(), bytes32(0));

        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        token.bridgeMint(address(0xCAFE), 123);

        assertEq(token.nativeTokenVault(), L2_NATIVE_TOKEN_VAULT_ADDR);
        bytes32 expected = DataEncoding.encodeNTVAssetId(block.chainid, originToken);
        assertEq(token.assetId(), expected);
    }

    function test_UnauthorizedSenderReverts_OnMint() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);
        _installMockNTV();

        _zeroOutNTVAndAssetId(token);

        // correct sender sets NTV
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        token.bridgeMint(address(this), 1);

        // now unauthorized sender
        vm.expectRevert();
        token.bridgeMint(address(this), 1);
    }
}
