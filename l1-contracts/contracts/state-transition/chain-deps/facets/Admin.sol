// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IAdmin} from "../../chain-interfaces/IAdmin.sol";
import {IMailbox} from "../../chain-interfaces/IMailbox.sol";
import {Diamond} from "../../libraries/Diamond.sol";
import {L2DACommitmentScheme, MAX_GAS_PER_TRANSACTION, MAX_PRICE_CHANGE_DENOMINATOR, MAX_PRICE_CHANGE_NUMERATOR, PRICE_REFERENCE_L1_GAS, PRICE_UPDATE_INTERVAL, PRIORITY_EXPIRATION, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "../../../common/Config.sol";
import {FeeParams, PubdataPricingMode} from "../ZKChainStorage.sol";
import {ZKChainBase} from "./ZKChainBase.sol";
import {IChainTypeManager} from "../../IChainTypeManager.sol";
import {IL1GenesisUpgrade} from "../../../upgrades/IL1GenesisUpgrade.sol";
import {L1DAValidatorAddressIsZero, NotL1, PriorityModeAlreadyAllowed} from "../../L1StateTransitionErrors.sol";
import {AlreadyPermanentRollup, DenominatorIsZero, DiamondAlreadyFrozen, DiamondNotFrozen, FeeParamsChangeTooFrequent, FeeParamsChangeTooLarge, HashMismatch, InvalidDAForPermanentRollup, InvalidL2DACommitmentScheme, InvalidPubdataPricingMode, PriorityModeActivationTooEarly, PriorityModeIsNotAllowed, PriorityModeRequiresPermanentRollup, PriorityOpsRequestTimestampMissing, PriorityTxPubdataExceedsMaxPubDataPerBatch, ProtocolIdMismatch, ProtocolIdNotGreater, TokenMultiplierChangeTooFrequent, TooMuchGas, Unauthorized, NotCompatibleWithPriorityMode} from "../../../common/L1ContractErrors.sol";
import {RollupDAManager} from "../../data-availability/RollupDAManager.sol";
import {PriorityTree} from "../../libraries/PriorityTree.sol";
import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR} from "../../../common/l2-helpers/L2ContractAddresses.sol";
import {AllowedBytecodeTypes, IL2ContractDeployer} from "../../../common/interfaces/IL2ContractDeployer.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZKChainBase} from "../../chain-interfaces/IZKChainBase.sol";

