// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MessageRootBase} from "./MessageRootBase.sol";
import {IBridgehubBase} from "../bridgehub/IBridgehubBase.sol";
import {V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1} from "./IMessageRoot.sol";
import {IL1MessageRoot} from "./IL1MessageRoot.sol";
import {CurrentBatchNumberAlreadySet, OnlyOnSettlementLayer, TotalBatchesExecutedLessThanV31UpgradeChainBatchNumber, TotalBatchesExecutedZero, LocallyNoChainsAtGenesis, V31UpgradeChainBatchNumberAlreadySet, NotAllChainsOnL1} from "../bridgehub/L1BridgehubErrors.sol";
import {IGetters} from "../../state-transition/chain-interfaces/IGetters.sol";
import {ZeroAddress} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The MessageRoot contract is responsible for storing the cross message roots of the chains and the aggregated root of all chains.
contract L1MessageRoot is MessageRootBase, IL1MessageRoot {
    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    address public immutable BRIDGE_HUB;

    /// @dev The chain asset handler contract.
    address public immutable CHAIN_ASSET_HANDLER;

    /// @notice The chain id of the Gateway chain.
    uint256 public immutable ERA_GATEWAY_CHAIN_ID;

    /// @notice The mapping storing the batch number at the moment the chain was updated to V31.
    /// Starting from this batch, if a settlement layer has agreed to a proof, it will be held accountable for the content of the message, e.g.
    /// if a withdrawal happens, the balance of the settlement layer will be reduced and not the chain.
    /// @notice This is also the first batch starting from which we store batch roots on L1.
    /// @notice Due to the definition above, this mapping will have the default value (0) for newly added chains, so all their batches are under v31 rules.
    /// For chains that existed at the moment of the upgrade, its value will be populated with V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE until
    /// they call this contract to establish the batch when the upgrade has happened.
    /// @notice Also, as a consequence of the above, the MessageRoot on a settlement layer will require that all messages after this batch go through the asset tracker
    /// to ensure balance consistency.
    /// @notice This value should contain the same value for both MessageRoot on L1 and on any settlement layer where the chain settles. This is ensured by the fact
    /// that on the settlement layer the chain will provide its totalBatchesExecuted at the moment of upgrade, and only then the value will be moved to L1 and other settlement layers
    /// via bridgeMint/bridgeBurn during migration.
    /// @dev The attack that could be possible by a completely compromised chain is that it will provide an overly small `v31UpgradeChainBatchNumber` value and then migrate
    /// to a settlement layer and then finalize messages that were not actually approved by the settlement layer. However, since before v31 release chains can only migrate within the same CTM,
    /// this attack is not considered viable as the chains belong to the same CTM as the settlement layer and so the SL can trust their `getTotalBatchesExecuted` value.
    mapping(uint256 chainId => uint256 batchNumber) public v31UpgradeChainBatchNumber;

    /// @dev This contract is expected to be used as a proxy implementation on L1.
    /// @param _bridgehub Address of the Bridgehub.
    /// @param _eraGatewayChainId Chain ID of the Era Gateway chain.
    constructor(address _bridgehub, uint256 _eraGatewayChainId, address _chainAssetHandler) {
        require(_bridgehub != address(0), ZeroAddress());
        require(_chainAssetHandler != address(0), ZeroAddress());
        BRIDGE_HUB = _bridgehub;
        ERA_GATEWAY_CHAIN_ID = _eraGatewayChainId;
        CHAIN_ASSET_HANDLER = _chainAssetHandler;
        _disableInitializers();
    }

    /// @dev This initializer is used in local deployments.
    function initialize() external reinitializer(2) {
        _initialize();
        uint256[] memory allZKChains = IBridgehubBase(BRIDGE_HUB).getAllZKChainChainIDs();
        uint256 allZKChainsLength = allZKChains.length;
        /// locally there are no chains deployed before.
        require(allZKChainsLength == 0, LocallyNoChainsAtGenesis());
    }

    /// @dev This initializer is used in the v31 upgrade.
    function initializeL1V31Upgrade() external reinitializer(2) {
        uint256[] memory allZKChains = IBridgehubBase(BRIDGE_HUB).getAllZKChainChainIDs();
        _v31InitializeInner(allZKChains);
    }

    function _v31InitializeInner(uint256[] memory _allZKChains) internal {
        uint256 allZKChainsLength = _allZKChains.length;
        for (uint256 i = 0; i < allZKChainsLength; ++i) {
            require(IBridgehubBase(_bridgehub()).settlementLayer(_allZKChains[i]) == block.chainid, NotAllChainsOnL1());
            v31UpgradeChainBatchNumber[_allZKChains[i]] = V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1;
        }
    }

    function saveV31UpgradeChainBatchNumber(uint256 _chainId) external onlyChain(_chainId) {
        require(block.chainid == IBridgehubBase(_bridgehub()).settlementLayer(_chainId), OnlyOnSettlementLayer());
        uint256 totalBatchesExecuted = IGetters(msg.sender).getTotalBatchesExecuted();
        require(totalBatchesExecuted > 0, TotalBatchesExecutedZero());
        require(
            totalBatchesExecuted != V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1,
            TotalBatchesExecutedLessThanV31UpgradeChainBatchNumber()
        );
        require(
            v31UpgradeChainBatchNumber[_chainId] == V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1,
            V31UpgradeChainBatchNumberAlreadySet()
        );
        require(currentChainBatchNumber[_chainId] == 0, CurrentBatchNumberAlreadySet());

        currentChainBatchNumber[_chainId] = totalBatchesExecuted;
        v31UpgradeChainBatchNumber[_chainId] = totalBatchesExecuted + 1;
    }

    function _proveL2LeafInclusionOnSettlementLayer(
        uint256 _chainId,
        uint256 _batchNumber,
        ProofData memory _proofData,
        bytes32[] calldata _proof,
        uint256 _depth
    ) internal view override returns (bool) {
        bool isValid = IL1ChainAssetHandler(CHAIN_ASSET_HANDLER).isValidSettlementLayer(
            _chainId,
            _batchNumber,
            _proofData.settlementLayerChainId
        );
        require(isValid, InvalidSettlementLayerForBatch(_chainId, _batchNumber, _proofData.settlementLayerChainId));

        return
            this.proveL2LeafInclusionSharedRecursive({
                _chainId: _proofData.settlementLayerChainId,
                _blockOrBatchNumber: _proofData.settlementLayerBatchNumber,
                _leafProofMask: _proofData.settlementLayerBatchRootMask,
                _leaf: _proofData.chainIdLeaf,
                _proof: MessageHashing.extractSliceUntilEnd(_proof, _proofData.ptr),
                _depth: _depth + 1
            });
    }

    /*//////////////////////////////////////////////////////////////
                        IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    function _bridgehub() internal view override returns (address) {
        return BRIDGE_HUB;
    }

    // solhint-disable-next-line func-name-mixedcase
    function L1_CHAIN_ID() public view override returns (uint256) {
        return block.chainid;
    }

    function _eraGatewayChainId() internal view override returns (uint256) {
        return ERA_GATEWAY_CHAIN_ID;
    }
}
