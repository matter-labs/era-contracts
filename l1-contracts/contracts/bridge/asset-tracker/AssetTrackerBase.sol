// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";

import {IAssetTrackerBase, MAX_TOKEN_BALANCE} from "./IAssetTrackerBase.sol";
import {TokenBalanceMigrationData} from "../../common/Messaging.sol";

import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {Unauthorized} from "../../common/L1ContractErrors.sol";
import {DynamicIncrementalMerkleMemory} from "../../common/libraries/DynamicIncrementalMerkleMemory.sol";
import {SERVICE_TRANSACTION_SENDER} from "../../common/Config.sol";
import {AssetHandlerModifiers} from "../interfaces/AssetHandlerModifiers.sol";
import {InsufficientChainBalance} from "./AssetTrackerErrors.sol";
import {IAssetTrackerDataEncoding} from "./IAssetTrackerDataEncoding.sol";

abstract contract AssetTrackerBase is
    IAssetTrackerBase,
    Ownable2StepUpgradeable,
    AssetHandlerModifiers,
    ReentrancyGuard
{
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;

    /// @notice Maps token balances for each chain to prevent unauthorized spending across ZK chains.
    /// NOTE: this function may be removed in the future, don't rely on it!
    /// @dev On L1AssetTracker:
    /// - For token origin chains (or their settlement layer if they are connected to a settlement layer), the balance starts at type(uint256).max.
    /// - Note that this balance is tracked even for tokens from L1, it is just that their `chainId` is `block.chainid`.
    /// - A chain can spend its balance when finalizing withdrawals/claiming failed deposits or when migrating the balance to the settlement layer.
    /// - A chain can increase its balance when deposits are made to the chain or when migrating the balance from the settlement layer.
    /// @dev On GWAssetTracker:
    /// - For each assetId, the sum of chainBalance[chainId][assetId] across all chains is less than or equal to
    ///  chainBalance[settlementLayerId][assetId] on L1AssetTracker, i.e., all tokens are backed by the settlement layer's balance on L1.
    /// - Chains spend their balances when submitting withdrawals, processing failed deposits or sending tokens via interop.
    /// - The balances are increased when deposits are made to the chains and when they receive interop from other chains.
    /// - Also, the balances are increased or decreased when migrating the balance to/from the settlement layer.
    /// @dev On L2AssetTracker:
    /// - The `chainBalance` is only used to track the balance of native tokens on the L2.
    /// - For all the other tokens it is expected to be 0.
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) public chainBalance;

    /// @notice Tracks the migration number of each asset on each chain. If the migration number is the same
    /// as the current migration number of the chain, then the token balance has been migrated to the settlement layer.
    /// If it is not, bridging it may be restricted.
    /// @dev On L1AssetTracker it is mainly used as a nullifier to ensure that the token migrations are not replayed.
    /// @dev On GWAssetTracker it is mainly used as a nullifier to ensure that the token migrations are not replayed.
    /// @dev On L2AssetTracker it is used to block withdrawals:
    /// - If a chain settles on GW, it blocks withdrawals or interop until the token balance has been migrated to GW.
    /// - If a chain settles on L1, it is mostly unused since withdrawals are always allowed.
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 migrationNumber)) public assetMigrationNumber;

    /// NOTE: this mapping may be removed in the future, don't rely on it!
    mapping(bytes32 assetId => bool maxChainBalanceAssigned) internal maxChainBalanceAssigned;

    function _nativeTokenVault() internal view virtual returns (INativeTokenVaultBase);

    modifier onlyServiceTransactionSender() {
        require(msg.sender == SERVICE_TRANSACTION_SENDER, Unauthorized(msg.sender));
        _;
    }

    modifier onlyNativeTokenVault() {
        require(msg.sender == address(_nativeTokenVault()), Unauthorized(msg.sender));
        _;
    }

    /// @notice Checks if a token has been migrated on the current chain.
    /// @dev This is a convenience function that checks migration status for the current chain.
    /// @param _assetId The asset ID of the token to check.
    /// @return bool True if the token has been migrated, false otherwise.
    function tokenMigratedThisChain(bytes32 _assetId) external view returns (bool) {
        return tokenMigrated(block.chainid, _assetId);
    }

    /// @notice Checks if a token has been migrated on a specific chain.
    /// @dev Compares the asset's migration number with the chain's current migration number.
    /// @param _chainId The chain ID to check migration status for.
    /// @param _assetId The asset ID of the token to check.
    /// @return bool True if the token has been migrated, false otherwise.
    function tokenMigrated(uint256 _chainId, bytes32 _assetId) public view returns (bool) {
        return assetMigrationNumber[_chainId][_assetId] == _getChainMigrationNumber(_chainId);
    }

    /// @notice Determines if a token can skip migration on the settlement layer.
    /// @dev If we are bridging the token for the first time, then we are allowed to bridge it, and set the assetMigrationNumber.
    /// @dev Note it might be the case that the token was deposited and all the supply was withdrawn, and the token balance was never migrated.
    /// @dev It is still ok to bridge in this case, since the chainBalance does not need to be migrated, and we set the assetMigrationNumber on the GW and the L2 manually.
    /// @param _chainId The chain ID to check.
    /// @param _assetId The asset ID to check.
    /// @return bool True if migration can be skipped, false otherwise.
    function _tokenCanSkipMigrationOnSettlementLayer(uint256 _chainId, bytes32 _assetId) internal view returns (bool) {
        uint256 savedAssetMigrationNumber = assetMigrationNumber[_chainId][_assetId];
        return savedAssetMigrationNumber == 0 && chainBalance[_chainId][_assetId] == 0;
    }

    /// @notice Forces the asset migration number to be set to the current chain migration number.
    /// @dev This is used when we want to mark a token as migrated without going through the normal migration process.
    /// @dev Force-set the asset's migration number to the chain's current migration number.
    /// @param _chainId The chain ID for which to set the migration number.
    /// @param _assetId The asset ID for which to set the migration number.
    function _forceSetAssetMigrationNumber(uint256 _chainId, bytes32 _assetId) internal {
        assetMigrationNumber[_chainId][_assetId] = _getChainMigrationNumber(_chainId);
    }

    /*//////////////////////////////////////////////////////////////
                    Register token
    //////////////////////////////////////////////////////////////*/

    function registerNewToken(bytes32 _assetId, uint256 _originChainId) public virtual;

    function _assignMaxChainBalance(uint256 _originChainId, bytes32 _assetId) internal virtual {
        chainBalance[_originChainId][_assetId] = MAX_TOKEN_BALANCE;
        maxChainBalanceAssigned[_assetId] = true;
    }

    /// @dev This function is used to decrease the chain balance of a token on a chain.
    /// @dev It makes debugging issues easier. Overflows don't usually happen, so there is no similar function to increase the chain balance.
    function _decreaseChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal {
        if (chainBalance[_chainId][_assetId] < _amount) {
            revert InsufficientChainBalance(_chainId, _assetId, _amount);
        }
        chainBalance[_chainId][_assetId] -= _amount;
    }

    /// @notice Sends token balance migration data to L1 through the L2->L1 messenger.
    /// @dev This function is used by L2 and Gateway to initiate migration operations on L1.
    /// @param data The migration data containing token information and amounts to migrate.
    function _sendMigrationDataToL1(TokenBalanceMigrationData memory data) internal {
        // slither-disable-next-line unused-return
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
            abi.encodeCall(IAssetTrackerDataEncoding.receiveMigrationOnL1, data)
        );
    }

    /*//////////////////////////////////////////////////////////////
                    Token deposits and withdrawals
    //////////////////////////////////////////////////////////////*/
    function _getChainMigrationNumber(uint256 _chainId) internal view virtual returns (uint256);
}
