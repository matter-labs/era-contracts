// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {ILegacyGetters} from "contracts/state-transition/chain-interfaces/ILegacyGetters.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {PriorityOperation} from "contracts/state-transition/libraries/PriorityQueue.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";

contract GettersFacetWrapper is GettersFacet {
    function util_setVerifier(address _verifier) external {
        s.verifier = IVerifier(_verifier);
    }

    function util_setAdmin(address _admin) external {
        s.admin = _admin;
    }

    function util_setPendingAdmin(address _pendingAdmin) external {
        s.pendingAdmin = _pendingAdmin;
    }

    function util_setBridgehub(address _bridgehub) external {
        s.bridgehub = _bridgehub;
    }

    function util_setStateTransitionManager(address _stateTransitionManager) external {
        s.stateTransitionManager = _stateTransitionManager;
    }

    function util_setBaseToken(address _baseToken) external {
        s.baseToken = _baseToken;
    }

    function util_setBaseTokenBridge(address _baseTokenBridge) external {
        s.baseTokenBridge = _baseTokenBridge;
    }

    function util_setTotalBatchesCommitted(uint256 _totalBatchesCommitted) external {
        s.totalBatchesCommitted = _totalBatchesCommitted;
    }

    function util_setTotalBatchesVerified(uint256 _totalBatchesVerified) external {
        s.totalBatchesVerified = _totalBatchesVerified;
    }

    function util_setTotalBatchesExecuted(uint256 _totalBatchesExecuted) external {
        s.totalBatchesExecuted = _totalBatchesExecuted;
    }

    function util_setTotalPriorityTxs(uint256 _totalPriorityTxs) external {
        s.priorityQueue.tail = _totalPriorityTxs;
    }

    function util_setFirstUnprocessedPriorityTx(uint256 _firstUnprocessedPriorityTx) external {
        s.priorityQueue.head = _firstUnprocessedPriorityTx;
    }

    function util_setPriorityQueueSize(uint256 _priorityQueueSize) external {
        s.priorityQueue.head = 0;
        s.priorityQueue.tail = _priorityQueueSize;
    }

    function util_setPriorityQueueFrontOperation(PriorityOperation memory _priorityQueueFrontOperation) external {
        s.priorityQueue.data[s.priorityQueue.head] = _priorityQueueFrontOperation;
        s.priorityQueue.tail = s.priorityQueue.head + 1;
    }

    function util_setValidator(address _validator, bool _status) external {
        s.validators[_validator] = _status;
    }

    function util_setL2LogsRootHash(uint256 batchNumber, bytes32 _l2LogsRootHash) external {
        s.l2LogsRootHashes[batchNumber] = _l2LogsRootHash;
    }

    function util_setStoredBatchHash(uint256 batchNumber, bytes32 _storedBatchHash) external {
        s.storedBatchHashes[batchNumber] = _storedBatchHash;
    }

    function util_setL2BootloaderBytecodeHash(bytes32 _l2BootloaderBytecodeHash) external {
        s.l2BootloaderBytecodeHash = _l2BootloaderBytecodeHash;
    }

    function util_setL2DefaultAccountBytecodeHash(bytes32 _l2DefaultAccountBytecodeHash) external {
        s.l2DefaultAccountBytecodeHash = _l2DefaultAccountBytecodeHash;
    }

    function util_setVerifierParams(VerifierParams memory _verifierParams) external {
        s.__DEPRECATED_verifierParams = _verifierParams;
    }

    function util_setProtocolVersion(uint256 _protocolVersion) external {
        s.protocolVersion = _protocolVersion;
    }

    function util_setL2SystemContractsUpgradeTxHash(bytes32 _l2SystemContractsUpgradeTxHash) external {
        s.l2SystemContractsUpgradeTxHash = _l2SystemContractsUpgradeTxHash;
    }

    function util_setL2SystemContractsUpgradeBatchNumber(uint256 _l2SystemContractsUpgradeBatchNumber) external {
        s.l2SystemContractsUpgradeBatchNumber = _l2SystemContractsUpgradeBatchNumber;
    }

    function util_setIsDiamondStorageFrozen(bool _isDiamondStorageFrozen) external {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        ds.isFrozen = _isDiamondStorageFrozen;
    }

    function util_setIsFacetFreezable(address _facet, bool _isFacetFreezable) external {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();

        ds.facetToSelectors[_facet].selectors = new bytes4[](1);
        ds.facetToSelectors[_facet].selectors[0] = bytes4("1234");
        bytes4 selector0 = ds.facetToSelectors[_facet].selectors[0];

        ds.selectorToFacet[selector0] = Diamond.SelectorToFacet({
            facetAddress: _facet,
            selectorPosition: 0,
            isFreezable: _isFacetFreezable
        });
    }

    function util_setPriorityTxMaxGasLimit(uint256 _priorityTxMaxGasLimit) external {
        s.priorityTxMaxGasLimit = _priorityTxMaxGasLimit;
    }

    function util_setIsFunctionFreezable(bytes4 _selector, bool _isFreezable) external {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();

        ds.selectorToFacet[_selector].isFreezable = _isFreezable;
    }

    function util_setIsEthWithdrawalFinalized(
        uint256 _l2Batchnumber,
        uint256 _l2MessageIndex,
        bool _isFinalized
    ) external {
        s.isEthWithdrawalFinalized[_l2Batchnumber][_l2MessageIndex] = _isFinalized;
    }

    function util_setFacets(IGetters.Facet[] memory _facets) external {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();

        ds.facets = new address[](_facets.length);
        for (uint256 i = 0; i < ds.facets.length; i++) {
            ds.facets[i] = _facets[i].addr;
            ds.facetToSelectors[_facets[i].addr] = Diamond.FacetToSelectors({
                selectors: _facets[i].selectors,
                facetPosition: uint16(i)
            });
        }
    }

    function util_setFacetFunctionSelectors(address _facet, bytes4[] memory _selectors) external {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        ds.facetToSelectors[_facet].selectors = _selectors;
    }

    function util_setFacetAddresses(address[] memory _facets) external {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        ds.facets = _facets;
    }

    function util_setFacetAddress(bytes4 _selector, address _facet) external {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        ds.selectorToFacet[_selector].facetAddress = _facet;
    }
}

contract GettersFacetTest is Test {
    IGetters internal gettersFacet;
    GettersFacetWrapper internal gettersFacetWrapper;
    ILegacyGetters internal legacyGettersFacet;

    function setUp() public virtual {
        gettersFacetWrapper = new GettersFacetWrapper();
        gettersFacet = IGetters(gettersFacetWrapper);
        legacyGettersFacet = ILegacyGetters(gettersFacetWrapper);
    }

    // add this to be excluded from coverage report
    function testA() internal virtual {}
}
