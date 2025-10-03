// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";

import {IAssetTrackerBase, MAX_TOKEN_BALANCE} from "./IAssetTrackerBase.sol";
import {TokenBalanceMigrationData} from "../../common/Messaging.sol";

import {L2_INTEROP_CENTER_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {Unauthorized} from "../../common/L1ContractErrors.sol";
import {IMessageRoot} from "../../bridgehub/IMessageRoot.sol";
import {DynamicIncrementalMerkleMemory} from "../../common/libraries/DynamicIncrementalMerkleMemory.sol";
import {SERVICE_TRANSACTION_SENDER} from "../../common/Config.sol";
import {AssetHandlerModifiers} from "../interfaces/AssetHandlerModifiers.sol";
import {IBridgehubBase} from "../../bridgehub/IBridgehubBase.sol";
import {InsufficientChainBalance} from "./AssetTrackerErrors.sol";
import {IAssetTrackerDataEncoding} from "./IAssetTrackerDataEncoding.sol";

abstract contract AssetTrackerBase is
    IAssetTrackerBase,
    Ownable2StepUpgradeable,
    AssetHandlerModifiers,
    ReentrancyGuard
{
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chains.
    /// NOTE: this function may be removed in the future, don't rely on it!
    /// @dev For token origin chains, the balance starts at type(uint256).max, and decreases as withdrawals are made from the chain.
    /// @dev On L1 the chainBalance for non origin chains equals the total supply of the token on the chain and unfinalized withdrawals to L1.
    /// @dev On Gateway the chainBalance for non origin chains equals the total supply of the token on the chain.
    /// @dev On non-Gateway L2s this mapping is only used to track the balance of native tokens.
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) public chainBalance;

    /// @notice Used on the L2 instead of the settlement layer
    /// @dev Maps the migration number for each asset on the L2.
    /// Needs to be equal to the migration number of the chain for the token to be bridgeable.
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 migrationNumber)) public assetMigrationNumber;

    function _l1ChainId() internal view virtual returns (uint256);

    function _bridgehub() internal view virtual returns (IBridgehubBase);

    function _nativeTokenVault() internal view virtual returns (INativeTokenVaultBase);

    function _messageRoot() internal view virtual returns (IMessageRoot);

    modifier onlyL1() {
        require(block.chainid == _l1ChainId(), Unauthorized(msg.sender));
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
        return assetMigrationNumber[_chainId][_assetId] == _getChainMigrationNumber(_chainId);
    }

    /// If we are bridging the token for the first time, then we are allowed to bridge it, and set the assetMigrationNumber.
    /// Note it might be the case that the token was deposited and all the supply was withdrawn, and the token balance was never migrated.
    /// It is still ok to bridge in this case, since the chainBalance does not need to be migrated, and we set the assetMigrationNumber manually on the GW and the L2 manually.
    function _tokenCanSkipMigrationOnSettlementLayer(uint256 _chainId, bytes32 _assetId) internal view returns (bool) {
        uint256 savedAssetMigrationNumber = assetMigrationNumber[_chainId][_assetId];
        return savedAssetMigrationNumber == 0 && chainBalance[_chainId][_assetId] == 0;
    }

    function _forceSetAssetMigrationNumber(uint256 _chainId, bytes32 _assetId) internal {
        assetMigrationNumber[_chainId][_assetId] = _getChainMigrationNumber(_chainId);
    }

    /*//////////////////////////////////////////////////////////////
                    Register token
    //////////////////////////////////////////////////////////////*/

    function registerNewToken(bytes32 _assetId, uint256 _originChainId) public virtual;

    function _assignMaxChainBalance(uint256 _originChainId, bytes32 _assetId) internal virtual {
        chainBalance[_originChainId][_assetId] = MAX_TOKEN_BALANCE;
    }

    /// @dev This function is used to decrease the chain balance of a token on a chain.
    /// @dev It makes debugging issues easier. Overflows don't usually happen, so there is no similar function to increase the chain balance.
    function _decreaseChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal {
        if (chainBalance[_chainId][_assetId] < _amount) {
            revert InsufficientChainBalance(_chainId, _assetId, _amount);
        }
        chainBalance[_chainId][_assetId] -= _amount;
    }

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
