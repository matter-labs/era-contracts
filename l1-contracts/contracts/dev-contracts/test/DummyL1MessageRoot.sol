// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MessageRootBase} from "../../core/message-root/MessageRootBase.sol";
import {IL1MessageRoot} from "../../core/message-root/IL1MessageRoot.sol";
import {V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE} from "../../core/message-root/IMessageRoot.sol";
import {ProofData} from "../../common/libraries/MessageHashing.sol";

/**
 * @title DummyL1MessageRoot
 * @notice Replaces L1MessageRoot proxy code for Anvil testing.
 * @dev Has the same storage layout as L1MessageRoot so existing proxy storage is preserved.
 * Uses storage variables instead of immutables for BRIDGE_HUB, CHAIN_ASSET_HANDLER, etc.
 * since immutables are embedded in bytecode (lost when replacing via anvil_setCode).
 * All proof verification functions return true.
 */
contract DummyL1MessageRoot is MessageRootBase, IL1MessageRoot {
    // ── Storage matching L1MessageRoot (slot 50) ──
    mapping(uint256 chainId => uint256 batchNumber) public v31UpgradeChainBatchNumber;

    // ── Additional storage for immutable replacements (slots 51, 52, 53) ──
    address private _storedBridgehub;
    address private _storedChainAssetHandler;
    uint256 private _storedEraGatewayChainId;

    // Storage slot constants for setting via anvil_setStorageAt
    // _storedBridgehub is at slot 51
    // _storedChainAssetHandler is at slot 52
    // _storedEraGatewayChainId is at slot 53
    uint256 public constant BRIDGEHUB_STORAGE_SLOT = 51;
    uint256 public constant CHAIN_ASSET_HANDLER_STORAGE_SLOT = 52;
    uint256 public constant ERA_GATEWAY_CHAIN_ID_STORAGE_SLOT = 53;

    /// @notice Initialize the stored addresses (call after anvil_setCode)
    function setStoredAddresses(
        address _bridgehubAddr,
        address _chainAssetHandlerAddr,
        uint256 _eraGwChainId
    ) external {
        _storedBridgehub = _bridgehubAddr;
        _storedChainAssetHandler = _chainAssetHandlerAddr;
        _storedEraGatewayChainId = _eraGwChainId;
    }

    // ── Internal getters (read from storage instead of immutables) ──

    function _bridgehub() internal view override returns (address) {
        return _storedBridgehub;
    }

    // solhint-disable-next-line func-name-mixedcase
    function L1_CHAIN_ID() public view override returns (uint256) {
        return block.chainid;
    }

    function _eraGatewayChainId() internal view override returns (uint256) {
        return _storedEraGatewayChainId;
    }

    function _chainAssetHandler() internal view override returns (address) {
        return _storedChainAssetHandler;
    }

    // ── Public getters matching L1MessageRoot interface ──

    // solhint-disable-next-line func-name-mixedcase
    function BRIDGE_HUB() external view returns (address) {
        return _storedBridgehub;
    }

    // solhint-disable-next-line func-name-mixedcase
    function ERA_GATEWAY_CHAIN_ID() external view returns (uint256) {
        return _storedEraGatewayChainId;
    }

    // solhint-disable-next-line func-name-mixedcase
    function CHAIN_ASSET_HANDLER() external view returns (address) {
        return _storedChainAssetHandler;
    }

    // ── IL1MessageRoot implementation ──

    function isPreV31(uint256 _chainId) external view returns (bool) {
        return v31UpgradeChainBatchNumber[_chainId] == V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE;
    }

    function saveV31UpgradeChainBatchNumber(uint256 _chainId) external onlyChain(_chainId) {
        // No-op for testing
        v31UpgradeChainBatchNumber[_chainId] = 1;
    }

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

    // Override the recursive proof to always return true
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
