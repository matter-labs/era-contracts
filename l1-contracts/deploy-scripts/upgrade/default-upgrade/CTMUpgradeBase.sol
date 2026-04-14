// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../SystemContractsProcessing.s.sol";
import {Call} from "contracts/governance/Common.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {
    L2_COMPLEX_UPGRADER_ADDR,
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
    L2_FORCE_DEPLOYER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {SYSTEM_UPGRADE_L2_TX_TYPE, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {PublishFactoryDepsResult} from "../../utils/bytecode/BytecodePublisher.s.sol";
import {CoreContract} from "../../ecosystem/CoreContract.sol";
import {CoreOnGatewayHelper} from "../../ecosystem/CoreOnGatewayHelper.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {ChainCreationParamsConfig, CTMDeployedAddresses, StateTransitionDeployedAddresses} from "../../utils/Types.sol";
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

    /// @notice Returns the L2 upgrade transaction type for the active VM.
    function _getUpgradeTxType() internal view returns (uint256) {
        return config.isZKsyncOS ? ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE : SYSTEM_UPGRADE_L2_TX_TYPE;
    }

    /// @notice Get L2 upgrade target and data.
    /// @dev From V32 onwards, both Era and ZKsyncOS should use forceDeployAndUpgradeUniversal
    /// (via L2_COMPLEX_UPGRADER_ADDR) since it supports both chain types via ContractUpgradeType.
    /// The Era branch below uses forceDeployOnAddresses only because V31 Era chains do not yet
    /// have forceDeployAndUpgradeUniversal deployed.
    function getL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual returns (address, bytes memory) {
        if (config.isZKsyncOS) {
            return (
                address(L2_COMPLEX_UPGRADER_ADDR),
                abi.encodeCall(IComplexUpgrader.forceDeployAndUpgradeUniversal, (_deployments, address(0), ""))
            );
        }
        return (
            address(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR),
            abi.encodeCall(IL2ContractDeployer.forceDeployOnAddresses, (unwrapEraDeployments(_deployments)))
        );
    }

    /// @notice Build L1 -> L2 upgrade tx
    function composeUpgradeTx(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments,
        PublishFactoryDepsResult memory _factoryDepsResult,
        uint256 protocolUpgradeNonce
    ) internal returns (L2CanonicalTransaction memory transaction) {
        // Sanity check: verify Era bytecodeHashes are in factory deps
        for (uint256 i; i < _deployments.length; i++) {
            if (_deployments[i].upgradeType == IComplexUpgrader.ContractUpgradeType.EraForceDeployment) {
                IL2ContractDeployer.ForceDeployment memory fd = abi.decode(
                    _deployments[i].deployedBytecodeInfo,
                    (IL2ContractDeployer.ForceDeployment)
                );
                require(_isHashInFactoryDeps(_factoryDepsResult, fd.bytecodeHash), "Bytecode hash not in factory deps");
            }
        }

        (address target, bytes memory data) = getL2UpgradeTargetAndData(_deployments);

        uint256 txType = _getUpgradeTxType();
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

    /// @notice Generate upgrade cut data.
    function generateUpgradeCutData(
        StateTransitionDeployedAddresses memory _stateTransition,
        ChainCreationParamsConfig memory _chainCreationParams,
        uint256 _l1ChainId,
        address _ownerAddress,
        PublishFactoryDepsResult memory _factoryDepsResult,
        address _registeredChainIdDiamondProxy
    ) public virtual returns (Diamond.DiamondCutData memory upgradeCutData) {
        Diamond.FacetCut[] memory facetCutsForDeletion = getFacetCutsForDeletion(_registeredChainIdDiamondProxy);

        Diamond.FacetCut[] memory facetCuts;
        facetCuts = getChainCreationFacetCuts(_stateTransition);
        facetCuts = mergeFacets(facetCutsForDeletion, facetCuts);
        uint256 nonce = getProtocolUpgradeNonce(_chainCreationParams.latestProtocolVersion);
        ProposedUpgrade memory proposedUpgrade = getProposedUpgrade(
            _stateTransition,
            _chainCreationParams,
            _l1ChainId,
            _ownerAddress,
            _factoryDepsResult,
            nonce
        );

        upgradeCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: _stateTransition.defaultUpgrade,
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
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments;

        if (config.isZKsyncOS) {
            FixedForceDeploymentsData memory fixedData = getFixedForceDeploymentsData();
            deployments = buildZKsyncOSForceDeployments(fixedData);
        } else {
            IL2ContractDeployer.ForceDeployment[] memory baseForceDeployments = SystemContractsProcessing
                .getBaseForceDeployments(l1ChainId, ownerAddress);
            IL2ContractDeployer.ForceDeployment[] memory additionalForceDeployments = getAdditionalForceDeployments();
            deployments = wrapEraDeployments(
                SystemContractsProcessing.mergeForceDeployments(baseForceDeployments, additionalForceDeployments)
            );
        }

        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: composeUpgradeTx(deployments, _factoryDepsResult, protocolUpgradeNonce),
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

    function getAdditionalForceDeployments()
        internal
        returns (IL2ContractDeployer.ForceDeployment[] memory additionalForceDeployments)
    {
        CoreContract[] memory forceDeploymentContracts = getForceDeploymentContracts();
        additionalForceDeployments = new IL2ContractDeployer.ForceDeployment[](forceDeploymentContracts.length);
        for (uint256 i; i < forceDeploymentContracts.length; i++) {
            additionalForceDeployments[i] = CoreOnGatewayHelper.getForceDeployment(
                config.isZKsyncOS,
                forceDeploymentContracts[i]
            );
        }
        return additionalForceDeployments;
    }

    function getAdditionalDependencyContracts()
        internal
        virtual
        returns (CoreContract[] memory forceDeploymentContracts)
    {
        CoreContract[] memory additionalForceDeploymentContracts = getForceDeploymentContracts();
        forceDeploymentContracts = new CoreContract[](additionalForceDeploymentContracts.length);
        for (uint256 i; i < additionalForceDeploymentContracts.length; i++) {
            forceDeploymentContracts[i] = additionalForceDeploymentContracts[i];
        }
        return forceDeploymentContracts;
    }

    function getForceDeploymentContracts() internal virtual returns (CoreContract[] memory forceDeploymentContracts) {
        return new CoreContract[](0);
    }

    /// @notice Encode calldata that will be passed to `_postUpgrade`
    /// in the on‑chain contract. Override in concrete upgrades.
    function encodePostUpgradeCalldata(
        StateTransitionDeployedAddresses memory
    ) internal virtual returns (bytes memory) {
        return new bytes(0);
    }

    function _isHashInFactoryDeps(PublishFactoryDepsResult memory _result, bytes32 _hash) private pure returns (bool) {
        if (_result.factoryDepsHashes.length == 0) {
            return true;
        }
        for (uint256 i = 0; i < _result.factoryDepsHashes.length; i++) {
            if (bytes32(_result.factoryDepsHashes[i]) == _hash) {
                return true;
            }
        }
        return false;
    }

    /// @notice Build the full ZKsyncOS force deployment array: base builtins + version-specific entries.
    /// @param _fixedData Already-loaded FixedForceDeploymentsData to reuse bytecodeInfo (avoids OOM).
    function buildZKsyncOSForceDeployments(
        FixedForceDeploymentsData memory _fixedData
    ) internal returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory) {
        return
            SystemContractsProcessing.buildZKsyncOSForceDeployments(
                _fixedData,
                getAdditionalZKsyncOSForceDeployments()
            );
    }

    /// @notice Returns the FixedForceDeploymentsData for bytecodeInfo reuse.
    /// @dev Override in DefaultCTMUpgrade to return cached data (avoids double-loading).
    function getFixedForceDeploymentsData() internal virtual returns (FixedForceDeploymentsData memory);

    /// @notice Override to provide version-specific ZKsyncOS force deployment entries.
    function getAdditionalZKsyncOSForceDeployments()
        internal
        virtual
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory)
    {
        return new IComplexUpgrader.UniversalContractUpgradeInfo[](0);
    }

    /// @notice Wrap Era ForceDeployment[] into UniversalContractUpgradeInfo[].
    /// Each ForceDeployment is abi-encoded into deployedBytecodeInfo so it can be
    /// unwrapped back losslessly when encoding the L2 calldata.
    function wrapEraDeployments(
        IL2ContractDeployer.ForceDeployment[] memory _fds
    ) internal pure returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory _result) {
        _result = new IComplexUpgrader.UniversalContractUpgradeInfo[](_fds.length);
        for (uint256 i = 0; i < _fds.length; i++) {
            _result[i] = IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: IComplexUpgrader.ContractUpgradeType.EraForceDeployment,
                deployedBytecodeInfo: abi.encode(_fds[i]),
                newAddress: _fds[i].newAddress
            });
        }
    }

    /// @notice Unwrap Era entries from UniversalContractUpgradeInfo[] back to ForceDeployment[].
    function unwrapEraDeployments(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _infos
    ) internal pure returns (IL2ContractDeployer.ForceDeployment[] memory _result) {
        uint256 count = 0;
        for (uint256 i = 0; i < _infos.length; i++) {
            if (_infos[i].upgradeType == IComplexUpgrader.ContractUpgradeType.EraForceDeployment) {
                count++;
            }
        }
        _result = new IL2ContractDeployer.ForceDeployment[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < _infos.length; i++) {
            if (_infos[i].upgradeType == IComplexUpgrader.ContractUpgradeType.EraForceDeployment) {
                _result[idx++] = abi.decode(_infos[i].deployedBytecodeInfo, (IL2ContractDeployer.ForceDeployment));
            }
        }
    }
}
