// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL2EcosystemRegistry} from "./IL2EcosystemRegistry.sol";
import {FixedForceDeploymentsData} from "../../state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {EmptyData, InvalidCaller} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IL2EcosystemRegistry}. A ZKsync OS built-in at `L2_ECOSYSTEM_REGISTRY_ADDR`,
///         written registry-first by the genesis / upgrade initialization
///         (`L2GenesisForceDeploymentsHelper`) with the exact bytes the L1 release pins.
///         Lifecycle: {protocol-docs/chain-lifecycle.md#the-l2-ecosystem-registry}.
/// @dev Stores the ABI ENCODING and decodes on read — the same store-the-encoding pattern as the
///      L1 registry objects: one assignment, no field-by-field transcription that could drift,
///      and `dataHash` is the hash of the pinned bytes by construction. Reads are views; the rare
///      on-chain consumer pays the decode, which is what keeps the write path a single store.
/// @dev No constructor and no immutables: L2 built-ins do not support them. Not write-once
///      either — every protocol upgrade re-pins the data, since its shape and content are
///      release-scoped (the registry's own bytecode is force-deployed fresh by the same upgrade,
///      so code and encoding always match).
contract L2EcosystemRegistry is IL2EcosystemRegistry {
    /// @dev THE data, stored as its own ABI encoding — see the contract doc.
    bytes internal encodedFixedForceDeploymentsData;

    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert InvalidCaller(msg.sender);
        }
        _;
    }

    /// @inheritdoc IL2EcosystemRegistry
    function updateL2(bytes calldata _fixedForceDeploymentsData) external onlyUpgrader {
        if (_fixedForceDeploymentsData.length == 0) {
            revert EmptyData();
        }
        // Shape check only: a malformed encoding must fail HERE, in the upgrade transaction,
        // not in every later read. Content is governance-reviewed data pinned by the release.
        abi.decode(_fixedForceDeploymentsData, (FixedForceDeploymentsData));
        encodedFixedForceDeploymentsData = _fixedForceDeploymentsData;
        emit EcosystemDataUpdated(keccak256(_fixedForceDeploymentsData));
    }

    /// @inheritdoc IL2EcosystemRegistry
    function dataHash() external view returns (bytes32) {
        return keccak256(encodedFixedForceDeploymentsData);
    }

    /// @inheritdoc IL2EcosystemRegistry
    function getFixedForceDeploymentsData() public view returns (FixedForceDeploymentsData memory) {
        return abi.decode(encodedFixedForceDeploymentsData, (FixedForceDeploymentsData));
    }

    /// @inheritdoc IL2EcosystemRegistry
    function l1ChainId() external view returns (uint256) {
        return getFixedForceDeploymentsData().l1ChainId;
    }

    /// @inheritdoc IL2EcosystemRegistry
    function eraChainId() external view returns (uint256) {
        return getFixedForceDeploymentsData().eraChainId;
    }

    /// @inheritdoc IL2EcosystemRegistry
    function l1AssetRouter() external view returns (address) {
        return getFixedForceDeploymentsData().l1AssetRouter;
    }

    /// @inheritdoc IL2EcosystemRegistry
    function aliasedL1Governance() external view returns (address) {
        return getFixedForceDeploymentsData().aliasedL1Governance;
    }

    /// @inheritdoc IL2EcosystemRegistry
    function aliasedChainRegistrationSender() external view returns (address) {
        return getFixedForceDeploymentsData().aliasedChainRegistrationSender;
    }

    /// @inheritdoc IL2EcosystemRegistry
    function zkTokenAssetId() external view returns (bytes32) {
        return getFixedForceDeploymentsData().zkTokenAssetId;
    }
}
