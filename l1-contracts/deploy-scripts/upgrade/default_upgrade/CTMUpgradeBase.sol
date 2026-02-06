// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../SystemContractsProcessing.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {DeployCTMUtils} from "../../ctm/DeployCTMUtils.s.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SYSTEM_UPGRADE_L2_TX_TYPE, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {StateTransitionDeployedAddresses, ChainCreationParamsConfig} from "../../utils/Types.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {DeployCTMScript} from "../../ctm/DeployCTM.s.sol";
import {UpgradeUtils} from "./UpgradeUtils.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

abstract contract CTMUpgradeBase is DeployCTMScript {
    function isHashInFactoryDepsCheck(bytes32 bytecodeHash) internal view virtual returns (bool);

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
    function emptyUpgradeTx() internal pure returns (L2CanonicalTransaction memory transaction) {
        transaction = L2CanonicalTransaction({
            txType: 0,
            from: uint256(0),
            to: uint256(0),
            gasLimit: 0,
            gasPerPubdataByteLimit: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymaster: uint256(uint160(address(0))),
            nonce: 0,
            value: 0,
            reserved: [uint256(0), uint256(0), uint256(0), uint256(0)],
            data: new bytes(0),
            signature: new bytes(0),
            factoryDeps: new uint256[](0),
            paymasterInput: new bytes(0),
            // Reserved dynamic type for the future use-case. Using it should be avoided,
            // But it is still here, just in case we want to enable some additional functionality
            reservedDynamic: new bytes(0)
        });
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
        uint256[] memory factoryDepsHashes,
        uint256 protocolUpgradeNonce,
        bool isZKsyncOS
    ) internal view returns (L2CanonicalTransaction memory transaction) {
        // Sanity check
        for (uint256 i; i < forceDeployments.length; i++) {
            require(isHashInFactoryDepsCheck(forceDeployments[i].bytecodeHash), "Bytecode hash not in factory deps");
        }

        (address target, bytes memory data) = getL2UpgradeTargetAndData(forceDeployments);

        uint256 txType = isZKsyncOS ? ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE : SYSTEM_UPGRADE_L2_TX_TYPE;
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
            factoryDeps: factoryDepsHashes,
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
        uint256[] memory factoryDepsHashes,
        address registeredChainIdDiamondProxy,
        bool isZKsyncOS
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
            factoryDepsHashes,
            nonce,
            isZKsyncOS
        );

        upgradeCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: stateTransition.defaultUpgrade,
            initCalldata: abi.encodeCall(DefaultUpgrade.upgrade, (proposedUpgrade))
        });
    }

    function getProposedPatchUpgrade(
        StateTransitionDeployedAddresses memory /* stateTransition */,
        uint256 newProtocolVersion
    ) public virtual returns (ProposedUpgrade memory proposedUpgrade) {
        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: emptyUpgradeTx(),
            bootloaderHash: bytes32(0),
            defaultAccountHash: bytes32(0),
            evmEmulatorHash: bytes32(0),
            // Verifier is resolved from CTM; keep zeroed fields for calldata compatibility.
            verifier: address(0),
            verifierParams: getEmptyVerifierParams(),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: new bytes(0),
            upgradeTimestamp: 0,
            newProtocolVersion: newProtocolVersion
        });
    }

    function getProposedUpgrade(
        StateTransitionDeployedAddresses memory stateTransition,
        ChainCreationParamsConfig memory chainCreationParams,
        uint256 l1ChainId,
        address ownerAddress,
        uint256[] memory factoryDepsHashes,
        uint256 protocolUpgradeNonce,
        bool isZKsyncOS
    ) public virtual returns (ProposedUpgrade memory proposedUpgrade) {
        IL2ContractDeployer.ForceDeployment[] memory baseForceDeployments = SystemContractsProcessing
            .getBaseForceDeployments(l1ChainId, ownerAddress);

        // Additional force deployments after Gateway
        IL2ContractDeployer.ForceDeployment[] memory additionalForceDeployments = getAdditionalForceDeployments();

        IL2ContractDeployer.ForceDeployment[] memory forceDeployments = SystemContractsProcessing.mergeForceDeployments(
            baseForceDeployments,
            additionalForceDeployments
        );

        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: composeUpgradeTx(
                forceDeployments,
                factoryDepsHashes,
                protocolUpgradeNonce,
                isZKsyncOS
            ),
            bootloaderHash: chainCreationParams.bootloaderHash,
            defaultAccountHash: chainCreationParams.defaultAAHash,
            evmEmulatorHash: chainCreationParams.evmEmulatorHash,
            // Verifier is resolved from CTM; keep zeroed fields for calldata compatibility.
            verifier: address(0),
            verifierParams: getEmptyVerifierParams(),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: encodePostUpgradeCalldata(stateTransition),
            upgradeTimestamp: 0,
            newProtocolVersion: chainCreationParams.latestProtocolVersion
        });
    }

    function getForceDeployment(
        string memory contractName
    ) public virtual returns (IL2ContractDeployer.ForceDeployment memory forceDeployment) {
        return
            IL2ContractDeployer.ForceDeployment({
                bytecodeHash: getL2BytecodeHash(contractName),
                newAddress: getExpectedL2Address(contractName),
                callConstructor: false,
                value: 0,
                input: ""
            });
    }

    function getAdditionalForceDeployments()
        internal
        returns (IL2ContractDeployer.ForceDeployment[] memory additionalForceDeployments)
    {
        string[] memory forceDeploymentNames = getForceDeploymentNames();
        additionalForceDeployments = new IL2ContractDeployer.ForceDeployment[](forceDeploymentNames.length);
        for (uint256 i; i < forceDeploymentNames.length; i++) {
            additionalForceDeployments[i] = getForceDeployment(forceDeploymentNames[i]);
        }
        return additionalForceDeployments;
    }

    function getAdditionalDependenciesNames() internal virtual returns (string[] memory forceDeploymentNames) {
        string[] memory additionalForceDeploymentNames = getForceDeploymentNames();
        forceDeploymentNames = new string[](additionalForceDeploymentNames.length);
        for (uint256 i; i < additionalForceDeploymentNames.length; i++) {
            forceDeploymentNames[i] = additionalForceDeploymentNames[i];
        }
        return forceDeploymentNames;
    }

    function getForceDeploymentNames() internal virtual returns (string[] memory forceDeploymentNames) {
        return new string[](0);
    }

    /// @notice Encode calldata that will be passed to `_postUpgrade`
    /// in the on‑chain contract. Override in concrete upgrades.
    function encodePostUpgradeCalldata(
        StateTransitionDeployedAddresses memory
    ) internal virtual returns (bytes memory) {
        return new bytes(0);
    }

    function getExpectedL2Address(string memory contractName) public virtual returns (address) {
        return Utils.getL2AddressViaCreate2Factory(bytes32(0), getL2BytecodeHash(contractName), hex"");
    }
}
