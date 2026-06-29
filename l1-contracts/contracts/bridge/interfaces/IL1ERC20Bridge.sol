// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IL1Nullifier} from "./IL1Nullifier.sol";
import {IL1NativeTokenVault} from "../ntv/IL1NativeTokenVault.sol";
import {IL1AssetRouter} from "../asset-router/IL1AssetRouter.sol";

/// @title L1 Bridge contract legacy interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Legacy Bridge interface before ZK chain migration, used for backward compatibility with ZKsync Era
interface IL1ERC20Bridge {
    function isWithdrawalFinalized(uint256 _l2BatchNumber, uint256 _l2MessageIndex) external view returns (bool);

    function finalizeWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external;

    function l2TokenAddress(address _l1Token) external view returns (address);

    function L1_NULLIFIER() external view returns (IL1Nullifier);

    function L1_ASSET_ROUTER() external view returns (IL1AssetRouter);

    function L1_NATIVE_TOKEN_VAULT() external view returns (IL1NativeTokenVault);

    function l2TokenBeacon() external view returns (address);

    function l2Bridge() external view returns (address);

    function ERA_CHAIN_ID() external view returns (uint256);

    function l2TokenProxyBytecodeHash() external view returns (bytes32);

    function depositAmount(
        address _account,
        address _l1Token,
        bytes32 _depositL2TxHash
    ) external view returns (uint256 amount);
}
