// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IVerifier, VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {
    L2DACommitmentScheme,
    PRIORITY_TX_MAX_GAS_LIMIT,
    PubdataContent,
    PubdataPricingMode
} from "contracts/common/Config.sol";

/// @notice GettersFacet with the UtilsFacet setters on the same storage, plus setters for the fields only these tests
/// write. They live here rather than in UtilsFacet, whose setters must also be registered as diamond selectors.
contract GettersFacetHarness is GettersFacet, UtilsFacet {
    function util_setPriorityTreeStartIndex(uint256 _startIndex) external {
        s.priorityTree.startIndex = _startIndex;
    }

    function util_setPriorityTreeUnprocessedIndex(uint256 _unprocessedIndex) external {
        s.priorityTree.unprocessedIndex = _unprocessedIndex;
    }

    function util_setIsEthWithdrawalFinalized(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        bool _isFinalized
    ) external {
        s.isEthWithdrawalFinalized[_l2BatchNumber][_l2MessageIndex] = _isFinalized;
    }

    function util_setZKsyncOS(bool _zksyncOS) external {
        s.zksyncOS = _zksyncOS;
    }

    function util_setL1DAValidator(address _l1DAValidator) external {
        s.l1DAValidator = _l1DAValidator;
    }

    function util_setPubdataContent(PubdataContent _pubdataContent) external {
        s.pubdataContent = _pubdataContent;
    }

    function util_setPubdataPricingMode(PubdataPricingMode _pubdataPricingMode) external {
        s.feeParams.pubdataPricingMode = _pubdataPricingMode;
    }

    function util_setFacets(address[] calldata _facets) external {
        Diamond.getDiamondStorage().facets = _facets;
    }

    function util_setFacetToSelectors(address _facet, bytes4[] calldata _selectors) external {
        Diamond.getDiamondStorage().facetToSelectors[_facet].selectors = _selectors;
    }

    function util_setSelectorToFacet(bytes4 _selector, address _facet, bool _isFreezable) external {
        Diamond.getDiamondStorage().selectorToFacet[_selector] = Diamond.SelectorToFacet({
            facetAddress: _facet,
            selectorPosition: 0,
            isFreezable: _isFreezable
        });
    }
}

