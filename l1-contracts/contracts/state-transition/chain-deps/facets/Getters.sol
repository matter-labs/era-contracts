// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";
import {ISelfDescribingFacet} from "../../chain-interfaces/ISelfDescribingFacet.sol";

import {ZKChainBase} from "./ZKChainBase.sol";
import {PubdataPricingMode} from "../ZKChainStorage.sol";
import {VerifierParams} from "../../../state-transition/chain-interfaces/IVerifier.sol";
import {Diamond} from "../../libraries/Diamond.sol";
import {PriorityTree} from "../../../state-transition/libraries/PriorityTree.sol";
import {IL1Bridgehub} from "../../../core/bridgehub/IL1Bridgehub.sol";
import {UncheckedMath} from "../../../common/libraries/UncheckedMath.sol";
import {IGetters} from "../../chain-interfaces/IGetters.sol";
import {ILegacyGetters} from "../../chain-interfaces/ILegacyGetters.sol";
import {SemVer} from "../../../common/libraries/SemVer.sol";
import {L2DACommitmentScheme} from "../../../common/Config.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZKChainBase} from "../../chain-interfaces/IZKChainBase.sol";

/// @title Getters Contract implements functions for getting contract state from outside the blockchain.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract GettersFacet is ZKChainBase, IGetters, ILegacyGetters, ISelfDescribingFacet {
    using UncheckedMath for uint256;
    using PriorityTree for PriorityTree.Tree;

    /// @inheritdoc IZKChainBase
    // solhint-disable-next-line const-name-snakecase
    string public constant override getName = "GettersFacet";

    /*//////////////////////////////////////////////////////////////
                            CUSTOM GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGetters
    function getVerifier() external view returns (address) {
        return address(s.verifier);
    }

    /// @inheritdoc IGetters
    function getAdmin() external view returns (address) {
        return s.admin;
    }

    /// @inheritdoc IGetters
    function getPendingAdmin() external view returns (address) {
        return s.pendingAdmin;
    }

    /// @inheritdoc IGetters
    function getBridgehub() external view returns (address) {
        return s.bridgehub;
    }

    /// @inheritdoc IGetters
    function getChainTypeManager() external view returns (address) {
        return s.chainTypeManager;
    }

    /// @inheritdoc IGetters
    function getChainId() external view returns (uint256) {
        return s.chainId;
    }

    /// @inheritdoc IGetters
    function getBaseToken() external view returns (address) {
        return IL1Bridgehub(s.bridgehub).baseToken(s.chainId);
    }

    /// @inheritdoc IGetters
    function getBaseTokenAssetId() external view returns (bytes32) {
        return s.baseTokenAssetId;
    }

    /// @inheritdoc IGetters
    function baseTokenGasPriceMultiplierNominator() external view returns (uint128) {
        return s.baseTokenGasPriceMultiplierNominator;
    }

    /// @inheritdoc IGetters
    function baseTokenGasPriceMultiplierDenominator() external view returns (uint128) {
        return s.baseTokenGasPriceMultiplierDenominator;
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
    function getTransactionFilterer() external view returns (address) {
        return s.transactionFilterer;
    }

    /// @inheritdoc IGetters
    function getTotalPriorityTxs() external view returns (uint256) {
        return _getTotalPriorityTxs();
    }

    /// @inheritdoc IGetters
    function getPriorityTreeStartIndex() external view returns (uint256) {
        return s.priorityTree.startIndex;
    }

    /// @inheritdoc IGetters
    function getFirstUnprocessedPriorityTx() external view returns (uint256) {
        return s.priorityTree.getFirstUnprocessedPriorityTx();
    }

    /// @inheritdoc IGetters
    function getPriorityTreeRoot() external view returns (bytes32) {
        return s.priorityTree.getRoot();
    }

    /// @inheritdoc IGetters
    function getPriorityQueueSize() external view returns (uint256) {
        return s.priorityTree.getSize();
    }

    /// @inheritdoc IGetters
    function isPriorityQueueActive() external view returns (bool) {
        return _isPriorityQueueActive();
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
    function getL2EvmEmulatorBytecodeHash() external view returns (bytes32) {
        return s.l2EvmEmulatorBytecodeHash;
    }

    /// @inheritdoc IGetters
    function getVerifierParams() external view returns (VerifierParams memory) {
        return s.__DEPRECATED_verifierParams;
    }

    /// @inheritdoc IGetters
    function getProtocolVersion() external view returns (uint256) {
        return s.protocolVersion;
    }

    /// @inheritdoc IGetters
    function getSemverProtocolVersion() external view returns (uint32, uint32, uint32) {
        // slither-disable-next-line unused-return
        return SemVer.unpackSemVer(SafeCast.toUint96(s.protocolVersion));
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
        if (ds.selectorToFacet[_selector].facetAddress == address(0)) {
            // The function does not exist
            return false;
        }
        return ds.selectorToFacet[_selector].isFreezable;
    }

    /// @inheritdoc IGetters
    function isEthWithdrawalFinalized(uint256 _l2BatchNumber, uint256 _l2MessageIndex) external view returns (bool) {
        return s.isEthWithdrawalFinalized[_l2BatchNumber][_l2MessageIndex];
    }

    /// @inheritdoc IGetters
    function getPubdataPricingMode() external view returns (PubdataPricingMode) {
        return s.feeParams.pubdataPricingMode;
    }

    /// @inheritdoc IGetters
    function getSettlementLayer() external view returns (address) {
        return s.settlementLayer;
    }

    /// @inheritdoc IGetters
    function getDAValidatorPair() external view returns (address, L2DACommitmentScheme) {
        return (s.l1DAValidator, s.l2DACommitmentScheme);
    }

    /// @inheritdoc IGetters
    function baseTokenSupportsTotalSupply() external view returns (bool) {
        return s.baseTokenHasTotalSupply;
    }

    /// @inheritdoc IGetters
    function getZKsyncOS() external view returns (bool) {
        return s.zksyncOS;
    }

    /*//////////////////////////////////////////////////////////////
                            DIAMOND LOUPE
     //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGetters
    function facets() external view returns (Facet[] memory result) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();

        uint256 facetsLen = ds.facets.length;
        result = new Facet[](facetsLen);

        for (uint256 i = 0; i < facetsLen; ++i) {
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

    /// @inheritdoc ISelfDescribingFacet
    /// @dev Packed list (4 bytes per selector) generated from this facet's ABI — every externally
    ///      served function except the unregistered helper views `getName()` and `selectors()`
    ///      (see `Utils.getAllSelectors`). Guarded against drift by FacetSelfDescription.t.sol.
    ///      0x1de72e34 baseTokenGasPriceMultiplierDenominator()
    ///      0xea6c029c baseTokenGasPriceMultiplierNominator()
    ///      0x44518012 baseTokenSupportsTotalSupply()
    ///      0xcdffacc6 facetAddress(bytes4)
    ///      0x52ef6b2c facetAddresses()
    ///      0xadfca15e facetFunctionSelectors(address)
    ///      0x7a0ed627 facets()
    ///      0x6e9960c3 getAdmin()
    ///      0x98acd7a6 getBaseToken()
    ///      0x960dcf24 getBaseTokenAssetId()
    ///      0x3591c1a0 getBridgehub()
    ///      0x3408e470 getChainId()
    ///      0x946ebad1 getChainTypeManager()
    ///      0x5a590335 getDAValidatorPair()
    ///      0x79823c9a getFirstUnprocessedPriorityTx()
    ///      0xd86970d8 getL2BootloaderBytecodeHash()
    ///      0xfd791f3c getL2DefaultAccountBytecodeHash()
    ///      0xdd655bb0 getL2EvmEmulatorBytecodeHash()
    ///      0xe5355c75 getL2SystemContractsUpgradeBatchNumber()
    ///      0x9d1b5a81 getL2SystemContractsUpgradeBlockNumber()
    ///      0x7b30c8da getL2SystemContractsUpgradeTxHash()
    ///      0xd0468156 getPendingAdmin()
    ///      0x631f4bac getPriorityQueueSize()
    ///      0x39d7d4aa getPriorityTreeRoot()
    ///      0xf4ff5e2e getPriorityTreeStartIndex()
    ///      0x0ec6b0b7 getPriorityTxMaxGasLimit()
    ///      0x33ce93fe getProtocolVersion()
    ///      0x06d49e5b getPubdataPricingMode()
    ///      0xf5c1182c getSemverProtocolVersion()
    ///      0x6a27e8b5 getSettlementLayer()
    ///      0xdb1f0bf9 getTotalBatchesCommitted()
    ///      0xb8c2f66f getTotalBatchesExecuted()
    ///      0xef3f0bae getTotalBatchesVerified()
    ///      0xfe26699e getTotalBlocksCommitted()
    ///      0x39607382 getTotalBlocksExecuted()
    ///      0xaf6a2dcd getTotalBlocksVerified()
    ///      0xa1954fc5 getTotalPriorityTxs()
    ///      0x22c5cf23 getTransactionFilterer()
    ///      0x46657fe9 getVerifier()
    ///      0x18e3a941 getVerifierParams()
    ///      0xc81838b7 getZKsyncOS()
    ///      0x29b98c67 isDiamondStorageFrozen()
    ///      0xbd7c5412 isEthWithdrawalFinalized(uint256,uint256)
    ///      0xc3bbd2d7 isFacetFreezable(address)
    ///      0xe81e0ba1 isFunctionFreezable(bytes4)
    ///      0x8708474e isPriorityQueueActive()
    ///      0xfacd743b isValidator(address)
    ///      0x9cd939e4 l2LogsRootHash(uint256)
    ///      0xb22dd78e storedBatchHash(uint256)
    ///      0x74f4d30d storedBlockHash(uint256)
    function selectors() public pure returns (bytes4[] memory result) {
        bytes
            memory packed = hex"1de72e34ea6c029c44518012cdffacc652ef6b2cadfca15e7a0ed6276e9960c398acd7a6960dcf243591c1a03408e470946ebad15a59033579823c9ad86970d8fd791f3cdd655bb0e5355c759d1b5a817b30c8dad0468156631f4bac39d7d4aaf4ff5e2e0ec6b0b733ce93fe06d49e5bf5c1182c6a27e8b5db1f0bf9b8c2f66fef3f0baefe26699e39607382af6a2dcda1954fc522c5cf2346657fe918e3a941c81838b729b98c67bd7c5412c3bbd2d7e81e0ba18708474efacd743b9cd939e4b22dd78e74f4d30d";
        uint256 count = packed.length / 4;
        result = new bytes4[](count);
        for (uint256 i = 0; i < count; ++i) {
            bytes4 selector;
            assembly {
                selector := mload(add(add(packed, 0x20), mul(i, 4)))
            }
            result[i] = selector;
        }
    }
}
