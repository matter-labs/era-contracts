// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";

contract BridgedStandardERC20_ReinitializeGuard_Test is Test {
    BridgedStandardERC20 implementation;
    address originToken = address(0xBEEF);
    bytes32 assetId = keccak256(abi.encode("assetId"));

    function setUp() public {
        implementation = new BridgedStandardERC20();
    }

    function _encodeTokenData(
        bytes memory nameBytes,
        bytes memory symbolBytes,
        bytes memory decimalsBytes
    ) internal pure returns (bytes memory) {
        return
            DataEncoding.encodeTokenData({
                _chainId: 1,
                _name: nameBytes,
                _symbol: symbolBytes,
                _decimals: decimalsBytes
            });
    }

    function _deployProxy() internal returns (BridgedStandardERC20 token) {
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), bytes(""));
        token = BridgedStandardERC20(address(proxy));
    }

    function _init(BridgedStandardERC20 token) internal {
        bytes memory data = _encodeTokenData(abi.encode("N"), abi.encode("S"), abi.encode(uint8(18)));
        token.bridgeInitialize(assetId, originToken, data);
    }

    function test_Reinitialize_OnlyBeaconOwner_And_VersionPlusOne() public {
        BridgedStandardERC20 token = _deployProxy();
        _init(token);

        UpgradeableBeacon beacon = new UpgradeableBeacon(address(new BridgedStandardERC20()));
        address owner = address(0xABCD);
        beacon.transferOwnership(owner);

        bytes32 BEACON_SLOT = bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1);
        vm.store(address(token), BEACON_SLOT, bytes32(uint256(uint160(address(beacon)))));

        // Non-owner should revert Unauthorized
        vm.expectRevert();
        token.reinitializeToken({
            _availableGetters: BridgedStandardERC20.ERC20Getters(false, false, false),
            _newName: "NewName",
            _newSymbol: "NS",
            _version: 2
        });

        // Owner, wrong version (not +1) should revert
        vm.prank(owner);
        vm.expectRevert();
        token.reinitializeToken({
            _availableGetters: BridgedStandardERC20.ERC20Getters(false, false, false),
            _newName: "NewName",
            _newSymbol: "NS",
            _version: 3
        });

        // Owner, correct version +1 should succeed
        vm.prank(owner);
        token.reinitializeToken({
            _availableGetters: BridgedStandardERC20.ERC20Getters(false, false, false),
            _newName: "NewName",
            _newSymbol: "NS",
            _version: 2
        });

        // Values updated
        assertEq(keccak256(bytes(token.name())), keccak256(bytes("NewName")));
        assertEq(keccak256(bytes(token.symbol())), keccak256(bytes("NS")));
    }
}
