// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable gas-custom-errors, reason-string

import {IAdmin} from "../../chain-interfaces/IAdmin.sol";
import {Diamond} from "../../libraries/Diamond.sol";
import {MAX_GAS_PER_TRANSACTION, ZKChainCommitment} from "../../../common/Config.sol";
import {FeeParams, PubdataPricingMode} from "../ZKChainStorage.sol";
import {PriorityTree} from "../../../state-transition/libraries/PriorityTree.sol";
import {PriorityQueue} from "../../../state-transition/libraries/PriorityQueue.sol";
import {ZKChainBase} from "./ZKChainBase.sol";
import {IChainTypeManager} from "../../IChainTypeManager.sol";
import {IL1GenesisUpgrade} from "../../../upgrades/IL1GenesisUpgrade.sol";
import {Unauthorized, TooMuchGas, PriorityTxPubdataExceedsMaxPubDataPerBatch, InvalidPubdataPricingMode, ProtocolIdMismatch, ChainAlreadyLive, HashMismatch, ProtocolIdNotGreater, DenominatorIsZero, DiamondAlreadyFrozen, DiamondNotFrozen} from "../../../common/L1ContractErrors.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZKChainBase} from "../../chain-interfaces/IZKChainBase.sol";

/// @title Admin Contract controls access rights for contract management.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract AdminFacet is ZKChainBase, IAdmin {
    using PriorityTree for PriorityTree.Tree;
    using PriorityQueue for PriorityQueue.Queue;

    /// @inheritdoc IZKChainBase
    string public constant override getName = "AdminFacet";

    /// @notice The chain id of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 internal immutable L1_CHAIN_ID;

    constructor(uint256 _l1ChainId) {
        L1_CHAIN_ID = _l1ChainId;
    }

    modifier onlyL1() {
        require(block.chainid == L1_CHAIN_ID, "AdminFacet: not L1");
        _;
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
    function setPriorityTxMaxGasLimit(uint256 _newPriorityTxMaxGasLimit) external onlyChainTypeManager {
        if (_newPriorityTxMaxGasLimit > MAX_GAS_PER_TRANSACTION) {
            revert TooMuchGas();
        }

        uint256 oldPriorityTxMaxGasLimit = s.priorityTxMaxGasLimit;
        s.priorityTxMaxGasLimit = _newPriorityTxMaxGasLimit;
        emit NewPriorityTxMaxGasLimit(oldPriorityTxMaxGasLimit, _newPriorityTxMaxGasLimit);
    }

    /// @inheritdoc IAdmin
    function changeFeeParams(FeeParams calldata _newFeeParams) external onlyAdminOrChainTypeManager onlyL1 {
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

        s.feeParams = _newFeeParams;

        emit NewFeeParams(oldFeeParams, _newFeeParams);
    }

    /// @inheritdoc IAdmin
    function setTokenMultiplier(uint128 _nominator, uint128 _denominator) external onlyAdminOrChainTypeManager {
        if (_denominator == 0) {
            revert DenominatorIsZero();
        }
        uint128 oldNominator = s.baseTokenGasPriceMultiplierNominator;
        uint128 oldDenominator = s.baseTokenGasPriceMultiplierDenominator;

        s.baseTokenGasPriceMultiplierNominator = _nominator;
        s.baseTokenGasPriceMultiplierDenominator = _denominator;

        emit NewBaseTokenMultiplier(oldNominator, oldDenominator, _nominator, _denominator);
    }

    /// @inheritdoc IAdmin
    function setPubdataPricingMode(PubdataPricingMode _pricingMode) external onlyAdmin onlyL1 {
        // Validium mode can be set only before the first batch is processed
        if (s.totalBatchesCommitted != 0) {
            revert ChainAlreadyLive();
        }
        s.feeParams.pubdataPricingMode = _pricingMode;
        emit ValidiumModeStatusUpdate(_pricingMode);
    }

    /// @inheritdoc IAdmin
    function setTransactionFilterer(address _transactionFilterer) external onlyAdmin onlyL1 {
        address oldTransactionFilterer = s.transactionFilterer;
        s.transactionFilterer = _transactionFilterer;
        emit NewTransactionFilterer(oldTransactionFilterer, _transactionFilterer);
    }

    /// @notice Sets the DA validator pair with the given addresses.
    /// @dev It does not check for these addresses to be non-zero, since when migrating to a new settlement
    /// layer, we set them to zero.
    function _setDAValidatorPair(address _l1DAValidator, address _l2DAValidator) internal {
        emit NewL1DAValidator(s.l1DAValidator, _l1DAValidator);
        emit NewL2DAValidator(s.l2DAValidator, _l2DAValidator);

        s.l1DAValidator = _l1DAValidator;
        s.l2DAValidator = _l2DAValidator;
    }

    /// @inheritdoc IAdmin
    function setDAValidatorPair(address _l1DAValidator, address _l2DAValidator) external onlyAdmin {
        require(_l1DAValidator != address(0), "AdminFacet: L1DAValidator address is zero");
        require(_l2DAValidator != address(0), "AdminFacet: L2DAValidator address is zero");

        _setDAValidatorPair(_l1DAValidator, _l2DAValidator);
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

    /*//////////////////////////////////////////////////////////////
                            CHAIN MIGRATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdmin
    function forwardedBridgeBurn(
        address _settlementLayer,
        address _originalCaller,
        bytes calldata _data
    ) external payable override onlyBridgehub returns (bytes memory chainBridgeMintData) {
        require(s.settlementLayer == address(0), "Af: already migrated");
        require(_originalCaller == s.admin, "Af: not chainAdmin");
        // As of now all we need in this function is the chainId so we encode it and pass it down in the _chainData field
        uint256 protocolVersion = abi.decode(_data, (uint256));

        uint256 currentProtocolVersion = s.protocolVersion;

        require(currentProtocolVersion == protocolVersion, "CTM: protocolVersion not up to date");

        if (block.chainid != L1_CHAIN_ID) {
            // We assume that GW -> L1 transactions can never fail and provide no recovery mechanism from it.
            // That's why we need to bound the gas that can be consumed during such a migration.
            require(s.totalBatchesCommitted == s.totalBatchesExecuted, "Af: not all batches executed");
        }

        s.settlementLayer = _settlementLayer;
        chainBridgeMintData = abi.encode(prepareChainCommitment());
    }

    /// @inheritdoc IAdmin
    function forwardedBridgeMint(
        bytes calldata _data,
        bool _contractAlreadyDeployed
    ) external payable override onlyBridgehub {
        ZKChainCommitment memory _commitment = abi.decode(_data, (ZKChainCommitment));

        IChainTypeManager ctm = IChainTypeManager(s.chainTypeManager);

        uint256 currentProtocolVersion = s.protocolVersion;
        uint256 protocolVersion = ctm.protocolVersion();
        require(currentProtocolVersion == protocolVersion, "CTM: protocolVersion not up to date");

        uint256 batchesExecuted = _commitment.totalBatchesExecuted;
        uint256 batchesVerified = _commitment.totalBatchesVerified;
        uint256 batchesCommitted = _commitment.totalBatchesCommitted;

        s.totalBatchesCommitted = batchesCommitted;
        s.totalBatchesVerified = batchesVerified;
        s.totalBatchesExecuted = batchesExecuted;

        // Some consistency checks just in case.
        require(batchesExecuted <= batchesVerified, "Executed is not consistent with verified");
        require(batchesVerified <= batchesCommitted, "Verified is not consistent with committed");

        // In the worst case, we may need to revert all the committed batches that were not executed.
        // This means that the stored batch hashes should be stored for [batchesExecuted; batchesCommitted] batches, i.e.
        // there should be batchesCommitted - batchesExecuted + 1 hashes.
        require(
            _commitment.batchHashes.length == batchesCommitted - batchesExecuted + 1,
            "Invalid number of batch hashes"
        );

        // Note that this part is done in O(N), i.e. it is the responsibility of the admin of the chain to ensure that the total number of
        // outstanding committed batches is not too long.
        uint256 length = _commitment.batchHashes.length;
        for (uint256 i = 0; i < length; ++i) {
            s.storedBatchHashes[batchesExecuted + i] = _commitment.batchHashes[i];
        }

        if (block.chainid == L1_CHAIN_ID) {
            // L1 PTree contains all L1->L2 transactions.
            require(
                s.priorityTree.isHistoricalRoot(
                    _commitment.priorityTree.sides[_commitment.priorityTree.sides.length - 1]
                ),
                "Admin: not historical root"
            );
            require(_contractAlreadyDeployed, "Af: contract not deployed");
            require(s.settlementLayer != address(0), "Af: not migrated");
            s.priorityTree.checkL1Reinit(_commitment.priorityTree);
        } else if (_contractAlreadyDeployed) {
            require(s.settlementLayer != address(0), "Af: not migrated 2");
            s.priorityTree.checkGWReinit(_commitment.priorityTree);
            s.priorityTree.initFromCommitment(_commitment.priorityTree);
        } else {
            s.priorityTree.initFromCommitment(_commitment.priorityTree);
        }

        s.l2SystemContractsUpgradeTxHash = _commitment.l2SystemContractsUpgradeTxHash;
        s.l2SystemContractsUpgradeBatchNumber = _commitment.l2SystemContractsUpgradeBatchNumber;

        // Set the settlement to 0 - as this is the current settlement chain.
        s.settlementLayer = address(0);

        _setDAValidatorPair(address(0), address(0));

        emit MigrationComplete();
    }

    /// @inheritdoc IAdmin
    function forwardedBridgeRecoverFailedTransfer(
        uint256 /* _chainId */,
        bytes32 /* _assetInfo */,
        address _depositSender,
        bytes calldata _chainData
    ) external payable override onlyBridgehub {
        // As of now all we need in this function is the chainId so we encode it and pass it down in the _chainData field
        uint256 protocolVersion = abi.decode(_chainData, (uint256));

        require(s.settlementLayer != address(0), "Af: not migrated");
        // Sanity check that the _depositSender is the chain admin.
        require(_depositSender == s.admin, "Af: not chainAdmin");

        uint256 currentProtocolVersion = s.protocolVersion;

        require(currentProtocolVersion == protocolVersion, "CTM: protocolVersion not up to date");

        s.settlementLayer = address(0);
    }

    /// @notice Returns the commitment for a chain.
    /// @dev Note, that this is a getter method helpful for debugging and should not be relied upon by clients.
    /// @return commitment The commitment for the chain.
    function prepareChainCommitment() public view returns (ZKChainCommitment memory commitment) {
        require(s.priorityQueue.getFirstUnprocessedPriorityTx() >= s.priorityTree.startIndex, "PQ not ready");

        commitment.totalBatchesCommitted = s.totalBatchesCommitted;
        commitment.totalBatchesVerified = s.totalBatchesVerified;
        commitment.totalBatchesExecuted = s.totalBatchesExecuted;
        commitment.l2SystemContractsUpgradeBatchNumber = s.l2SystemContractsUpgradeBatchNumber;
        commitment.l2SystemContractsUpgradeTxHash = s.l2SystemContractsUpgradeTxHash;
        commitment.priorityTree = s.priorityTree.getCommitment();

        // just in case
        require(
            commitment.totalBatchesExecuted <= commitment.totalBatchesVerified,
            "Verified is not consistent with executed"
        );
        require(
            commitment.totalBatchesVerified <= commitment.totalBatchesCommitted,
            "Verified is not consistent with committed"
        );

        uint256 blocksToRemember = commitment.totalBatchesCommitted - commitment.totalBatchesExecuted + 1;

        bytes32[] memory batchHashes = new bytes32[](blocksToRemember);

        for (uint256 i = 0; i < blocksToRemember; ++i) {
            unchecked {
                batchHashes[i] = s.storedBatchHashes[commitment.totalBatchesExecuted + i];
            }
        }

        commitment.batchHashes = batchHashes;
    }
}
