// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2EcosystemContract} from "./ContractIdentifiers.sol";
import {RegistryMemberHasNoFixedAddress} from "../../../common/L1ContractErrors.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_TRACKER_ADDR,
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_ECOSYSTEM_REGISTRY_ADDR,
    L2_INTEROP_ATTRIBUTE_PARSER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_INTEROP_ROOT_STORAGE_ADDR,
    L2_MESSAGE_ROOT_ADDR,
    L2_MESSAGE_VERIFICATION_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_NTV_BEACON_DEPLOYER_ADDR,
    L2_REMOVED_GW_ASSET_TRACKER_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
    L2_VERSION_SPECIFIC_UPGRADER_ADDR,
    L2_WRAPPED_BASE_TOKEN_IMPL_ADDR
} from "../../../common/l2-helpers/L2ContractAddresses.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The canonical {L2EcosystemContract} member -> fixed L2 address mapping. Single source
///         for both the on-chain L2 deployment derivation ({TransitionDerivationLib}) and the
///         deploy tooling's composition, so the two can never place a member at different
///         addresses.
library L2InventoryLib {
    /// @notice The fixed L2 address a force deployment of `_member` targets.
    /// @dev Reverts for the bytecode-identity members (proxies, bridged-token templates): they
    ///      have no fixed address, so a release table row for them is unexecutable — the revert
    ///      surfaces at transition construction, before anything is committed.
    // solhint-disable-next-line code-complexity
    function fixedAddress(L2EcosystemContract _member) internal pure returns (address) {
        if (_member == L2EcosystemContract.L2Bridgehub) {
            return L2_BRIDGEHUB_ADDR;
        }
        if (_member == L2EcosystemContract.L2AssetRouter) {
            return L2_ASSET_ROUTER_ADDR;
        }
        if (_member == L2EcosystemContract.L2NativeTokenVault) {
            return L2_NATIVE_TOKEN_VAULT_ADDR;
        }
        if (_member == L2EcosystemContract.L2MessageRoot) {
            return L2_MESSAGE_ROOT_ADDR;
        }
        if (_member == L2EcosystemContract.UpgradeableBeaconDeployer) {
            return L2_NTV_BEACON_DEPLOYER_ADDR;
        }
        if (_member == L2EcosystemContract.BaseTokenHolder) {
            return L2_BASE_TOKEN_HOLDER_ADDR;
        }
        if (_member == L2EcosystemContract.L2ChainAssetHandler) {
            return L2_CHAIN_ASSET_HANDLER_ADDR;
        }
        if (_member == L2EcosystemContract.InteropCenter) {
            return L2_INTEROP_CENTER_ADDR;
        }
        if (_member == L2EcosystemContract.InteropAttributeParser) {
            return L2_INTEROP_ATTRIBUTE_PARSER_ADDR;
        }
        if (_member == L2EcosystemContract.L2InteropHandler) {
            return L2_INTEROP_HANDLER_ADDR;
        }
        if (_member == L2EcosystemContract.L2AssetTracker) {
            return L2_ASSET_TRACKER_ADDR;
        }
        if (_member == L2EcosystemContract.L2WrappedBaseToken) {
            return L2_WRAPPED_BASE_TOKEN_IMPL_ADDR;
        }
        if (_member == L2EcosystemContract.L2MessageVerification) {
            return L2_MESSAGE_VERIFICATION_ADDR;
        }
        if (_member == L2EcosystemContract.L2InteropRootStorage) {
            return L2_INTEROP_ROOT_STORAGE_ADDR;
        }
        if (_member == L2EcosystemContract.L2V34Upgrade) {
            return L2_VERSION_SPECIFIC_UPGRADER_ADDR;
        }
        if (_member == L2EcosystemContract.L2InteropCommitmentTree) {
            return L2_INTEROP_COMMITMENT_TREE_ADDR;
        }
        if (_member == L2EcosystemContract.AtomicFlowManager) {
            return L2_ATOMIC_FLOW_MANAGER_ADDR;
        }
        if (_member == L2EcosystemContract.L2BaseToken) {
            return L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR;
        }
        if (_member == L2EcosystemContract.L1Messenger) {
            return L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR;
        }
        if (_member == L2EcosystemContract.SystemContext) {
            return L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR;
        }
        if (_member == L2EcosystemContract.RemovedGWAssetTracker) {
            return L2_REMOVED_GW_ASSET_TRACKER_ADDR;
        }
        if (_member == L2EcosystemContract.L2EcosystemRegistry) {
            return L2_ECOSYSTEM_REGISTRY_ADDR;
        }
        revert RegistryMemberHasNoFixedAddress(uint256(_member));
    }
}
