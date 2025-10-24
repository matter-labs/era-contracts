// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {FinalizeL1DepositParams} from "../../common/Messaging.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";

interface IL1AssetTracker {
    function BRIDGE_HUB() external view returns (IBridgehub);

    function handleChainBalanceIncreaseOnL1(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId
    ) external;

    function handleChainBalanceDecreaseOnL1(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId
    ) external;

    function receiveMigrationOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external;

    function migrateTokenBalanceFromNTV(uint256 _chainId, bytes32 _assetId) external;

    function consumeBalanceChange(
        uint256 _callerChainId,
        uint256 _chainId
    ) external returns (bytes32 assetId, uint256 amount);
}
