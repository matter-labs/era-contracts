// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MessageRootBase} from "./MessageRootBase.sol";
import {IBridgehubBase} from "../bridgehub/IBridgehubBase.sol";
import {IL1MessageRoot} from "./IL1MessageRoot.sol";
import {InvalidSettlementLayerForBatch, LocallyNoChainsAtGenesis} from "../bridgehub/L1BridgehubErrors.sol";
import {IGetters} from "../../state-transition/chain-interfaces/IGetters.sol";
import {ZeroAddress} from "../../common/L1ContractErrors.sol";
import {MessageHashing, ProofData} from "../../common/libraries/MessageHashing.sol";
import {IL1ChainAssetHandler} from "../chain-asset-handler/IL1ChainAssetHandler.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The MessageRoot contract is responsible for storing the cross message roots of the chains and the aggregated root of all chains.
contract L1MessageRoot is MessageRootBase, IL1MessageRoot {
    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    address public immutable BRIDGE_HUB;

    /// @dev The chain asset handler contract.
    address public immutable CHAIN_ASSET_HANDLER;

    /// @notice The mapping storing the batch number at the moment the chain was updated to V31.
    /// @notice This is the first batch starting from which we store batch roots on L1.
    /// @notice Due to the definition above, this mapping will have the default value (0) for newly added chains, so all their batches are under v31 rules.
    /// Chains that existed at the moment of the upgrade recorded their value during their own v31 upgrade, which has to precede
    /// this release; nothing writes it any more. See {protocol-docs/chain-lifecycle.md#upgrading-an-existing-ecosystem-onto-this-release}.
    /// @dev A chain's v31 upgrade, run while it settled on L1, set its `currentChainBatchNumber` to the batch before this
    /// one, so `chainBatchRoots` only holds batches from this one on.
    /// @dev A completely malicious chain (i.e. with malicious DiamondProxy implementation) could have recorded a wrong value here during its v31 upgrade, e.g. too low or too high.
    /// The system should be ready to handle such cases as long as no settlement layer (except for L1) is allowed. Before a settlement layer is added, it is the responsibility of the governance to double check that
    /// no malicious activity has happened before the transition of the ownership of the CTMs within the ecosystem.
    /// @dev It may be replaced with a library of constant values for cheaper access.
    mapping(uint256 chainId => uint256 batchNumber) public v31UpgradeChainBatchNumber;

    /// @dev This contract is expected to be used as a proxy implementation on L1.
    /// @param _bridgehub Address of the Bridgehub.
    /// @param _chainAssetHandler Address of the chain asset handler.
    constructor(address _bridgehub, address _chainAssetHandler) {
        require(_bridgehub != address(0), ZeroAddress());
        require(_chainAssetHandler != address(0), ZeroAddress());
        BRIDGE_HUB = _bridgehub;
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

    function _proveL2LeafInclusionOnSettlementLayer(
        uint256 _chainId,
        uint256 _batchNumber,
        ProofData memory _proofData,
        bytes32[] calldata _proof,
        uint256 _depth
    ) internal view virtual override returns (bool) {
        bool isValid = IL1ChainAssetHandler(CHAIN_ASSET_HANDLER).isValidSettlementLayer(
            _chainId,
            _batchNumber,
            _proofData.settlementLayerChainId,
            _proofData.settlementLayerBatchNumber
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

    /// @inheritdoc MessageRootBase
    function _noBatchFallback(uint256 _chainId, uint256 _batchNumber) internal view virtual override returns (bytes32) {
        if (_batchNumber < v31UpgradeChainBatchNumber[_chainId]) {
            return IGetters(IBridgehubBase(_getBridgehub()).getZKChain(_chainId)).l2LogsRootHash(_batchNumber);
        }
        return bytes32(0);
    }

    /*//////////////////////////////////////////////////////////////
                        IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    function _getBridgehub() internal view override returns (address) {
        return BRIDGE_HUB;
    }

    // solhint-disable-next-line func-name-mixedcase
    function L1_CHAIN_ID() public view override returns (uint256) {
        return block.chainid;
    }

    function _getChainAssetHandler() internal view override returns (address) {
        return CHAIN_ASSET_HANDLER;
    }
}
