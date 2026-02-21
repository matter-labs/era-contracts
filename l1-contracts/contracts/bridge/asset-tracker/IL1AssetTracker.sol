// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {FinalizeL1DepositParams} from "../../common/Messaging.sol";
import {IBridgehubBase} from "../../core/bridgehub/IBridgehubBase.sol";

interface IL1AssetTracker {
    /// @notice Per-(chainId, assetId) migration accounting stored on L1.
    /// @param preV31ChainBalance Chain balance right before the v31 upgrade.
    /// - For non-native tokens it is exactly equal to chainBalance before the *ecosystem* upgraded to v31 (0 for new tokens).
    /// - For tokens native to the chain, we imagine that it received 2^256-1 token deposit at the inception point and so
    /// all the balances that are not present on the chain are from claimed withdrawals, i.e. for a token that was bridged
    /// before v31 it is equal to `2^256-1 - <sum of other chainBalances, including l1>`. For new tokens it is exactly `2^256-1`.
    /// @param totalDepositedFromL1 Total amount deposited from L1 to the chain since v31 accounting started. Note, that it is not
    /// just about any L1->L2 deposit, but only those that debited the chainBalance on L1 directly and it is assumed that every such
    /// deposit will be processed while the chain is still settling on L1. It is the responsibility of the chain admin to ensure that.
    /// @param totalClaimedOnL1 Total amount claimed on L1 (withdrawals and failed deposits) since v31 accounting started. Note, that it is not just
    /// about any claim, but claims that affect `chainBalance` of the chain (i.e. the respective failed deposits or withdrawals were submitted
    /// while the chain was settling on L1)).
    /// @dev It is the responsibility of the *chain* to ensure that all deposits are processed before the migration to Gateway is complete
    /// and vice versa, i.e. all deposits are either fully processed on L1 or fully processed while it settles on ZK Gateway. In case the chain violates
    /// this rule, invalid migration amount can be migrated, but it must only affect the chain and its users.
    struct InteropL1Info {
        uint256 preV31ChainBalance;
        uint256 totalDepositedFromL1;
        uint256 totalClaimedOnL1;
    }

    event PauseDepositsForChainRequested(uint256 indexed chainId, uint256 indexed settlementLayer);

    function BRIDGE_HUB() external view returns (IBridgehubBase);

    function isAssetRegistered(bytes32 _assetId) external view returns (bool);

    function handleChainBalanceIncreaseOnL1(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId
    ) external;

    function handleChainBalanceDecreaseOnL1(uint256 _chainId, bytes32 _assetId, uint256 _amount) external;

    function receiveL1ToGatewayMigrationOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external;

    function receiveGatewayToL1MigrationOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external;

    function registerLegacyToken(bytes32 _assetId) external;

    function consumeBalanceChange(
        uint256 _callerChainId,
        uint256 _chainId
    ) external returns (bytes32 assetId, uint256 amount);

    function setAddresses() external;

    function requestPauseDepositsForChainOnGateway(uint256 _chainId) external;
}
