// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ISystemContext} from "contracts/common/interfaces/ISystemContext.sol";
import {IL2ChainAssetHandler} from "contracts/core/chain-asset-handler/IL2ChainAssetHandler.sol";
import {L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/**
 * @notice Full storage layout of the SystemContext contract, mirroring the original
 * system-contracts/contracts/SystemContext.sol slot-for-slot.
 * @dev Mappings cannot be placed inside structs in Solidity. Slot 8 (`batchHashes`)
 * is represented as a `bytes32` placeholder to preserve alignment. Contracts that need
 * to access `batchHashes` must obtain a typed mapping pointer via assembly (see
 * `SystemContextEra._eraBatchHashes()`).
 * @dev The struct is always anchored at slot 0 via `assembly { $.slot := 0 }`.
 */
struct SystemContextStorage {
    // Slot 0
    uint256 chainId;
    // Slot 1
    address origin;
    // Slot 2
    uint256 gasPrice;
    // Slot 3
    uint256 blockGasLimit;
    // Slot 4
    address coinbase;
    // Slot 5
    uint256 difficulty;
    // Slot 6
    uint256 baseFee;
    // Slot 7 — two uint128 fields packed by Solidity
    ISystemContext.BlockInfo currentBatchInfo;
    // Slot 8 — placeholder; the actual mapping(uint256 => bytes32) batchHashes is
    // accessed via assembly in contracts that need it.
    bytes32 _batchHashesSlot;
    // Slot 9
    ISystemContext.BlockInfo currentL2BlockInfo;
    // Slot 10
    bytes32 currentL2BlockTxsRollingHash;
    // Slots 11-267
    bytes32[257] l2BlockHash;
    // Slot 268
    ISystemContext.BlockInfo currentVirtualL2BlockInfo;
    // Slot 269
    ISystemContext.VirtualBlockUpgradeInfo virtualBlockUpgradeInfo;
    // Slot 270
    uint256 currentSettlementLayerChainId;
    // Slot 271
    uint16 txNumberInBlock;
    // Slot 272
    uint256 gasPerPubdataByte;
    // Slot 273
    uint256 basePubdataSpent;
    // Slots 274-319 — storage gap for future shared variables
    uint256[46] __gap;
}

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Library implementing logic shared between SystemContextEra and SystemContextZKOS.
 * @dev Receives a storage pointer to `SystemContextStorage` anchored at slot 0 of the
 * calling contract. This avoids base-contract inheritance while still sharing code.
 */
library SystemContextLib {
    /// @notice Emitted when the Settlement Layer chain id is modified.
    event SettlementLayerChainIdUpdated(uint256 indexed _newSettlementLayerChainId);

    /// @notice Updates the settlement layer chain ID, calling the chain asset handler and
    /// emitting an event when the value actually changes.
    /// @param $ Storage pointer to the calling contract's SystemContextStorage.
    /// @param _newSettlementLayerChainId The new settlement layer chain ID.
    function setSettlementLayerChainId(
        SystemContextStorage storage $,
        uint256 _newSettlementLayerChainId
    ) internal {
        if ($.currentSettlementLayerChainId != _newSettlementLayerChainId) {
            // slither-disable-next-line reentrancy-no-eth
            IL2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR).setSettlementLayerChainId(
                $.currentSettlementLayerChainId,
                _newSettlementLayerChainId
            );
            $.currentSettlementLayerChainId = _newSettlementLayerChainId;
            emit SettlementLayerChainIdUpdated(_newSettlementLayerChainId);
        }
    }
}
