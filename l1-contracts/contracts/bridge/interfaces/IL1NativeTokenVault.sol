// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL1SharedBridge} from "./IL1SharedBridge.sol";

/// @title L1 Native token vault contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1NativeTokenVault {
    function L1_SHARED_BRIDGE() external view returns (IL1SharedBridge);

    function registerToken(address _l1Token) external;

    function getAssetIdFromLegacy(address l1TokenAddress) external view returns (bytes32);

    function getAssetId(address l1TokenAddress) external view returns (bytes32);

    function getERC20Getters(address _token) external view returns (bytes memory);

    function tokenAddress(bytes32 assetId) external view returns (address);
}
