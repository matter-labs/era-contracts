// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {PubdataPricingMode, L2DACommitmentScheme} from "contracts/common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IAdminFunctions {
    function initConfig() external;

    function governanceAcceptOwner(address governor, address target) external;

    function governanceAcceptAdmin(address governor, address target) external;

    function chainAdminAcceptAdmin(ChainAdmin chainAdmin, address target) external;

    function chainSetTokenMultiplierSetter(
        address chainAdmin,
        address accessControlRestriction,
        address diamondProxyAddress,
        address setter
    ) external;

    function governanceExecuteCalls(bytes calldata callsToExecute, address governanceAddr) external;

    function ecosystemAdminExecuteCalls(bytes calldata callsToExecute, address ecosystemAdminAddr) external;

    function adminEncodeMulticall(bytes calldata callsToExecute) external;

    function adminExecuteUpgrade(
        bytes calldata diamondCut,
        address adminAddr,
        address accessControlRestriction,
        address chainDiamondProxy
    ) external;

    function adminScheduleUpgrade(
        address adminAddr,
        address accessControlRestriction,
        uint256 newProtocolVersion,
        uint256 timestamp
    ) external;

    function upgradeChainFromCTM(
        address chainAddress,
        address ctmAddress,
        address adminAddr,
        address accessControlRestriction
    ) external;

    function makePermanentRollup(ChainAdmin chainAdmin, address target) external;

    function updateValidator(
        address adminAddr,
        address accessControlRestriction,
        address validatorTimelock,
        uint256 chainId,
        address validatorAddress,
        bool addValidator
    ) external;

    function addL2WethToStore(
        address storeAddress,
        ChainAdmin ecosystemAdmin,
        uint256 chainId,
        address l2WBaseToken
    ) external;

    function setPubdataPricingMode(ChainAdmin chainAdmin, address target, PubdataPricingMode pricingMode) external;

    function notifyServerMigrationToGateway(address bridgehub, uint256 chainId, bool shouldSend) external;

    function notifyServerMigrationFromGateway(address bridgehub, uint256 chainId, bool shouldSend) external;

    function prepareUpgradeZKChainOnGateway(
        uint256 l1GasPrice,
        uint256 oldProtocolVersion,
        bytes calldata upgradeCutData,
        address chainDiamondProxyOnGateway,
        uint256 gatewayChainId,
        uint256 chainId,
        address bridgehub,
        address l1AssetRouterProxy,
        address refundRecipient,
        bool shouldSend
    ) external;

    function grantGatewayWhitelist(
        address bridgehub,
        uint256 chainId,
        address[] calldata grantees,
        bool shouldSend
    ) external;

    function revokeGatewayWhitelist(address bridgehub, uint256 chainId, address toRevoke, bool shouldSend) external;

    function setTransactionFilterer(
        address bridgehub,
        uint256 chainId,
        address transactionFiltererAddress,
        bool shouldSend
    ) external;

    function pauseDepositsBeforeInitiatingMigration(address bridgehub, uint256 chainId, bool shouldSend) external;

    function unpauseDeposits(address bridgehub, uint256 chainId, bool shouldSend) external;

    function setDAValidatorPair(
        address bridgehub,
        uint256 chainId,
        address l1DaValidator,
        L2DACommitmentScheme l2DaCommitmentScheme,
        bool shouldSend
    ) external;

    function migrateChainToGateway(
        address bridgehub,
        uint256 l1GasPrice,
        uint256 l2ChainId,
        uint256 gatewayChainId,
        bytes calldata gatewayDiamondCutData,
        address refundRecipient,
        bool shouldSend
    ) external;

    function setDAValidatorPairWithGateway(
        address bridgehub,
        uint256 l1GasPrice,
        uint256 l2ChainId,
        uint256 gatewayChainId,
        address l1DAValidator,
        L2DACommitmentScheme l2DACommitmentScheme,
        address chainDiamondProxyOnGateway,
        address refundRecipient,
        bool shouldSend
    ) external;

    function enableValidatorViaGateway(
        address bridgehub,
        uint256 l1GasPrice,
        uint256 l2ChainId,
        uint256 gatewayChainId,
        address validatorAddress,
        address gatewayValidatorTimelock,
        address refundRecipient,
        bool shouldSend
    ) external;

    function enableValidator(
        address bridgehub,
        uint256 l2ChainId,
        address validatorAddress,
        address validatorTimelock,
        bool shouldSend
    ) external;

    function startMigrateChainFromGateway(
        address bridgehub,
        uint256 l1GasPrice,
        uint256 l2ChainId,
        uint256 gatewayChainId,
        bytes calldata l1DiamondCutData,
        address refundRecipient,
        bool shouldSend
    ) external;

    function adminL1L2Tx(
        address bridgehub,
        uint256 l1GasPrice,
        uint256 chainId,
        address to,
        uint256 value,
        bytes calldata data,
        address refundRecipient,
        bool shouldSend
    ) external;
}
