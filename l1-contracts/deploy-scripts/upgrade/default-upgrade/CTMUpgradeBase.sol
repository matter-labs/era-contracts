// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {L2_FORCE_DEPLOYER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {PublishFactoryDepsResult} from "../../utils/bytecode/BytecodePublisher.s.sol";
import {CoreContract} from "../../ecosystem/CoreContract.sol";
import {ChainCreationParamsConfig, StateTransitionDeployedAddresses} from "../../utils/Types.sol";
import {ProposedUpgrade, ProposedUpgradeLib} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {DeployCTMScript} from "../../ctm/DeployCTM.s.sol";
import {FacetCutsLib} from "./FacetCutsLib.sol";
import {UpgradeHelperLib} from "./UpgradeHelperLib.sol";

abstract contract CTMUpgradeBase is DeployCTMScript {
    /// @notice Build the active VM's full force-deployment list in universal format.
    function getUniversalForceDeployments(
        uint256 _l1ChainId,
        address _ownerAddress
    ) internal virtual returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments);

    /// @notice Override to add version-specific force deployments in universal format.
    function getAdditionalUniversalForceDeployments()
        internal
        virtual
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments)
    {
        return new IComplexUpgrader.UniversalContractUpgradeInfo[](0);
    }

    /// @notice Override to add version-specific bytecodes to the factory deps publication set.
    function getAdditionalFactoryDependencyContracts()
        internal
        virtual
        returns (CoreContract[] memory additionalDependencyContracts)
    {
        return new CoreContract[](0);
    }

    /// @notice Get L2 upgrade target and data for the active VM.
    function getL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual returns (address, bytes memory);

    /// @notice Get the L1 -> L2 upgrade transaction type for the active VM.
    function getUpgradeTxType() internal virtual returns (uint256);

    /// @notice Build L1 -> L2 upgrade tx
    function composeUpgradeTx(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments,
        PublishFactoryDepsResult memory _factoryDepsResult,
        uint256 _protocolUpgradeNonce
    ) internal returns (L2CanonicalTransaction memory transaction) {
        validateUniversalForceDeployments(_deployments, _factoryDepsResult);
        (address target, bytes memory data) = getL2UpgradeTargetAndData(_deployments);

        transaction = L2CanonicalTransaction({
            txType: getUpgradeTxType(),
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

    function validateUniversalForceDeployments(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments,
        PublishFactoryDepsResult memory _factoryDepsResult
    ) internal virtual {
        // Era force deployments must have bytecode hashes in factory deps.
        for (uint256 i; i < _deployments.length; i++) {
            if (_deployments[i].upgradeType == IComplexUpgrader.ContractUpgradeType.EraForceDeployment) {
                IL2ContractDeployer.ForceDeployment memory fd = abi.decode(
                    _deployments[i].deployedBytecodeInfo,
                    (IL2ContractDeployer.ForceDeployment)
                );
                require(_isHashInFactoryDeps(_factoryDepsResult, fd.bytecodeHash), "Bytecode hash not in factory deps");
            }
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
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments = getUniversalForceDeployments(
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
}
