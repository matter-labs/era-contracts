// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../SystemContractsProcessing.s.sol";
import {Call} from "contracts/governance/Common.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
    L2_FORCE_DEPLOYER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {EraZkosContract, EraZkosRouter, PublishFactoryDepsResult} from "../../utils/EraZkosRouter.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {ChainCreationParamsConfig, StateTransitionDeployedAddresses} from "../../utils/Types.sol";
import {ProposedUpgrade, ProposedUpgradeLib} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {DeployCTMScript} from "../../ctm/DeployCTM.s.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

abstract contract CTMUpgradeBase is DeployCTMScript {
    function getEmptyVerifierParams() internal pure returns (VerifierParams memory) {
        return
            VerifierParams({
                recursionNodeLevelVkHash: bytes32(0),
                recursionLeafLevelVkHash: bytes32(0),
                recursionCircuitsSetVksHash: bytes32(0)
            });
    }

    /// @notice Get protocol upgrade nonce from protocol version
    function getProtocolUpgradeNonce(uint256 protocolVersion) internal pure returns (uint256) {
        return (protocolVersion >> 32);
    }

    /// @notice Check if upgrade is a patch upgrade
    function isPatchUpgrade(uint256 protocolVersion) internal pure returns (bool) {
        (uint32 _major, uint32 _minor, uint32 patch) = SemVer.unpackSemVer(SafeCast.toUint96(protocolVersion));
        return patch != 0;
    }

    /// @notice Get old protocol deadline (max uint256 by default)
    function getOldProtocolDeadline() internal pure returns (uint256) {
        // Note, that it is this way by design, on stage2 it
        // will be set to 0
        return type(uint256).max;
    }

    /// @notice Build empty L1 -> L2 upgrade tx
    /// @dev Only useful for patch upgrades
    function emptyUpgradeTx() internal pure returns (L2CanonicalTransaction memory) {
        return ProposedUpgradeLib.emptyL2CanonicalTransaction();
    }

    /// @notice Get L2 upgrade target and data
    function getL2UpgradeTargetAndData(
        IL2ContractDeployer.ForceDeployment[] memory _forceDeployments
    ) internal view virtual returns (address, bytes memory) {
        return (
            address(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR),
            abi.encodeCall(IL2ContractDeployer.forceDeployOnAddresses, (_forceDeployments))
        );
    }

    /// @notice Build L1 -> L2 upgrade tx
    function composeUpgradeTx(
        IL2ContractDeployer.ForceDeployment[] memory forceDeployments,
        PublishFactoryDepsResult memory _factoryDepsResult,
        uint256 protocolUpgradeNonce
    ) internal view returns (L2CanonicalTransaction memory transaction) {
        // Sanity check
        for (uint256 i; i < forceDeployments.length; i++) {
            require(
                EraZkosRouter.isHashInFactoryDeps(_factoryDepsResult, forceDeployments[i].bytecodeHash),
                "Bytecode hash not in factory deps"
            );
        }

        (address target, bytes memory data) = getL2UpgradeTargetAndData(forceDeployments);

        uint256 txType = EraZkosRouter.upgradeL2TxType(config.isZKsyncOS);
        transaction = L2CanonicalTransaction({
            txType: txType,
            from: uint256(uint160(L2_FORCE_DEPLOYER_ADDR)),
            to: uint256(uint160(target)),
            // TODO: dont use hardcoded values
            gasLimit: 72_000_000,
            gasPerPubdataByteLimit: 800,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymaster: uint256(uint160(address(0))),
            nonce: protocolUpgradeNonce,
            value: 0,
            reserved: [uint256(0), uint256(0), uint256(0), uint256(0)],
            data: data,
            signature: new bytes(0),
            // All factory deps should've been published before
            factoryDeps: _factoryDepsResult.factoryDepsHashes,
            paymasterInput: new bytes(0),
            // Reserved dynamic type for the future use-case. Using it should be avoided,
            // But it is still here, just in case we want to enable some additional functionality
            reservedDynamic: new bytes(0)
        });
    }

    /// @notice Merge two Call arrays
    function mergeCalls(Call[] memory a, Call[] memory b) internal pure returns (Call[] memory result) {
        result = new Call[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            result[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            result[a.length + i] = b[i];
        }
    }

    /// @notice Merge two FacetCut arrays
    function mergeFacets(
        Diamond.FacetCut[] memory a,
        Diamond.FacetCut[] memory b
    ) internal pure returns (Diamond.FacetCut[] memory result) {
        result = new Diamond.FacetCut[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            result[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            result[a.length + i] = b[i];
        }
    }

    error NotLatestProtocolVersion();

    /// @notice Get facet cuts that should be removed
    function getFacetCutsForDeletion(address diamond) internal view returns (Diamond.FacetCut[] memory facetCuts) {
        IZKChain.Facet[] memory facets = IZKChain(diamond).facets();

        require(
            IZKChain(diamond).getProtocolVersion() ==
                IChainTypeManager(IZKChain(diamond).getChainTypeManager()).protocolVersion(),
            NotLatestProtocolVersion()
        );

        // Freezability does not matter when deleting, so we just put false everywhere
        facetCuts = new Diamond.FacetCut[](facets.length);
        for (uint i = 0; i < facets.length; i++) {
            facetCuts[i] = Diamond.FacetCut({
                facet: address(0),
                action: Diamond.Action.Remove,
                isFreezable: false,
                selectors: facets[i].selectors
            });
        }
    }

    /// @notice Generate upgrade cut data
    function generateUpgradeCutData(
        StateTransitionDeployedAddresses memory stateTransition,
        ChainCreationParamsConfig memory chainCreationParams,
        uint256 l1ChainId,
        address ownerAddress,
        PublishFactoryDepsResult memory _factoryDepsResult,
        address registeredChainIdDiamondProxy
    ) public virtual returns (Diamond.DiamondCutData memory upgradeCutData) {
        Diamond.FacetCut[] memory facetCutsForDeletion = getFacetCutsForDeletion(registeredChainIdDiamondProxy);

        Diamond.FacetCut[] memory facetCuts;
        facetCuts = getChainCreationFacetCuts(stateTransition);
        facetCuts = mergeFacets(facetCutsForDeletion, facetCuts);
        uint256 nonce = getProtocolUpgradeNonce(chainCreationParams.latestProtocolVersion);
        ProposedUpgrade memory proposedUpgrade = getProposedUpgrade(
            stateTransition,
            chainCreationParams,
            l1ChainId,
            ownerAddress,
            _factoryDepsResult,
            nonce
        );

        upgradeCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: stateTransition.defaultUpgrade,
            initCalldata: abi.encodeCall(DefaultUpgrade.upgrade, (proposedUpgrade))
        });
    }

    function getProposedPatchUpgrade(
        uint256 newProtocolVersion
    ) public virtual returns (ProposedUpgrade memory proposedUpgrade) {
        proposedUpgrade = ProposedUpgradeLib.emptyProposedUpgrade(newProtocolVersion);
    }

    function getProposedUpgrade(
        StateTransitionDeployedAddresses memory stateTransition,
        ChainCreationParamsConfig memory chainCreationParams,
        uint256 l1ChainId,
        address ownerAddress,
        PublishFactoryDepsResult memory _factoryDepsResult,
        uint256 protocolUpgradeNonce
    ) public virtual returns (ProposedUpgrade memory proposedUpgrade) {
        IL2ContractDeployer.ForceDeployment[] memory forceDeployments = buildUpgradeForceDeployments(
            l1ChainId,
            ownerAddress
        );

        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: composeUpgradeTx(forceDeployments, _factoryDepsResult, protocolUpgradeNonce),
            bootloaderHash: chainCreationParams.bootloaderHash,
            defaultAccountHash: chainCreationParams.defaultAAHash,
            evmEmulatorHash: chainCreationParams.evmEmulatorHash,
            // Verifier is resolved from CTM; keep zeroed fields for calldata compatibility.
            verifier: address(0),
            verifierParams: ProposedUpgradeLib.emptyVerifierParams(),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: encodePostUpgradeCalldata(stateTransition),
            upgradeTimestamp: 0,
            newProtocolVersion: chainCreationParams.latestProtocolVersion
        });
    }

    /// @notice Build the full force deployment list for an upgrade.
    ///         Era: merges base system contract deployments with additional deployments.
    ///         ZKsyncOS: returns empty array (system contracts use proxy pattern).
    function buildUpgradeForceDeployments(
        uint256 _l1ChainId,
        address _ownerAddress
    ) internal virtual returns (IL2ContractDeployer.ForceDeployment[] memory forceDeployments) {
        // FIXME: this logic is not correct as force deployments are still needed to be done by the complex upgrader.
        // We did not introduce force deployments yet.
        if (config.isZKsyncOS) {
            return new IL2ContractDeployer.ForceDeployment[](0);
        }
        IL2ContractDeployer.ForceDeployment[] memory baseForceDeployments = SystemContractsProcessing
            .getBaseForceDeployments(_l1ChainId, _ownerAddress);
        IL2ContractDeployer.ForceDeployment[] memory additionalForceDeployments = getAdditionalForceDeployments();
        forceDeployments = SystemContractsProcessing.mergeForceDeployments(
            baseForceDeployments,
            additionalForceDeployments
        );
    }

    function getAdditionalForceDeployments()
        internal
        returns (IL2ContractDeployer.ForceDeployment[] memory additionalForceDeployments)
    {
        EraZkosContract[] memory forceDeploymentContracts = getForceDeploymentContracts();
        additionalForceDeployments = new IL2ContractDeployer.ForceDeployment[](forceDeploymentContracts.length);
        for (uint256 i; i < forceDeploymentContracts.length; i++) {
            additionalForceDeployments[i] = EraZkosRouter.getForceDeployment(
                config.isZKsyncOS,
                forceDeploymentContracts[i]
            );
        }
        return additionalForceDeployments;
    }

    function getAdditionalDependencyContracts()
        internal
        virtual
        returns (EraZkosContract[] memory forceDeploymentContracts)
    {
        EraZkosContract[] memory additionalForceDeploymentContracts = getForceDeploymentContracts();
        forceDeploymentContracts = new EraZkosContract[](additionalForceDeploymentContracts.length);
        for (uint256 i; i < additionalForceDeploymentContracts.length; i++) {
            forceDeploymentContracts[i] = additionalForceDeploymentContracts[i];
        }
        return forceDeploymentContracts;
    }

    function getForceDeploymentContracts()
        internal
        virtual
        returns (EraZkosContract[] memory forceDeploymentContracts)
    {
        return new EraZkosContract[](0);
    }

    /// @notice Encode calldata that will be passed to `_postUpgrade`
    /// in the on‑chain contract. Override in concrete upgrades.
    function encodePostUpgradeCalldata(
        StateTransitionDeployedAddresses memory
    ) internal virtual returns (bytes memory) {
        return new bytes(0);
    }
}
