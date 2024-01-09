// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Base} from "./Base.sol";
import {VerifierParams} from "../Storage.sol";
import {Diamond} from "../libraries/Diamond.sol";
import {PriorityQueue, PriorityOperation} from "../libraries/PriorityQueue.sol";
import {UncheckedMath} from "../../common/libraries/UncheckedMath.sol";
import {IGetters} from "../interfaces/IGetters.sol";
import {ILegacyGetters} from "../interfaces/ILegacyGetters.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IBase} from "../interfaces/IBase.sol";

/// @title Getters Contract implements functions for getting contract state from outside the blockchain.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract GettersFacet is Base, IGetters, ILegacyGetters {
    using UncheckedMath for uint256;
    using PriorityQueue for PriorityQueue.Queue;

    /// @inheritdoc IBase
    string public constant override getName = "GettersFacet";

    /*//////////////////////////////////////////////////////////////
                            CUSTOM GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGetters
    function getVerifier() external view returns (address) {
        return address(s.verifier);
    }

    /// @inheritdoc IGetters
    function getGovernor() external view returns (address) {
        return s.governor;
    }

    /// @inheritdoc IGetters
    function getPendingGovernor() external view returns (address) {
        return s.pendingGovernor;
    }

    /// @inheritdoc IGetters
    function getTotalBatchesCommitted() external view returns (uint256) {
        return s.totalBatchesCommitted;
    }

    /// @inheritdoc IGetters
    function getTotalBatchesVerified() external view returns (uint256) {
        return s.totalBatchesVerified;
    }

    /// @inheritdoc IGetters
    function getTotalBatchesExecuted() external view returns (uint256) {
        return s.totalBatchesExecuted;
    }

    /// @inheritdoc IGetters
    function getTotalPriorityTxs() external view returns (uint256) {
        return s.priorityQueue.getTotalPriorityTxs();
    }

    /// @inheritdoc IGetters
    function getFirstUnprocessedPriorityTx() external view returns (uint256) {
        return s.priorityQueue.getFirstUnprocessedPriorityTx();
    }

    /// @inheritdoc IGetters
    function getPriorityQueueSize() external view returns (uint256) {
        return s.priorityQueue.getSize();
    }

    /// @inheritdoc IGetters
    function priorityQueueFrontOperation() external view returns (PriorityOperation memory) {
        return s.priorityQueue.front();
    }

    /// @inheritdoc IGetters
    function isValidator(address _address) external view returns (bool) {
        return s.validators[_address];
    }

    /// @inheritdoc IGetters
    function l2LogsRootHash(uint256 _batchNumber) external view returns (bytes32) {
        return s.l2LogsRootHashes[_batchNumber];
    }

    /// @inheritdoc IGetters
    function storedBatchHash(uint256 _batchNumber) external view returns (bytes32) {
        return s.storedBatchHashes[_batchNumber];
    }

    /// @inheritdoc IGetters
    function getL2BootloaderBytecodeHash() external view returns (bytes32) {
        return s.l2BootloaderBytecodeHash;
    }

    /// @inheritdoc IGetters
    function getL2DefaultAccountBytecodeHash() external view returns (bytes32) {
        return s.l2DefaultAccountBytecodeHash;
    }

    /// @inheritdoc IGetters
    function getVerifierParams() external view returns (VerifierParams memory) {
        return s.verifierParams;
    }

    /// @inheritdoc IGetters
    function getProtocolVersion() external view returns (uint256) {
        return s.protocolVersion;
    }

    /// @inheritdoc IGetters
    function getL2SystemContractsUpgradeTxHash() external view returns (bytes32) {
        return s.l2SystemContractsUpgradeTxHash;
    }

    /// @inheritdoc IGetters
    function getL2SystemContractsUpgradeBatchNumber() external view returns (uint256) {
        return s.l2SystemContractsUpgradeBatchNumber;
    }

    /// @inheritdoc IGetters
    function isDiamondStorageFrozen() external view returns (bool) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        return ds.isFrozen;
    }

    /// @inheritdoc IGetters
    function isFacetFreezable(address _facet) external view returns (bool isFreezable) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();

        // There is no direct way to get whether the facet address is freezable,
        // so we get it from one of the selectors that are associated with the facet.
        uint256 selectorsArrayLen = ds.facetToSelectors[_facet].selectors.length;
        if (selectorsArrayLen != 0) {
            bytes4 selector0 = ds.facetToSelectors[_facet].selectors[0];
            isFreezable = ds.selectorToFacet[selector0].isFreezable;
        }
    }

    /// @inheritdoc IGetters
    function getPriorityTxMaxGasLimit() external view returns (uint256) {
        return s.priorityTxMaxGasLimit;
    }

    /// @inheritdoc IGetters
    function isFunctionFreezable(bytes4 _selector) external view returns (bool) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        require(ds.selectorToFacet[_selector].facetAddress != address(0), "g2");
        return ds.selectorToFacet[_selector].isFreezable;
    }

    /// @inheritdoc IGetters
    function isEthWithdrawalFinalized(uint256 _l2BatchNumber, uint256 _l2MessageIndex) external view returns (bool) {
        return s.isEthWithdrawalFinalized[_l2BatchNumber][_l2MessageIndex];
    }

    /*//////////////////////////////////////////////////////////////
                            DIAMOND LOUPE
     //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGetters
    function facets() external view returns (Facet[] memory result) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();

        uint256 facetsLen = ds.facets.length;
        result = new Facet[](facetsLen);

        for (uint256 i = 0; i < facetsLen; i = i.uncheckedInc()) {
            address facetAddr = ds.facets[i];
            Diamond.FacetToSelectors memory facetToSelectors = ds.facetToSelectors[facetAddr];

            result[i] = Facet(facetAddr, facetToSelectors.selectors);
        }
    }

    /// @inheritdoc IGetters
    function facetFunctionSelectors(address _facet) external view returns (bytes4[] memory) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        return ds.facetToSelectors[_facet].selectors;
    }

    /// @inheritdoc IGetters
    function facetAddresses() external view returns (address[] memory) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        return ds.facets;
    }

    /// @inheritdoc IGetters
    function facetAddress(bytes4 _selector) external view returns (address) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        return ds.selectorToFacet[_selector].facetAddress;
    }

    /*//////////////////////////////////////////////////////////////
                        DEPRECATED METHODS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILegacyGetters
    function getTotalBlocksCommitted() external view returns (uint256) {
        return s.totalBatchesCommitted;
    }

    /// @inheritdoc ILegacyGetters
    function getTotalBlocksVerified() external view returns (uint256) {
        return s.totalBatchesVerified;
    }

    /// @inheritdoc ILegacyGetters
    function getTotalBlocksExecuted() external view returns (uint256) {
        return s.totalBatchesExecuted;
    }

    /// @inheritdoc ILegacyGetters
    function storedBlockHash(uint256 _batchNumber) external view returns (bytes32) {
        return s.storedBatchHashes[_batchNumber];
    }

    /// @inheritdoc ILegacyGetters
    function getL2SystemContractsUpgradeBlockNumber() external view returns (uint256) {
        return s.l2SystemContractsUpgradeBatchNumber;
    }
}
