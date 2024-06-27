// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IZkSyncHyperchainBase} from "../chain-interfaces/IZkSyncHyperchainBase.sol";
import {L2CanonicalTransaction} from "../../common/Messaging.sol";

import {Diamond} from "../libraries/Diamond.sol";
import {FeeParams, PubdataPricingMode} from "../chain-deps/ZkSyncHyperchainStorage.sol";

/// @title The interface of the Admin Contract that controls access rights for contract management.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IAdmin is IZkSyncHyperchainBase {
    /// @notice Starts the transfer of admin rights. Only the current admin can propose a new pending one.
    /// @notice New admin can accept admin rights by calling `acceptAdmin` function.
    /// @param _newPendingAdmin Address of the new admin
    function setPendingAdmin(address _newPendingAdmin) external;

    /// @notice Accepts transfer of admin rights. Only pending admin can accept the role.
    function acceptAdmin() external;

    /// @notice Change validator status (active or not active)
    /// @param _validator Validator address
    /// @param _active Active flag
    function setValidator(address _validator, bool _active) external;

    /// @notice Change zk porter availability
    /// @param _zkPorterIsAvailable The availability of zk porter shard
    function setPorterAvailability(bool _zkPorterIsAvailable) external;

    /// @notice Change the max L2 gas limit for L1 -> L2 transactions
    /// @param _newPriorityTxMaxGasLimit The maximum number of L2 gas that a user can request for L1 -> L2 transactions
    function setPriorityTxMaxGasLimit(uint256 _newPriorityTxMaxGasLimit) external;

    /// @notice Change the fee params for L1->L2 transactions
    /// @param _newFeeParams The new fee params
    function changeFeeParams(FeeParams calldata _newFeeParams) external;

    /// @notice Change the token multiplier for L1->L2 transactions
    function setTokenMultiplier(uint128 _nominator, uint128 _denominator) external;

    /// @notice Change the pubdata pricing mode before the first batch is processed
    /// @param _pricingMode The new pubdata pricing mode
    function setPubdataPricingMode(PubdataPricingMode _pricingMode) external;

    /// @notice Set the transaction filterer
    function setTransactionFilterer(address _transactionFilterer) external;

    /// @notice Perform the upgrade from the current protocol version with the corresponding upgrade data
    /// @param _protocolVersion The current protocol version from which upgrade is executed
    /// @param _cutData The diamond cut parameters that is executed in the upgrade
    function upgradeChainFromVersion(uint256 _protocolVersion, Diamond.DiamondCutData calldata _cutData) external;

    /// @notice Executes a proposed governor upgrade
    /// @dev Only the current admin can execute the upgrade
    /// @param _diamondCut The diamond cut parameters to be executed
    function executeUpgrade(Diamond.DiamondCutData calldata _diamondCut) external;

    /// @notice Instantly pause the functionality of all freezable facets & their selectors
    /// @dev Only the governance mechanism may freeze Diamond Proxy
    function freezeDiamond() external;

    /// @notice Unpause the functionality of all freezable facets & their selectors
    /// @dev Both the admin and the STM can unfreeze Diamond Proxy
    function unfreezeDiamond() external;

    function genesisUpgrade(
        address _l1GenesisUpgrade,
        bytes calldata _forceDeploymentData,
        bytes[] calldata _factoryDeps
    ) external;

    /// @notice Set the L1 DA validator address as well as the L2 DA validator address.
    /// @dev While in principle it is possible that updating only one of the addresses is needed,
    /// usually these should work in pair and L1 validator typically expects a specific input from the L2 Validator.
    /// That's why we change those together to prevent shooting admins of chains from shooting themselves in the foot.
    /// @param _l1DAValidator The address of the L1 DA validator
    /// @param _l2DAValidator The address of the L2 DA validator
    function setDAValidatorPair(address _l1DAValidator, address _l2DAValidator) external;

    /// @notice Porter availability status changes
    event IsPorterAvailableStatusUpdate(bool isPorterAvailable);

    /// @notice Validator's status changed
    event ValidatorStatusUpdate(address indexed validatorAddress, bool isActive);

    /// @notice pendingAdmin is changed
    /// @dev Also emitted when new admin is accepted and in this case, `newPendingAdmin` would be zero address
    event NewPendingAdmin(address indexed oldPendingAdmin, address indexed newPendingAdmin);

    /// @notice Admin changed
    event NewAdmin(address indexed oldAdmin, address indexed newAdmin);

    /// @notice Priority transaction max L2 gas limit changed
    event NewPriorityTxMaxGasLimit(uint256 oldPriorityTxMaxGasLimit, uint256 newPriorityTxMaxGasLimit);

    /// @notice Fee params for L1->L2 transactions changed
    event NewFeeParams(FeeParams oldFeeParams, FeeParams newFeeParams);

    /// @notice Validium mode status changed
    event ValidiumModeStatusUpdate(PubdataPricingMode validiumMode);

    /// @notice The transaction filterer has been updated
    event NewTransactionFilterer(address oldTransactionFilterer, address newTransactionFilterer);

    /// @notice BaseToken multiplier for L1->L2 transactions changed
    event NewBaseTokenMultiplier(
        uint128 oldNominator,
        uint128 oldDenominator,
        uint128 newNominator,
        uint128 newDenominator
    );

    /// @notice Emitted when an upgrade is executed.
    event ExecuteUpgrade(Diamond.DiamondCutData diamondCut);

    /// TODO: maybe include some params
    event MigrationComplete();

    /// @notice Emitted when the contract is frozen.
    event Freeze();

    /// @notice Emitted when the contract is unfrozen.
    event Unfreeze();

    /// @notice New pair of DA validators set
    event NewL2DAValidator(address indexed oldL2DAValidator, address indexed newL2DAValidator);
    event NewL1DAValidator(address indexed oldL1DAValidator, address indexed newL1DAValidator);
    /// @dev emitted when an chain registers and a SetChainIdUpgrade happens
    event SetChainIdUpgrade(
        address indexed _hyperchain,
        L2CanonicalTransaction _l2Transaction,
        uint256 indexed _protocolVersion
    );

    event BridgeInitialize(address indexed l1Token, string name, string symbol, uint8 decimals);

    event BridgeMint(address indexed _account, uint256 _amount);

    function forwardedBridgeBurn(
        address _syncLayer,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable returns (bytes memory _bridgeMintData);

    function forwardedBridgeClaimFailedBurn(
        uint256 _chainId,
        bytes32 _assetInfo,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable;

    function forwardedBridgeMint(bytes calldata _data) external payable;
}
