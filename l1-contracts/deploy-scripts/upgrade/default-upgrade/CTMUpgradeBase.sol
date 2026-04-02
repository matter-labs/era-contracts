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
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {SYSTEM_UPGRADE_L2_TX_TYPE, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {ChainCreationParamsConfig, StateTransitionDeployedAddresses} from "../../utils/Types.sol";
import {ProposedUpgrade, ProposedUpgradeLib} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {DeployCTMScript} from "../../ctm/DeployCTM.s.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

abstract contract CTMUpgradeBase is DeployCTMScript {
    function isHashInFactoryDepsCheck(bytes32 bytecodeHash) internal view virtual returns (bool);

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
    ) internal virtual returns (address, bytes memory) {
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
    ) internal returns (L2CanonicalTransaction memory transaction) {
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
        uint256 newProtocolVersion
    ) public virtual returns (ProposedUpgrade memory proposedUpgrade) {
        proposedUpgrade = ProposedUpgradeLib.emptyProposedUpgrade(newProtocolVersion);
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
        IL2ContractDeployer.ForceDeployment[] memory forceDeployments;

        if (isZKsyncOS) {
            // ZKsyncOS uses FixedForceDeploymentsData (built in DeployCTM) instead of
            // Era-style ForceDeployment[] arrays. Return empty — the upgrade tx for
            // ZKsyncOS chains carries data through a different path.
            forceDeployments = new IL2ContractDeployer.ForceDeployment[](0);
        } else {
            IL2ContractDeployer.ForceDeployment[] memory baseForceDeployments = SystemContractsProcessing
                .getBaseForceDeployments(l1ChainId, ownerAddress);
            IL2ContractDeployer.ForceDeployment[] memory additionalForceDeployments = getAdditionalForceDeployments();
            forceDeployments = SystemContractsProcessing.mergeForceDeployments(
                baseForceDeployments,
                additionalForceDeployments
            );
        }

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
            verifierParams: ProposedUpgradeLib.emptyVerifierParams(),
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

    /// @notice Build the base ZKsyncOS force deployment array from FixedForceDeploymentsData.
    /// @dev Uses the same address list as getOtherBuiltinForceDeployments (Era) from
    /// SystemContractsProcessing. Maps each address to its ZKsyncOS bytecodeInfo from
    /// FixedForceDeploymentsData. Version-specific entries (e.g. L2V31Upgrade) should be
    /// appended by the concrete upgrade.
    /// @param _fixedForceDeploymentsData The ABI-encoded FixedForceDeploymentsData.
    function getBaseZKsyncOSForceDeployments(
        bytes memory _fixedForceDeploymentsData
    ) internal view returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments) {
        FixedForceDeploymentsData memory data = abi.decode(
            _fixedForceDeploymentsData,
            (FixedForceDeploymentsData)
        );

        // Get the canonical address list (same order as Era force deployments).
        BuiltinContractDeployInfo[] memory contracts = SystemContractsProcessing.getOtherBuiltinContracts();

        // Build a parallel bytecodeInfo array. Contracts with ZKsyncOS proxy bytecodeInfo in
        // FixedForceDeploymentsData get ZKsyncOSSystemProxyUpgrade. Others get UnsafeForceDeployment.
        bytes[] memory bytecodeInfos = new bytes[](contracts.length);
        bytecodeInfos[0] = data.bridgehubBytecodeInfo;
        bytecodeInfos[1] = data.l2AssetRouterBytecodeInfo;
        bytecodeInfos[2] = data.l2NtvBytecodeInfo;
        bytecodeInfos[3] = data.messageRootBytecodeInfo;
        // [4] L2WrappedBaseToken — no bytecodeInfo in FixedForceDeploymentsData
        // [5] L2MessageVerification — no bytecodeInfo
        bytecodeInfos[6] = data.chainAssetHandlerBytecodeInfo;
        // [7] L2InteropRootStorage — no bytecodeInfo
        bytecodeInfos[8] = data.baseTokenHolderBytecodeInfo;
        bytecodeInfos[9] = data.assetTrackerBytecodeInfo;
        bytecodeInfos[10] = data.interopCenterBytecodeInfo;
        bytecodeInfos[11] = data.interopHandlerBytecodeInfo;
        // [12] GWAssetTracker — no bytecodeInfo

        _deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](contracts.length);
        for (uint256 i = 0; i < contracts.length; i++) {
            _deployments[i] = IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: bytecodeInfos[i].length > 0
                    ? IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade
                    : IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
                deployedBytecodeInfo: bytecodeInfos[i],
                newAddress: contracts[i].addr
            });
        }
    }
}
