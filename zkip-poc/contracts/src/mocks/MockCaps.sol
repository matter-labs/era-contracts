// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CapExceeded, OnlyRegistry, RegistryAlreadySet} from "../ZKIPLiteErrors.sol";

/// @notice Mock of L1NativeTokenVault's per-chain caps, isolating the registry from the vault: `deposit` and
/// `withdraw` stand in for the vault's per-chain deposit and withdrawal accounting, and the registry's `lock` and
/// `unlock` move value between a chain's public cap and its private ZKIP interop balance.
contract MockCaps {
    address public registry;
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 amount)) public cap;

    event CapChanged(uint256 indexed chainId, bytes32 indexed assetId, uint256 newCap);


    function setRegistry(address _registry) external {
        require(registry == address(0), RegistryAlreadySet());
        registry = _registry;
    }

    function deposit(uint256 _chainId, bytes32 _assetId, uint256 _amount) external {
        _set(_chainId, _assetId, cap[_chainId][_assetId] + _amount);
    }

    function withdraw(uint256 _chainId, bytes32 _assetId, uint256 _amount) external {
        _spend(_chainId, _assetId, _amount);
    }

    function lock(uint256 _chainId, bytes32 _assetId, uint256 _amount) external {
        require(msg.sender == registry, OnlyRegistry());
        _spend(_chainId, _assetId, _amount);
    }

    function unlock(uint256 _chainId, bytes32 _assetId, uint256 _amount) external {
        require(msg.sender == registry, OnlyRegistry());
        _set(_chainId, _assetId, cap[_chainId][_assetId] + _amount);
    }

    function _spend(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal {
        uint256 current = cap[_chainId][_assetId];
        require(current >= _amount, CapExceeded(_chainId, _assetId, current, _amount));
        _set(_chainId, _assetId, current - _amount);
    }

    function _set(uint256 _chainId, bytes32 _assetId, uint256 _value) internal {
        cap[_chainId][_assetId] = _value;
        emit CapChanged(_chainId, _assetId, _value);
    }
}