/// @title Admin Contract controls access rights for contract management.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract AdminFacet is ZKChainBase, IAdmin {
    using PriorityTree for PriorityTree.Tree;

    /// @inheritdoc IZKChainBase
    // solhint-disable-next-line const-name-snakecase
    string public constant override getName = "AdminFacet";

    /// @notice The chain id of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 internal immutable L1_CHAIN_ID;

    /// @notice The address that is responsible for determining whether a certain DA pair is allowed for rollups.
    RollupDAManager public immutable ROLLUP_DA_MANAGER;

    constructor(uint256 _l1ChainId, RollupDAManager _rollupDAManager) {
        L1_CHAIN_ID = _l1ChainId;
        ROLLUP_DA_MANAGER = _rollupDAManager;
    }

    modifier onlyL1() {
        _onlyL1();
        _;
    }

    function _onlyL1() internal view {
        if (block.chainid != L1_CHAIN_ID) {
            revert NotL1(block.chainid);
        }
    }

    /// @inheritdoc IAdmin
    function setPendingAdmin(address _newPendingAdmin) external onlyAdmin {
        // Save previous value into the stack to put it into the event later
        address oldPendingAdmin = s.pendingAdmin;
        // Change pending admin
        s.pendingAdmin = _newPendingAdmin;
        emit NewPendingAdmin(oldPendingAdmin, _newPendingAdmin);
    }

    /// @inheritdoc IAdmin
    function acceptAdmin() external {
        address pendingAdmin = s.pendingAdmin;
        // Only proposed by current admin address can claim the admin rights
        if (msg.sender != pendingAdmin) {
            revert Unauthorized(msg.sender);
        }

        address previousAdmin = s.admin;
        s.admin = pendingAdmin;
        delete s.pendingAdmin;

        emit NewPendingAdmin(pendingAdmin, address(0));
        emit NewAdmin(previousAdmin, pendingAdmin);
    }

    /// @inheritdoc IAdmin
    function setValidator(address _validator, bool _active) external onlyChainTypeManager {
        s.validators[_validator] = _active;
        emit ValidatorStatusUpdate(_validator, _active);
    }

    /// @inheritdoc IAdmin
    function setPorterAvailability(bool _zkPorterIsAvailable) external onlyChainTypeManager {
        // Change the porter availability
        s.zkPorterIsAvailable = _zkPorterIsAvailable;
        emit IsPorterAvailableStatusUpdate(_zkPorterIsAvailable);
    }

    /// @inheritdoc IAdmin
    function setPriorityTxMaxGasLimit(uint256 _newPriorityTxMaxGasLimit) external onlyChainTypeManager onlyL1 {
        if (_newPriorityTxMaxGasLimit > MAX_GAS_PER_TRANSACTION) {
            revert TooMuchGas();
        }

        uint256 oldPriorityTxMaxGasLimit = s.priorityTxMaxGasLimit;
        s.priorityTxMaxGasLimit = _newPriorityTxMaxGasLimit;
        emit NewPriorityTxMaxGasLimit(oldPriorityTxMaxGasLimit, _newPriorityTxMaxGasLimit);
    }

    /// @inheritdoc IAdmin
    function changeFeeParams(FeeParams calldata _newFeeParams) external onlyAdminOrChainTypeManager onlyL1 {
        uint256 lastUpdateTimestamp = s.lastFeeParamsUpdateTimestamp;
        if (lastUpdateTimestamp != 0 && block.timestamp < lastUpdateTimestamp + PRICE_UPDATE_INTERVAL) {
            revert FeeParamsChangeTooFrequent(lastUpdateTimestamp + PRICE_UPDATE_INTERVAL);
        }

        // Double checking that the new fee params are valid, i.e.
        // the maximal pubdata per batch is not less than the maximal pubdata per priority transaction.
        if (_newFeeParams.maxPubdataPerBatch < _newFeeParams.priorityTxMaxPubdata) {
            revert PriorityTxPubdataExceedsMaxPubDataPerBatch();
        }

        FeeParams memory oldFeeParams = s.feeParams;

        // we cannot change pubdata pricing mode
        if (_newFeeParams.pubdataPricingMode != oldFeeParams.pubdataPricingMode) {
            revert InvalidPubdataPricingMode();
        }

        _enforcePriceIncreaseBound({
            _oldFeeParams: oldFeeParams,
            _newFeeParams: _newFeeParams,
            _oldNominator: s.baseTokenGasPriceMultiplierNominator,
            _oldDenominator: s.baseTokenGasPriceMultiplierDenominator,
            _newNominator: s.baseTokenGasPriceMultiplierNominator,
            _newDenominator: s.baseTokenGasPriceMultiplierDenominator
        });

        s.feeParams = _newFeeParams;
        s.lastFeeParamsUpdateTimestamp = block.timestamp;

        emit NewFeeParams(oldFeeParams, _newFeeParams);
    }

    /// @inheritdoc IAdmin
    function setTokenMultiplier(uint128 _nominator, uint128 _denominator) external onlyAdminOrChainTypeManager onlyL1 {
        if (_denominator == 0) {
            revert DenominatorIsZero();
        }

        uint256 lastUpdateTimestamp = s.lastTokenMultiplierUpdateTimestamp;
        if (lastUpdateTimestamp != 0 && block.timestamp < lastUpdateTimestamp + PRICE_UPDATE_INTERVAL) {
            revert TokenMultiplierChangeTooFrequent(lastUpdateTimestamp + PRICE_UPDATE_INTERVAL);
        }

        _enforcePriceIncreaseBound({
            _oldFeeParams: s.feeParams,
            _newFeeParams: s.feeParams,
            _oldNominator: s.baseTokenGasPriceMultiplierNominator,
            _oldDenominator: s.baseTokenGasPriceMultiplierDenominator,
            _newNominator: _nominator,
            _newDenominator: _denominator
        });

        uint128 oldNominator = s.baseTokenGasPriceMultiplierNominator;
        uint128 oldDenominator = s.baseTokenGasPriceMultiplierDenominator;

        s.baseTokenGasPriceMultiplierNominator = _nominator;
        s.baseTokenGasPriceMultiplierDenominator = _denominator;
        s.lastTokenMultiplierUpdateTimestamp = block.timestamp;

        emit NewBaseTokenMultiplier(oldNominator, oldDenominator, _nominator, _denominator);
    }

    function _enforcePriceIncreaseBound(
        FeeParams memory _oldFeeParams,
        FeeParams memory _newFeeParams,
        uint128 _oldNominator,
        uint128 _oldDenominator,
        uint128 _newNominator,
        uint128 _newDenominator
    ) internal pure {
        uint256 oldPrice = _safeDerivedL2GasPrice(_oldFeeParams, _oldNominator, _oldDenominator);
        uint256 newPrice = _safeDerivedL2GasPrice(_newFeeParams, _newNominator, _newDenominator);

        if (oldPrice == 0 || newPrice <= oldPrice) {
            return;
        }

        uint256 maxAllowedPrice = (oldPrice * MAX_PRICE_CHANGE_NUMERATOR) / MAX_PRICE_CHANGE_DENOMINATOR;
        if (newPrice > maxAllowedPrice) {
            revert FeeParamsChangeTooLarge(oldPrice, newPrice, maxAllowedPrice);
        }
    }

    function _safeDerivedL2GasPrice(
        FeeParams memory _feeParams,
        uint128 _multiplierNominator,
        uint128 _multiplierDenominator
    ) internal pure returns (uint256) {
        if (_multiplierDenominator == 0 || _feeParams.maxPubdataPerBatch == 0 || _feeParams.maxL2GasPerBatch == 0) {
            return 0;
        }

        return
            _deriveL2GasPriceFromParams({
                _feeParams: _feeParams,
                _multiplierNominator: _multiplierNominator,
                _multiplierDenominator: _multiplierDenominator,
                _l1GasPrice: PRICE_REFERENCE_L1_GAS,
                _gasPerPubdata: REQUIRED_L2_GAS_PRICE_PER_PUBDATA
            });
    }

    /// @inheritdoc IAdmin
    function setPubdataPricingMode(PubdataPricingMode _pricingMode) external onlyAdmin onlyL1 {
        s.feeParams.pubdataPricingMode = _pricingMode;
        emit PubdataPricingModeUpdate(_pricingMode);
    }

    /// @inheritdoc IAdmin
    function setTransactionFilterer(address _transactionFilterer) external onlyAdmin onlyL1 {
        if (s.priorityModeInfo.canBeActivated) {
            revert NotCompatibleWithPriorityMode();
        }
        _setTransactionFilterer(_transactionFilterer);
    }

    function _setTransactionFilterer(address _transactionFilterer) internal {
        address oldTransactionFilterer = s.transactionFilterer;
        s.transactionFilterer = _transactionFilterer;
        emit NewTransactionFilterer(oldTransactionFilterer, _transactionFilterer);
    }

    /// @inheritdoc IAdmin
    function getRollupDAManager() external view returns (address) {
        return address(ROLLUP_DA_MANAGER);
    }

    /// @inheritdoc IAdmin
    function setDAValidatorPair(address _l1DAValidator, L2DACommitmentScheme _l2DACommitmentScheme) external onlyAdmin {
        if (_l1DAValidator == address(0)) {
            revert L1DAValidatorAddressIsZero();
        }

        if (_l2DACommitmentScheme == L2DACommitmentScheme.NONE) {
            revert InvalidL2DACommitmentScheme(uint8(_l2DACommitmentScheme));
        }

        if (s.isPermanentRollup && !ROLLUP_DA_MANAGER.isPairAllowed(_l1DAValidator, _l2DACommitmentScheme)) {
            revert InvalidDAForPermanentRollup();
        }

        _setDAValidatorPair(_l1DAValidator, _l2DACommitmentScheme);
    }

    /// @inheritdoc IAdmin
    function makePermanentRollup() external onlyAdmin onlySettlementLayer {
        if (s.isPermanentRollup) {
            revert AlreadyPermanentRollup();
        }

        if (!ROLLUP_DA_MANAGER.isPairAllowed(s.l1DAValidator, s.l2DACommitmentScheme)) {
            // The correct data availability pair should be set beforehand.
            revert InvalidDAForPermanentRollup();
        }

        s.isPermanentRollup = true;
    }

    /// @inheritdoc IAdmin
    function setPriorityModeTransactionFilterer(
        address _priorityModeTransactionFilterer
    ) external onlyChainTypeManager onlySettlementLayer onlyL1 {
        if (s.priorityModeInfo.canBeActivated) {
            _setTransactionFilterer(_priorityModeTransactionFilterer);
        }
        emit NewPriorityModeTransactionFilterer(
            s.priorityModeInfo.transactionFilterer,
            _priorityModeTransactionFilterer
        );
        s.priorityModeInfo.transactionFilterer = _priorityModeTransactionFilterer;
    }

    /// @inheritdoc IAdmin
    function permanentlyAllowPriorityMode() external onlyAdmin onlySettlementLayer onlyL1 {
        if (s.priorityModeInfo.canBeActivated) {
            revert PriorityModeAlreadyAllowed();
        }
        // Set a transaction filterer that is compatible with Priority Mode.
        //
        // In the common case, ZK Governance does not override `priorityModeInfo.transactionFilterer`,
        // so most of the time transaction filtering will be disabled.
        //
        // For some chains (e.g., Prividium or Gateway), a custom filterer may be required
        // for correct system operation. This lets ZK Governance choose whether to remove the
        // transaction filterer entirely or set the one best suited for the special chain needs.
        _setTransactionFilterer(s.priorityModeInfo.transactionFilterer);
        s.priorityModeInfo.canBeActivated = true;
        emit PriorityModeAllowed();
    }

    /// @inheritdoc IAdmin
    function deactivatePriorityMode() external onlyPriorityMode onlyChainTypeManager onlySettlementLayer onlyL1 {
        s.priorityModeInfo.activated = false;
        emit PriorityModeDeactivated();
    }

    /// @inheritdoc IAdmin
    function activatePriorityMode() external onlySettlementLayer onlyL1 notPriorityMode nonReentrant {
        if (!s.priorityModeInfo.canBeActivated) {
            revert PriorityModeIsNotAllowed();
        }
        if (!s.isPermanentRollup) {
            revert PriorityModeRequiresPermanentRollup();
        }
        uint256 firstUnprocessedTx = s.priorityTree.getFirstUnprocessedPriorityTx();
        uint256 unprocessedTxRequestedAt = s.priorityOpsRequestTimestamp[firstUnprocessedTx];
        // A zero timestamp means we don't have a recorded "requested at" time for this priority tx.
        // This can happen when:
        //  - the priority queue is empty, or
        //  - immediately after the chain upgraded to the v31 protocol version.
        //
        // In the upgrade case, priority transactions may already exist in the contract state,
        // but `priorityOpsRequestTimestamp` has not been populated for "old" priority transactions.
        if (unprocessedTxRequestedAt == 0) {
            revert PriorityOpsRequestTimestampMissing(firstUnprocessedTx);
        }
        uint256 earliestActivationTimestamp = unprocessedTxRequestedAt + PRIORITY_EXPIRATION;
        if (block.timestamp < earliestActivationTimestamp) {
            revert PriorityModeActivationTooEarly(earliestActivationTimestamp, block.timestamp);
        }
        s.priorityModeInfo.activated = true;
        // Revert all batches that are not finalized yet to allow the `PermissionlessValidator`
        // to commit, prove, and execute batches in one go.
        _revertBatches(s.totalBatchesExecuted);
        emit PriorityModeActivated();
    }

    /// @inheritdoc IAdmin
    function allowEvmEmulation() external onlyAdmin onlyL1 returns (bytes32 canonicalTxHash) {
        canonicalTxHash = IMailbox(address(this)).requestL2ServiceTransaction(
            L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
            abi.encodeCall(IL2ContractDeployer.setAllowedBytecodeTypesToDeploy, AllowedBytecodeTypes.EraVmAndEVM)
        );
        emit EnableEvmEmulator();
    }

    /*//////////////////////////////////////////////////////////////
                            UPGRADE EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdmin
    function upgradeChainFromVersion(
        uint256 _oldProtocolVersion,
        Diamond.DiamondCutData calldata _diamondCut
    ) external onlyAdminOrChainTypeManager {
        bytes32 cutHashInput = keccak256(abi.encode(_diamondCut));
        bytes32 upgradeCutHash = IChainTypeManager(s.chainTypeManager).upgradeCutHash(_oldProtocolVersion);
        if (cutHashInput != upgradeCutHash) {
            revert HashMismatch(upgradeCutHash, cutHashInput);
        }

        if (s.protocolVersion != _oldProtocolVersion) {
            revert ProtocolIdMismatch(s.protocolVersion, _oldProtocolVersion);
        }
        Diamond.diamondCut(_diamondCut);
        emit ExecuteUpgrade(_diamondCut);
        if (s.protocolVersion <= _oldProtocolVersion) {
            revert ProtocolIdNotGreater();
        }
    }

    /// @inheritdoc IAdmin
    function executeUpgrade(Diamond.DiamondCutData calldata _diamondCut) external onlyChainTypeManager {
        Diamond.diamondCut(_diamondCut);
        emit ExecuteUpgrade(_diamondCut);
    }

    /// @dev we have to set the chainId at genesis, as blockhashzero is the same for all chains with the same chainId
    function genesisUpgrade(
        address _l1GenesisUpgrade,
        address _ctmDeployer,
        bytes calldata _forceDeploymentData,
        bytes[] calldata _factoryDeps
    ) external onlyChainTypeManager {
        Diamond.FacetCut[] memory emptyArray;
        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: emptyArray,
            initAddress: _l1GenesisUpgrade,
            initCalldata: abi.encodeCall(
                IL1GenesisUpgrade.genesisUpgrade,
                (_l1GenesisUpgrade, s.chainId, s.protocolVersion, _ctmDeployer, _forceDeploymentData, _factoryDeps)
            )
        });

        Diamond.diamondCut(cutData);
        emit ExecuteUpgrade(cutData);
    }

    /*//////////////////////////////////////////////////////////////
                            CONTRACT FREEZING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdmin
    function freezeDiamond() external onlyChainTypeManager {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        // diamond proxy is frozen already
        if (diamondStorage.isFrozen) {
            revert DiamondAlreadyFrozen();
        }
        diamondStorage.isFrozen = true;

        emit Freeze();
    }

    /// @inheritdoc IAdmin
    function unfreezeDiamond() external onlyChainTypeManager {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        // diamond proxy is not frozen
        if (!diamondStorage.isFrozen) {
            revert DiamondNotFrozen();
        }
        diamondStorage.isFrozen = false;

        emit Unfreeze();
    }
}
