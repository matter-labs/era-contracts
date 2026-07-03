// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";

import {IAssetTrackerBase} from "./IAssetTrackerBase.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {Unauthorized} from "../../common/L1ContractErrors.sol";
import {InsufficientChainBalance} from "./AssetTrackerErrors.sol";

abstract contract AssetTrackerBase is IAssetTrackerBase, ReentrancyGuard {
    /// @notice Maps token balances for each chain.
    /// NOTE: this mapping may be removed in the future, don't rely on it!
    /// @dev This is write-only bookkeeping kept for future use; it is not consulted by any
    /// bridging decision. Correctness of transfers is guaranteed by ZK proofs (plus 2FA on
    /// ZKsync OS chains) rather than by on-chain balance enforcement.
    /// @dev On L2AssetTracker:
    /// - The `chainBalance` is only used to track the balance of native tokens on the L2.
    /// - For all the other tokens it is expected to be 0.
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) public chainBalance;

    /// @notice Denotes whether a token is registered or not.
    /// - On L2AssetTracker, it means that the token's chainBalance is set correctly and its `totalPreV31TotalSupply` is tracked correctly.
    /// @dev Once we know that all legacy tokens have been registered (and all new ones have the corresponding logic performed automatically),
    ///  we can remove the mapping. So DONT RELY ON IT!
    mapping(bytes32 assetId => bool isAssetRegistered) public isAssetRegistered;

    function _nativeTokenVault() internal view virtual returns (INativeTokenVaultBase);

    modifier onlyNativeTokenVault() {
        require(msg.sender == address(_nativeTokenVault()), Unauthorized(msg.sender));
        _;
    }

    /*//////////////////////////////////////////////////////////////
                    Register token
    //////////////////////////////////////////////////////////////*/

    function registerNewTokenIfNeeded(bytes32 _assetId, uint256 _originChainId) public virtual;

    /// @dev This function is used to decrease the chain balance of a token on a chain.
    /// @dev It makes debugging issues easier. Overflows don't usually happen, so there is no similar function to increase the chain balance.
    function _decreaseChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal {
        if (chainBalance[_chainId][_assetId] < _amount) {
            revert InsufficientChainBalance(_chainId, _assetId, _amount);
        }
        chainBalance[_chainId][_assetId] -= _amount;
    }
}
