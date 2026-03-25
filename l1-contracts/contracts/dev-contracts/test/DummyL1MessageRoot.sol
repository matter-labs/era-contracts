// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L1MessageRoot} from "../../core/message-root/L1MessageRoot.sol";
import {ProofData} from "../../common/libraries/MessageHashing.sol";

/**
 * @title DummyL1MessageRoot
 * @notice Extends L1MessageRoot to bypass proof verification for Anvil testing.
 * @dev L1MessageRoot is the only contract that performs Merkle proof verification
 * for L2→L1 messages. Other contracts (Bridgehub, L1AssetRouter, etc.) delegate to it.
 *
 * Deployed directly via the deploy scripts (USE_DUMMY_MESSAGE_ROOT=true) so that
 * immutables are set normally by the constructor. Only proof verification is overridden.
 *
 * TODO: Consider building real Merkle proofs in the test harness instead of mocking,
 * at least for L1 settlement. This would validate the proof construction path too.
 */
contract DummyL1MessageRoot is L1MessageRoot {
    constructor(
        address _bridgehub,
        uint256 _eraGatewayChainId,
        address _chainAssetHandler
    ) L1MessageRoot(_bridgehub, _eraGatewayChainId, _chainAssetHandler) {}

    // ── Proof verification overrides (always return true) ──

    function _proveL2LeafInclusionOnSettlementLayer(
        uint256,
        uint256,
        ProofData memory,
        bytes32[] calldata,
        uint256
    ) internal pure override returns (bool) {
        return true;
    }

    function _noBatchFallback(uint256, uint256) internal pure override returns (bytes32) {
        // Return a non-zero value so batch root checks pass
        return bytes32(uint256(1));
    }

    function _proveL2LeafInclusionRecursive(
        uint256,
        uint256,
        uint256,
        bytes32,
        bytes32[] calldata,
        uint256
    ) internal pure override returns (bool) {
        return true;
    }
}
