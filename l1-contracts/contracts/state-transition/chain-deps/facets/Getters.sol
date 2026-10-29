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
import {ProofSystem, DisabledProofSystems, L2DACommitmentScheme, PubdataContent} from "../../../common/Config.sol";

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
    function getProofMode() external view returns (uint256) {
        return _getProofMode();
    }

    /// @inheritdoc IGetters
    function isSecondProofSystemRequired() external view returns (bool) {
        return s.secondProofSystemRequired;
    }

    /// @inheritdoc IGetters
    function disabledProofSystems() external view returns (DisabledProofSystems memory) {
        uint8 mask = s.disabledProofSystems;
        return
            DisabledProofSystems({
                boojum: mask & uint8(1 << uint8(ProofSystem.Boojum)) != 0,
                airbender: mask & uint8(1 << uint8(ProofSystem.Airbender)) != 0,
                zisk: mask & uint8(1 << uint8(ProofSystem.Zisk)) != 0
            });
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
    function getZKsyncOSMaxTxGasLimit() external view returns (uint64) {
        return _getZKsyncOSMaxTxGasLimit();
    }

    /// @inheritdoc IGetters
    function getZKsyncOSChainConfigHash() external view returns (bytes32) {
        return _getZKsyncOSChainConfigHash();
    }

    /// @inheritdoc IGetters
    function isZKsyncOSL1TxFilteringEnabled() external view returns (bool) {
        return s.zksyncOSL1TxFilteringEnabled;
    }

    /// @inheritdoc IGetters
    function isZKsyncOSLargeContractsEnabled() external view returns (bool) {
        return s.zksyncOSLargeContractsEnabled;
    }

    /// @inheritdoc IGetters
    function isZKsyncOSL1SloadEnabled() external view returns (bool) {
        return s.zksyncOSL1SloadEnabled;
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
    function getPubdataContent() external view returns (PubdataContent) {
        return s.pubdataContent;
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
    /// @dev GENERATED by `yarn l1 facet-selectors --fix` from this facet's ABI: every externally
    ///      served function except the unregistered helper views `getName()` and `selectors()`
    ///      (see `Utils.getAllSelectors`), in ascending selector order. Guarded against drift by
    ///      FacetSelfDescription.t.sol and `yarn l1 facet-selectors --check`.
    function selectors() public pure returns (bytes4[] memory result) {
        uint32[56] memory list = [
            // getPubdataPricingMode()
            uint32(0x06d49e5b),
            // getPriorityTxMaxGasLimit()
            uint32(0x0ec6b0b7),
            // getVerifierParams()
            uint32(0x18e3a941),
            // baseTokenGasPriceMultiplierDenominator()
            uint32(0x1de72e34),
            // getTransactionFilterer()
            uint32(0x22c5cf23),
            // isDiamondStorageFrozen()
            uint32(0x29b98c67),
            // getProtocolVersion()
            uint32(0x33ce93fe),
            // getChainId()
            uint32(0x3408e470),
            // getBridgehub()
            uint32(0x3591c1a0),
            // getProofMode()
            uint32(0x38459451),
            // getTotalBlocksExecuted()
            uint32(0x39607382),
            // getPriorityTreeRoot()
            uint32(0x39d7d4aa),
            // baseTokenSupportsTotalSupply()
            uint32(0x44518012),
            // getVerifier()
            uint32(0x46657fe9),
            // facetAddresses()
            uint32(0x52ef6b2c),
            // getDAValidatorPair()
            uint32(0x5a590335),
            // getPriorityQueueSize()
            uint32(0x631f4bac),
            // getSettlementLayer()
            uint32(0x6a27e8b5),
            // getAdmin()
            uint32(0x6e9960c3),
            // getPubdataContent()
            uint32(0x70e7ef4f),
            // isZKsyncOSLargeContractsEnabled()
            uint32(0x747c3166),
            // storedBlockHash(uint256)
            uint32(0x74f4d30d),
            // disabledProofSystems()
            uint32(0x765b11a1),
            // getFirstUnprocessedPriorityTx()
            uint32(0x79823c9a),
            // facets()
            uint32(0x7a0ed627),
            // getL2SystemContractsUpgradeTxHash()
            uint32(0x7b30c8da),
            // getZKsyncOSChainConfigHash()
            uint32(0x84364651),
            // isPriorityQueueActive()
            uint32(0x8708474e),
            // isSecondProofSystemRequired()
            uint32(0x90985aac),
            // getChainTypeManager()
            uint32(0x946ebad1),
            // getBaseTokenAssetId()
            uint32(0x960dcf24),
            // getBaseToken()
            uint32(0x98acd7a6),
            // l2LogsRootHash(uint256)
            uint32(0x9cd939e4),
            // getL2SystemContractsUpgradeBlockNumber()
            uint32(0x9d1b5a81),
            // getTotalPriorityTxs()
            uint32(0xa1954fc5),
            // facetFunctionSelectors(address)
            uint32(0xadfca15e),
            // getTotalBlocksVerified()
            uint32(0xaf6a2dcd),
            // storedBatchHash(uint256)
            uint32(0xb22dd78e),
            // getTotalBatchesExecuted()
            uint32(0xb8c2f66f),
            // isZKsyncOSL1TxFilteringEnabled()
            uint32(0xbb978235),
            // isEthWithdrawalFinalized(uint256,uint256)
            uint32(0xbd7c5412),
            // isFacetFreezable(address)
            uint32(0xc3bbd2d7),
            // getZKsyncOS()
            uint32(0xc81838b7),
            // facetAddress(bytes4)
            uint32(0xcdffacc6),
            // getPendingAdmin()
            uint32(0xd0468156),
            // getTotalBatchesCommitted()
            uint32(0xdb1f0bf9),
            // getZKsyncOSMaxTxGasLimit()
            uint32(0xdc2f223a),
            // getL2SystemContractsUpgradeBatchNumber()
            uint32(0xe5355c75),
            // isFunctionFreezable(bytes4)
            uint32(0xe81e0ba1),
            // baseTokenGasPriceMultiplierNominator()
            uint32(0xea6c029c),
            // isZKsyncOSL1SloadEnabled()
            uint32(0xecfbb07b),
            // getTotalBatchesVerified()
            uint32(0xef3f0bae),
            // getPriorityTreeStartIndex()
            uint32(0xf4ff5e2e),
            // getSemverProtocolVersion()
            uint32(0xf5c1182c),
            // isValidator(address)
            uint32(0xfacd743b),
            // getTotalBlocksCommitted()
            uint32(0xfe26699e)
        ];
        uint256 count = list.length;
        result = new bytes4[](count);
        for (uint256 i = 0; i < count; ++i) {
            result[i] = bytes4(list[i]);
        }
    }
}
