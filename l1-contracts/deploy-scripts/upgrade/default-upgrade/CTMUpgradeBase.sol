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
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {PublishFactoryDepsResult} from "../../utils/bytecode/BytecodePublisher.s.sol";
import {CoreContract} from "../../ecosystem/CoreContract.sol";
import {CoreOnGatewayHelper} from "../../ecosystem/CoreOnGatewayHelper.sol";
import {ChainCreationParamsConfig, CTMDeployedAddresses, StateTransitionDeployedAddresses} from "../../utils/Types.sol";
import {ProposedUpgrade, ProposedUpgradeLib} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {DeployCTMScript} from "../../ctm/DeployCTM.s.sol";
import {EraForceDeploymentsLib} from "./EraForceDeploymentsLib.sol";
import {FacetCutsLib} from "./FacetCutsLib.sol";
import {UpgradeHelperLib} from "./UpgradeHelperLib.sol";

abstract contract CTMUpgradeBase is DeployCTMScript {
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
            abi.encodeCall(IL2ContractDeployer.forceDeployOnAddresses, (EraForceDeploymentsLib.unwrap(_deployments)))
        );
    }

    /// @notice Build L1 -> L2 upgrade tx
    function composeUpgradeTx(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments,
        PublishFactoryDepsResult memory _factoryDepsResult,
        uint256 _protocolUpgradeNonce
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

        uint256 txType = UpgradeHelperLib.getUpgradeTxType(config.isZKsyncOS);
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
            nonce: _protocolUpgradeNonce,
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

    /// @notice Generate upgrade cut data.
    function generateUpgradeCutData(
        StateTransitionDeployedAddresses memory _stateTransition,
        ChainCreationParamsConfig memory _chainCreationParams,
        uint256 _l1ChainId,
        address _ownerAddress,
        PublishFactoryDepsResult memory _factoryDepsResult,
        address _registeredChainIdDiamondProxy
    ) public virtual returns (Diamond.DiamondCutData memory upgradeCutData) {
        Diamond.FacetCut[] memory facetCutsForDeletion = FacetCutsLib.getDeletionCuts(_registeredChainIdDiamondProxy);

        Diamond.FacetCut[] memory facetCuts;
        facetCuts = getChainCreationFacetCuts(_stateTransition);
        facetCuts = FacetCutsLib.merge(facetCutsForDeletion, facetCuts);
        uint256 nonce = UpgradeHelperLib.getProtocolUpgradeNonce(_chainCreationParams.latestProtocolVersion);
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
        StateTransitionDeployedAddresses memory _stateTransition,
        ChainCreationParamsConfig memory _chainCreationParams,
        uint256 _l1ChainId,
        address _ownerAddress,
        PublishFactoryDepsResult memory _factoryDepsResult,
        uint256 _protocolUpgradeNonce
    ) public virtual returns (ProposedUpgrade memory proposedUpgrade) {
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments = getAllUniversalForceDeployments(
            _l1ChainId,
            _ownerAddress
        );

        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: composeUpgradeTx(deployments, _factoryDepsResult, _protocolUpgradeNonce),
            bootloaderHash: _chainCreationParams.bootloaderHash,
            defaultAccountHash: _chainCreationParams.defaultAAHash,
            evmEmulatorHash: _chainCreationParams.evmEmulatorHash,
            // Verifier is resolved from CTM; keep zeroed fields for calldata compatibility.
            verifier: address(0),
            verifierParams: ProposedUpgradeLib.emptyVerifierParams(),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: encodePostUpgradeCalldata(_stateTransition),
            upgradeTimestamp: 0,
            newProtocolVersion: _chainCreationParams.latestProtocolVersion
        });
    }

    /// @notice Build the complete force-deployment list in the universal upgrader format for the active VM.
    function getAllUniversalForceDeployments(
        uint256 _l1ChainId,
        address _ownerAddress
    ) internal returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments) {
        return
            SystemContractsProcessing.mergeUniversalForceDeployments(
                getBaseUniversalForceDeployments(_l1ChainId, _ownerAddress),
                getAdditionalUniversalForceDeployments()
            );
    }

    function getBaseUniversalForceDeployments(
        uint256 _l1ChainId,
        address _ownerAddress
    ) internal returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments) {
        if (config.isZKsyncOS) {
            return SystemContractsProcessing.getBaseZKsyncOSForceDeployments();
        }

        return
            EraForceDeploymentsLib.wrap(SystemContractsProcessing.getBaseForceDeployments(_l1ChainId, _ownerAddress));
    }

    function getAdditionalUniversalForceDeployments()
        internal
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments)
    {
        if (config.isZKsyncOS) {
            return getAdditionalZKsyncOSForceDeployments();
        }

        CoreContract[] memory additionalForcedCoreContracts = getAdditionalForcedCoreContracts();
        IL2ContractDeployer.ForceDeployment[]
            memory additionalForceDeployments = new IL2ContractDeployer.ForceDeployment[](
                additionalForcedCoreContracts.length
            );
        for (uint256 i; i < additionalForcedCoreContracts.length; i++) {
            additionalForceDeployments[i] = CoreOnGatewayHelper.getForceDeployment(
                false,
                additionalForcedCoreContracts[i]
            );
        }
        return EraForceDeploymentsLib.wrap(additionalForceDeployments);
    }

    function getAdditionalForcedCoreContracts()
        internal
        virtual
        returns (CoreContract[] memory additionalForcedCoreContracts)
    {
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
}
