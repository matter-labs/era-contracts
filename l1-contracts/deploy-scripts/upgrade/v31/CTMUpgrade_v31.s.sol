// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {Governance} from "contracts/governance/Governance.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";

import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";

import {Call} from "contracts/governance/Common.sol";

import {L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_VERSION_SPECIFIC_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {StateTransitionDeployedAddresses, ChainCreationParamsConfig} from "../../utils/Types.sol";
import {Utils} from "../../utils/Utils.sol";
import {SystemContractsProcessing} from "../SystemContractsProcessing.s.sol";

import {DefaultEcosystemUpgrade} from "../default-upgrade/DefaultEcosystemUpgrade.s.sol";

import {IL2V31Upgrade} from "contracts/upgrades/IL2V31Upgrade.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";

/// @notice Script used for v31 upgrade flow
contract CTMUpgrade_v31 is Script, DefaultCTMUpgrade {
    bytes internal l2V31UpgradeBytecodeInfo;

    /// @notice E2e upgrade generation
    function run() public virtual override {
        revert(
            "CTMUpgrade_v31.run() is deprecated. Use --sig initializeWithArgs(...) and call preparation methods explicitly"
        );
    }

    function initialize(
        string memory permanentValuesInputPath,
        string memory newConfigPath,
        string memory upgradeEcosystemOutputPath
    ) public virtual override {
        permanentValuesInputPath;
        newConfigPath;
        upgradeEcosystemOutputPath;
        revert("CTMUpgrade_v31.initialize(permanent-values path,...) is deprecated. Use initializeWithArgs(...)");
    }

    function initializeWithArgs(
        address ctmProxy,
        address bytecodesSupplier,
        bool isZKsyncOS,
        address rollupDAManager,
        bytes32 create2FactorySalt,
        string memory newConfigPath,
        string memory upgradeEcosystemOutputPath,
        address governance
    ) public virtual override {
        super.initializeWithArgs(
            ctmProxy,
            bytecodesSupplier,
            isZKsyncOS,
            rollupDAManager,
            create2FactorySalt,
            newConfigPath,
            upgradeEcosystemOutputPath,
            governance
        );
    }

    /// @notice Deploy everything that should be deployed
    function deployNewCTMContracts() public virtual override {
        (ctmAddresses.stateTransition.defaultUpgrade) = deployUsedUpgradeContract();
        (ctmAddresses.stateTransition.genesisUpgrade) = deploySimpleContract("L1GenesisUpgrade", false);

        deployVerifiers();

        deployEIP7702Checker();
        deployUpgradeStageValidator();
        deployGovernanceUpgradeTimer();

        // Deploy BytecodesSupplier as TUPP (was a simple contract in old version)
        // This creates both implementation and proxy
        (
            ctmAddresses.stateTransition.implementations.bytecodesSupplier,
            ctmAddresses.stateTransition.proxies.bytecodesSupplier
        ) = deployTuppWithContract("BytecodesSupplier", false);

        // Deploy new ChainTypeManager implementation
        // The constructor will receive the new BytecodesSupplier proxy address
        // Select the correct ChainTypeManager based on chain type (Era vs ZKsyncOS)
        string memory ctmContractName = config.isZKsyncOS ? "ZKsyncOSChainTypeManager" : "EraChainTypeManager";
        console.log("Deploying ChainTypeManager:", ctmContractName);
        ctmAddresses.stateTransition.implementations.chainTypeManager = deploySimpleContract(ctmContractName, false);

        deployStateTransitionDiamondFacets();
    }

    /// @notice Override to deploy v31-specific upgrade contract
    function deployUsedUpgradeContract() internal virtual override returns (address) {
        console.log("Deploying SettlementLayerV31Upgrade as the chain upgrade contract");
        return deploySimpleContract("SettlementLayerV31Upgrade", false);
    }

    function getForceDeploymentNames() internal override returns (string[] memory forceDeploymentNames) {
        forceDeploymentNames = new string[](1);
        forceDeploymentNames[0] = "L2V31Upgrade";
    }

    function getExpectedL2Address(string memory contractName) public override returns (address) {
        if (compareStrings(contractName, "L2V31Upgrade")) {
            return address(L2_VERSION_SPECIFIC_UPGRADER_ADDR);
        }

        return super.getExpectedL2Address(contractName);
    }

    function getL2UpgradeTargetAndData(
        IL2ContractDeployer.ForceDeployment[] memory _forceDeployments
    ) internal view virtual override returns (address, bytes memory) {
        IL1AssetRouter assetRouter = IL1AssetRouter(address(bridgehub.assetRouter()));
        uint256 chainId = upToDateZkChain.chainId;
        bytes32 baseTokenAssetId = bridgehub.baseTokenAssetId(chainId);
        INativeTokenVaultBase nativeTokenVault = INativeTokenVaultBase(address(assetRouter.nativeTokenVault()));
        uint256 baseTokenOriginChainId = nativeTokenVault.originChainId(baseTokenAssetId);
        address baseTokenOriginAddress = baseTokenOriginChainId == block.chainid
            ? bridgehub.baseToken(chainId)
            : nativeTokenVault.originToken(baseTokenAssetId);
        bytes memory l2UpgradeCalldata = abi.encodeCall(
            IL2V31Upgrade.upgrade,
            (baseTokenOriginChainId, baseTokenOriginAddress)
        );
        if (config.isZKsyncOS) {
            require(l2V31UpgradeBytecodeInfo.length > 0, "L2V31Upgrade bytecode info not prepared");
            IComplexUpgrader.UniversalContractUpgradeInfo[] memory universalDeployments = new IComplexUpgrader
                .UniversalContractUpgradeInfo[](1);
            universalDeployments[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
                deployedBytecodeInfo: l2V31UpgradeBytecodeInfo,
                newAddress: L2_VERSION_SPECIFIC_UPGRADER_ADDR
            });
            return (
                address(L2_COMPLEX_UPGRADER_ADDR),
                abi.encodeCall(
                    IComplexUpgrader.forceDeployAndUpgradeUniversal,
                    (universalDeployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, l2UpgradeCalldata)
                )
            );
        }

        return (
            address(L2_COMPLEX_UPGRADER_ADDR),
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgrade,
                (_forceDeployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, l2UpgradeCalldata)
            )
        );
    }

    function getProposedUpgrade(
        StateTransitionDeployedAddresses memory stateTransition,
        ChainCreationParamsConfig memory chainCreationParams,
        uint256,
        address,
        uint256[] memory factoryDepsHashes,
        uint256 protocolUpgradeNonce,
        bool isZKsyncOS
    ) public virtual override returns (ProposedUpgrade memory proposedUpgrade) {
        if (!config.isZKsyncOS) {
            return super.getProposedUpgrade(
                stateTransition,
                chainCreationParams,
                config.l1ChainId,
                config.ownerAddress,
                factoryDepsHashes,
                protocolUpgradeNonce,
                isZKsyncOS
            );
        }

        // For ZKsyncOS v31 upgrades, force-deploy only the version-specific upgrader contract.
        l2V31UpgradeBytecodeInfo = Utils.getZKOSBytecodeInfoForContract("L2V31Upgrade.sol", "L2V31Upgrade");
        IL2ContractDeployer.ForceDeployment[] memory forceDeployments = getAdditionalForceDeployments();

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
            verifier: address(0),
            verifierParams: getEmptyVerifierParams(),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: encodePostUpgradeCalldata(stateTransition),
            upgradeTimestamp: 0,
            newProtocolVersion: chainCreationParams.latestProtocolVersion
        });
    }

    function getFullListOfFactoryDependencies() internal virtual override returns (bytes[] memory factoryDeps) {
        factoryDeps = super.getFullListOfFactoryDependencies();
        if (!config.isZKsyncOS) {
            return factoryDeps;
        }

        // ZKsyncOS universal upgrade flow uses deployed bytecode info for L2V31Upgrade.
        // Ensure the deployed bytecode preimage is also published in BytecodeSupplier.
        bytes memory l2V31UpgradeDeployed = Utils.readFoundryDeployedBytecodeL1("L2V31Upgrade.sol", "L2V31Upgrade");
        bytes[] memory extra = new bytes[](1);
        extra[0] = l2V31UpgradeDeployed;
        factoryDeps = SystemContractsProcessing.mergeBytesArrays(factoryDeps, extra);
        factoryDeps = SystemContractsProcessing.deduplicateBytecodes(factoryDeps);
    }
}
