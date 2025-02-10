// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {Create2} from "@openzeppelin/contracts-v4/utils/Create2.sol";
import {IBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";

import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {NativeTokenVault} from "contracts/bridge/ntv/NativeTokenVault.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";

/// @author Matter Labs
/// @notice This is used for fast debugging of the L2NTV by running it in L1 context, i.e. normal foundry instead of foundry --zksync.
contract L2NativeTokenVaultDev is L2NativeTokenVault {
    constructor(
        uint256 _l1ChainId,
        address _aliasedOwner,
        bytes32 _l2TokenProxyBytecodeHash,
        address _legacySharedBridge,
        address _bridgedTokenBeacon,
        bool _contractsDeployedAlready,
        address _wethToken,
        bytes32 _baseTokenAssetId
    )
        L2NativeTokenVault(
            _l1ChainId,
            _aliasedOwner,
            _l2TokenProxyBytecodeHash,
            _legacySharedBridge,
            _bridgedTokenBeacon,
            _contractsDeployedAlready,
            _wethToken,
            _baseTokenAssetId
        )
    {}

    /// @notice copied from L1NTV for L1 compilation
    function calculateCreate2TokenAddress(
        uint256 _originChainId,
        address _l1Token
    ) public view override(L2NativeTokenVault) returns (address) {
        bytes32 salt = _getCreate2Salt(_originChainId, _l1Token);
        return
            Create2.computeAddress(
                salt,
                keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(bridgedTokenBeacon, "")))
            );
    }

    function deployBridgedStandardERC20(address _owner) external {
        _transferOwnership(_owner);

        address l2StandardToken = address(new BridgedStandardERC20{salt: bytes32(0)}());

        UpgradeableBeacon tokenBeacon = new UpgradeableBeacon{salt: bytes32(0)}(l2StandardToken);

        tokenBeacon.transferOwnership(owner());
        bridgedTokenBeacon = IBeacon(address(tokenBeacon));
        emit L2TokenBeaconUpdated(address(bridgedTokenBeacon), L2_TOKEN_PROXY_BYTECODE_HASH);
    }

    function test() external pure {
        // test
    }

    function _deployBeaconProxy(bytes32 _salt, uint256) internal virtual override returns (BeaconProxy proxy) {
        // Use CREATE2 to deploy the BeaconProxy
        address proxyAddress = Create2.deploy(
            0,
            _salt,
            abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(bridgedTokenBeacon, ""))
        );
        return BeaconProxy(payable(proxyAddress));
    }
}
