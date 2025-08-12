// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {IAssetTrackerBase} from "./IAssetTrackerBase.sol";
import {L2_CHAIN_ASSET_HANDLER, L2_INTEROP_CENTER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";
import {Unauthorized} from "../../common/L1ContractErrors.sol";
import {IMessageRoot} from "../../bridgehub/IMessageRoot.sol";
import {DynamicIncrementalMerkleMemory} from "../../common/libraries/DynamicIncrementalMerkleMemory.sol";
import {SERVICE_TRANSACTION_SENDER} from "../../common/Config.sol";
import {AssetHandlerModifiers} from "../interfaces/AssetHandlerModifiers.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";

import {IChainAssetHandler} from "../../bridgehub/IChainAssetHandler.sol";

abstract contract AssetTrackerBase is IAssetTrackerBase, Ownable2StepUpgradeable, AssetHandlerModifiers {
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chains.
    /// NOTE: this function may be removed in the future, don't rely on it!
    /// @dev For minter chains, the balance is 0.
    /// @dev Only used on settlement layers
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) public chainBalance;

    /// @notice Used on the L2 instead of the settlement layer
    /// @dev Maps the migration number for each asset on the L2.
    /// Needs to be equal to the migration number of the chain for the token to be bridgeable.
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 migrationNumber)) internal assetMigrationNumber;
    function _l1ChainId() internal view virtual returns (uint256);

    function _bridgehub() internal view virtual returns (IBridgehub);

    function _nativeTokenVault() internal view virtual returns (INativeTokenVault);

    function _messageRoot() internal view virtual returns (IMessageRoot);

    modifier onlyL1() {
        require(block.chainid == _l1ChainId(), Unauthorized(msg.sender));
        _;
    }

    modifier onlyChainAdmin() {
        // require(msg.sender == , Unauthorized(msg.sender));
        _;
    }

    modifier onlyServiceTransactionSender() {
        require(msg.sender == SERVICE_TRANSACTION_SENDER, Unauthorized(msg.sender));
        _;
    }

    modifier onlyNativeTokenVaultOrInteropCenter() {
        require(
            msg.sender == address(_nativeTokenVault()) || msg.sender == L2_INTEROP_CENTER_ADDR,
            Unauthorized(msg.sender)
        );
        _;
    }

    modifier onlyNativeTokenVault() {
        require(msg.sender == address(_nativeTokenVault()), Unauthorized(msg.sender));
        _;
    }

    function tokenMigratedThisChain(bytes32 _assetId) external view returns (bool) {
        return tokenMigrated(block.chainid, _assetId);
    }

    function tokenMigrated(uint256 _chainId, bytes32 _assetId) public view returns (bool) {
        return assetMigrationNumber[_chainId][_assetId] == _getMigrationNumber(_chainId);
    }

    /*//////////////////////////////////////////////////////////////
                    Register token
    //////////////////////////////////////////////////////////////*/

    function registerLegacyTokenOnChain(bytes32 _assetId) external {
        _registerTokenOnL2(_assetId);
    }

    function registerNewToken(bytes32 _assetId, uint256) external {
        // isMinterChain[_originChainId][_assetId] = true;
        /// todo call from ntv only probably
        /// todo figure out L1 vs L2 differences
        if (block.chainid == _l1ChainId()) {
            // _registerTokenOnL1(_assetId);
        } else {
            _registerTokenOnL2(_assetId);
        }
    }

    // function _registerTokenOnL1(bytes32 _assetId) internal {
    // }

    // function _registerTokenOnGateway(bytes32 _assetId) internal {
    // }

    function _registerTokenOnL2(bytes32 _assetId) internal {
        assetMigrationNumber[block.chainid][_assetId] = L2_CHAIN_ASSET_HANDLER.getMigrationNumber(block.chainid);
    }

    /*//////////////////////////////////////////////////////////////
                    Token deposits and withdrawals
    //////////////////////////////////////////////////////////////*/
    function _getMigrationNumber(uint256 _chainId) internal view returns (uint256) {
        return IChainAssetHandler(IBridgehub(_bridgehub()).chainAssetHandler()).getMigrationNumber(_chainId);
    }
}
