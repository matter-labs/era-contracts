// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {BalanceChange, ConfirmBalanceMigrationData} from "../../common/Messaging.sol";

interface IGWAssetTracker {
    function setAddresses(uint256 _l1ChainId) external;

    function handleChainBalanceIncreaseOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        BalanceChange calldata _balanceChange
    ) external;

    function processLogsAndMessages(ProcessLogsInput calldata) external;

    function initiateGatewayToL1MigrationOnGateway(uint256 _chainId, bytes32 _assetId) external;

    function confirmMigrationOnGateway(ConfirmBalanceMigrationData calldata _tokenBalanceMigrationData) external;

    function setLegacySharedBridgeAddress(uint256 _chainId, address _legacySharedBridgeAddress) external;

    function requestPauseDepositsForChain(uint256 _chainId) external;
}
