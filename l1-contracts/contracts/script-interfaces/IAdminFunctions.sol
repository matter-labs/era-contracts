// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {L2DACommitmentScheme, PubdataPricingMode} from "contracts/common/Config.sol";

/// Per-env list of contracts that can appear as the current owner of a CTM /
/// ProxyAdmin and need their calls wrapped (since they have no private key)
/// when running ownership-transfer pre-steps on a real chain. `kind` is a
/// uint8 (instead of an enum) so the ABI is a plain `(address,uint8)` tuple
/// — easy to encode from Rust and trivial to extend.
///
/// Kind values:
///   - 0 = `OWNER_KIND_NONE` (placeholder; treated as "not in registry")
///   - 1 = `OWNER_KIND_LEGACY_GOVERNANCE` (legacy ZKsync `Governance.sol`,
///     wrapped via `scheduleTransparent` + `executeInstant` from EOA)
///   - 2 = `OWNER_KIND_OZ_CHAIN_ADMIN` (Ownable2Step `ChainAdmin`, wrapped
///     via `multicall` from EOA)
struct OwnerWrap {
    address ownableContract;
    uint8 kind;
}

uint8 constant OWNER_KIND_NONE = 0;
uint8 constant OWNER_KIND_LEGACY_GOVERNANCE = 1;
uint8 constant OWNER_KIND_OZ_CHAIN_ADMIN = 2;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IAdminFunctions {
    function initConfig() external;

    function governanceAcceptOwner(address governor, address target) external;

    function governanceAcceptOwnerConditional(address governor, address target) external;

    function transferOwnerConditional(address target, address newOwner) external;

    function transferOwnerSingleConditional(address target, address newOwner) external;

    function ensureCtmsAndProxyAdminsOwnedByGovernance(address bridgehub, address governance) external;

    function ensureCtmsAndProxyAdminsOwnedByGovernanceWithWraps(
        address bridgehub,
        address governance,
        OwnerWrap[] calldata wraps
    ) external;

    function governanceAcceptAdmin(address governor, address target) external;

    function chainAdminAcceptAdmin(ChainAdmin chainAdmin, address target) external;

    function chainSetTokenMultiplierSetter(
        address chainAdmin,
        address accessControlRestriction,
        address diamondProxyAddress,
        address setter
    ) external;

    function governanceExecuteCalls(bytes calldata callsToExecute, address governanceAddr) external;

    function governanceExecuteCallsDirect(bytes calldata callsToExecute, address governanceAddr) external;

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

    function upgradeChainFromCTM(address chainAddress, address adminAddr, address accessControlRestriction) external;

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
        string calldata gatewayRpcUrl,
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