/// @notice Most getters return one storage field: each group test writes distinct values through the `util_set*`
/// backdoors and reads every one back. Getters with logic of their own have dedicated tests.
contract GettersFacetTest is Test {
    GettersFacetHarness internal getters;

    function setUp() public {
        getters = new GettersFacetHarness();
    }

    function test_chainAddressesAndBaseTokenAssetId() public {
        address admin = makeAddr("admin");
        address pendingAdmin = makeAddr("pendingAdmin");
        address bridgehub = makeAddr("bridgehub");
        address chainTypeManager = makeAddr("chainTypeManager");
        address verifier = makeAddr("verifier");
        bytes32 baseTokenAssetId = keccak256("baseTokenAssetId");

        getters.util_setAdmin(admin);
        getters.util_setPendingAdmin(pendingAdmin);
        getters.util_setBridgehub(bridgehub);
        getters.util_setChainTypeManager(chainTypeManager);
        getters.util_setVerifier(IVerifier(verifier));
        getters.util_setBaseToken(baseTokenAssetId);

        assertEq(getters.getAdmin(), admin);
        assertEq(getters.getPendingAdmin(), pendingAdmin);
        assertEq(getters.getBridgehub(), bridgehub);
        assertEq(getters.getChainTypeManager(), chainTypeManager);
        assertEq(getters.getVerifier(), verifier);
        assertEq(getters.getBaseTokenAssetId(), baseTokenAssetId);
    }

    function test_getBaseToken_asksBridgehubForThisChain() public {
        address bridgehub = makeAddr("bridgehub");
        address baseToken = makeAddr("baseToken");
        uint256 chainId = 123;
        getters.util_setBridgehub(bridgehub);
        getters.util_setChainId(chainId);
        // The facet is tested in isolation: the Bridgehub is mocked, and the call matches only for this chain id.
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.baseToken, (chainId)), abi.encode(baseToken));

        assertEq(getters.getBaseToken(), baseToken);
    }

    function test_batchCountersAndHashes() public {
        uint256 committed = 30;
        uint256 verified = 20;
        uint256 executed = 10;
        uint32 batchNumber = 42;
        bytes32 storedBatchHash = keccak256("storedBatchHash");
        bytes32 l2LogsRootHash = keccak256("l2LogsRootHash");

        getters.util_setTotalBatchesCommitted(committed);
        getters.util_setTotalBatchesVerified(verified);
        getters.util_setTotalBatchesExecuted(executed);
        getters.util_setStoredBatchHashes(batchNumber, storedBatchHash);
        getters.util_setL2LogsRootHash(batchNumber, l2LogsRootHash);

        assertEq(getters.getTotalBatchesCommitted(), committed);
        assertEq(getters.getTotalBatchesVerified(), verified);
        assertEq(getters.getTotalBatchesExecuted(), executed);
        assertEq(getters.storedBatchHash(batchNumber), storedBatchHash);
        assertEq(getters.l2LogsRootHash(batchNumber), l2LogsRootHash);
    }

    function test_protocolVersionAndUpgradeState() public {
        uint256 protocolVersion = 765456;
        bytes32 upgradeTxHash = keccak256("l2SystemContractsUpgradeTxHash");
        uint256 upgradeBatchNumber = 56432;
        VerifierParams memory verifierParams = VerifierParams({
            recursionNodeLevelVkHash: keccak256("recursionNodeLevelVkHash"),
            recursionLeafLevelVkHash: keccak256("recursionLeafLevelVkHash"),
            recursionCircuitsSetVksHash: keccak256("recursionCircuitsSetVksHash")
        });

        getters.util_setProtocolVersion(protocolVersion);
        getters.util_setL2SystemContractsUpgradeTxHash(upgradeTxHash);
        getters.util_setL2SystemContractsUpgradeBatchNumber(upgradeBatchNumber);
        getters.util_setVerifierParams(verifierParams);

        assertEq(getters.getProtocolVersion(), protocolVersion);
        assertEq(getters.getL2SystemContractsUpgradeTxHash(), upgradeTxHash);
        assertEq(getters.getL2SystemContractsUpgradeBatchNumber(), upgradeBatchNumber);
        assertEq(abi.encode(getters.getVerifierParams()), abi.encode(verifierParams));
    }

    /// @dev The deprecated block-named getters read the same fields as their batch-named replacements.
    function test_legacyBlockGetters() public {
        uint256 committed = 30;
        uint256 verified = 20;
        uint256 executed = 10;
        uint32 batchNumber = 42;
        bytes32 storedBatchHash = keccak256("storedBatchHash");
        uint256 upgradeBatchNumber = 56432;

        getters.util_setTotalBatchesCommitted(committed);
        getters.util_setTotalBatchesVerified(verified);
        getters.util_setTotalBatchesExecuted(executed);
        getters.util_setStoredBatchHashes(batchNumber, storedBatchHash);
        getters.util_setL2SystemContractsUpgradeBatchNumber(upgradeBatchNumber);

        assertEq(getters.getTotalBlocksCommitted(), committed);
        assertEq(getters.getTotalBlocksVerified(), verified);
        assertEq(getters.getTotalBlocksExecuted(), executed);
        assertEq(getters.storedBlockHash(batchNumber), storedBatchHash);
        assertEq(getters.getL2SystemContractsUpgradeBlockNumber(), upgradeBatchNumber);
    }

    /// @dev The tree counts its leaves from `startIndex`, so the absolute indexes add it and the queue size does not.
    function testFuzz_priorityTreeCounters(uint128 _startIndex, uint64 _processed, uint64 _pending) public {
        getters.util_setPriorityTreeStartIndex(_startIndex);
        getters.util_setPriorityTreeUnprocessedIndex(_processed);
        getters.util_setPriorityTreeNextLeafIndex(uint256(_processed) + _pending);

        assertEq(getters.getPriorityTreeStartIndex(), _startIndex);
        assertEq(getters.getFirstUnprocessedPriorityTx(), uint256(_startIndex) + _processed);
        assertEq(getters.getTotalPriorityTxs(), uint256(_startIndex) + _processed + _pending);
        assertEq(getters.getPriorityQueueSize(), _pending);
    }

    /// @dev The getter returns the stored limit as is, isolated from initialization and upgrade-time normalization.
    function testFuzz_getPriorityTxMaxGasLimit_returnsStoredLimit(uint256 _storedLimit) public {
        getters.util_setPriorityTxMaxGasLimit(_storedLimit);
        assertEq(getters.getPriorityTxMaxGasLimit(), _storedLimit);
    }

    function test_getPriorityTxMaxGasLimit_boundaries() public {
        uint256[4] memory limits = [
            uint256(0),
            PRIORITY_TX_MAX_GAS_LIMIT - 1,
            PRIORITY_TX_MAX_GAS_LIMIT,
            type(uint256).max
        ];
        for (uint256 i; i < limits.length; ++i) {
            getters.util_setPriorityTxMaxGasLimit(limits[i]);
            assertEq(getters.getPriorityTxMaxGasLimit(), limits[i]);
        }
    }

    function test_booleanFlags() public {
        address validator = makeAddr("validator");
        uint256 l2BatchNumber = 123456789;
        uint256 l2MessageIndex = 987654321;

        getters.util_setValidator(validator, true);
        getters.util_setZKsyncOS(true);
        getters.util_setIsFrozen(true);
        getters.util_setIsEthWithdrawalFinalized(l2BatchNumber, l2MessageIndex, true);
        assertTrue(getters.isValidator(validator));
        assertTrue(getters.getZKsyncOS());
        assertTrue(getters.isDiamondStorageFrozen());
        assertTrue(getters.isEthWithdrawalFinalized(l2BatchNumber, l2MessageIndex));

        getters.util_setValidator(validator, false);
        getters.util_setZKsyncOS(false);
        getters.util_setIsFrozen(false);
        getters.util_setIsEthWithdrawalFinalized(l2BatchNumber, l2MessageIndex, false);
        assertFalse(getters.isValidator(validator));
        assertFalse(getters.getZKsyncOS());
        assertFalse(getters.isDiamondStorageFrozen());
        assertFalse(getters.isEthWithdrawalFinalized(l2BatchNumber, l2MessageIndex));
    }

    function test_getPubdataPricingMode() public {
        getters.util_setPubdataPricingMode(PubdataPricingMode.Validium);
        assertEq(uint8(getters.getPubdataPricingMode()), uint8(PubdataPricingMode.Validium));

        getters.util_setPubdataPricingMode(PubdataPricingMode.Rollup);
        assertEq(uint8(getters.getPubdataPricingMode()), uint8(PubdataPricingMode.Rollup));
    }

    function test_getDAValidatorPair() public {
        L2DACommitmentScheme[3] memory schemes = [
            L2DACommitmentScheme.BLOBS_ZKSYNC_OS,
            L2DACommitmentScheme.PUBDATA_KECCAK256,
            L2DACommitmentScheme.NONE
        ];
        for (uint256 i; i < schemes.length; ++i) {
            address l1DAValidator = makeAddr(string.concat("l1DAValidator", vm.toString(i)));
            getters.util_setL1DAValidator(l1DAValidator);
            getters.util_setL2DACommitmentScheme(schemes[i]);

            (address receivedValidator, L2DACommitmentScheme receivedScheme) = getters.getDAValidatorPair();
            assertEq(receivedValidator, l1DAValidator);
            assertEq(uint8(receivedScheme), uint8(schemes[i]));
        }
    }

    function test_getPubdataContent_defaultsToFullPubdata() public view {
        // Fresh storage: the enum's zero value must read as FULL_PUBDATA (commit everything),
        // so chains that existed before the field was introduced keep full-pubdata behavior.
        assertEq(uint8(getters.getPubdataContent()), uint8(PubdataContent.FULL_PUBDATA));
    }

    function test_getPubdataContent() public {
        getters.util_setPubdataContent(PubdataContent.LOGS_ONLY);
        assertEq(uint8(getters.getPubdataContent()), uint8(PubdataContent.LOGS_ONLY));

        getters.util_setPubdataContent(PubdataContent.FULL_PUBDATA);
        assertEq(uint8(getters.getPubdataContent()), uint8(PubdataContent.FULL_PUBDATA));
    }

    function test_diamondLoupeAndFreezability() public {
        address freezableFacet = makeAddr("freezableFacet");
        address unfreezableFacet = makeAddr("unfreezableFacet");
        bytes4[] memory freezableSelectors = new bytes4[](2);
        freezableSelectors[0] = bytes4(0x11111111);
        freezableSelectors[1] = bytes4(0x22222222);
        bytes4[] memory unfreezableSelectors = new bytes4[](1);
        unfreezableSelectors[0] = bytes4(0x33333333);
        address[] memory facetAddresses = new address[](2);
        facetAddresses[0] = freezableFacet;
        facetAddresses[1] = unfreezableFacet;

        getters.util_setFacets(facetAddresses);
        getters.util_setFacetToSelectors(freezableFacet, freezableSelectors);
        getters.util_setFacetToSelectors(unfreezableFacet, unfreezableSelectors);
        getters.util_setSelectorToFacet(freezableSelectors[0], freezableFacet, true);
        getters.util_setSelectorToFacet(freezableSelectors[1], freezableFacet, true);
        getters.util_setSelectorToFacet(unfreezableSelectors[0], unfreezableFacet, false);

        IGetters.Facet[] memory expectedFacets = new IGetters.Facet[](2);
        expectedFacets[0] = IGetters.Facet({addr: freezableFacet, selectors: freezableSelectors});
        expectedFacets[1] = IGetters.Facet({addr: unfreezableFacet, selectors: unfreezableSelectors});
        assertEq(abi.encode(getters.facets()), abi.encode(expectedFacets));
        assertEq(getters.facetAddresses(), facetAddresses);
        assertEq(abi.encode(getters.facetFunctionSelectors(freezableFacet)), abi.encode(freezableSelectors));
        assertEq(getters.facetAddress(freezableSelectors[1]), freezableFacet);
        assertEq(getters.facetAddress(unfreezableSelectors[0]), unfreezableFacet);

        assertTrue(getters.isFacetFreezable(freezableFacet));
        assertFalse(getters.isFacetFreezable(unfreezableFacet));
        assertTrue(getters.isFunctionFreezable(freezableSelectors[0]));
        assertFalse(getters.isFunctionFreezable(unfreezableSelectors[0]));
    }

    function test_isFacetFreezable_falseForFacetWithoutSelectors() public {
        assertFalse(getters.isFacetFreezable(makeAddr("facet")));
    }

    function test_isFunctionFreezable_falseForSelectorWithoutFacet() public {
        bytes4 selector = bytes4(0x44444444);
        // The freezable flag is set on purpose: only the missing facet address makes the getter return false.
        getters.util_setSelectorToFacet(selector, address(0), true);

        assertFalse(getters.isFunctionFreezable(selector));
    }
}
