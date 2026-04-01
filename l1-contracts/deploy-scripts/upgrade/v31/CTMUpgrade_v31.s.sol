// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {Governance} from "contracts/governance/Governance.sol";

import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";

import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";

import {Call} from "contracts/governance/Common.sol";

import {
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_VERSION_SPECIFIC_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {StateTransitionDeployedAddresses, ChainCreationParamsConfig} from "../../utils/Types.sol";
import {Utils} from "../../utils/Utils.sol";
import {SystemContractsProcessing} from "../SystemContractsProcessing.s.sol";

import {IL2V31Upgrade} from "contracts/upgrades/IL2V31Upgrade.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {EraZkosContract} from "../../utils/EraZkosRouter.sol";

/// @notice Script used for v31 upgrade flow
contract CTMUpgrade_v31 is Script, DefaultCTMUpgrade {
    bytes internal l2V31UpgradeBytecodeInfo;

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
        (, string memory ctmContractName) = vms.resolve(EraZkosContract.ChainTypeManager);
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
        if (vms.isZKsyncOS()) {
            require(l2V31UpgradeBytecodeInfo.length > 0, "L2V31Upgrade bytecode info not prepared");
            IComplexUpgrader.UniversalContractUpgradeInfo[]
                memory universalDeployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
            universalDeployments[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade,
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
        uint256 protocolUpgradeNonce
    ) public virtual override returns (ProposedUpgrade memory proposedUpgrade) {
        if (!vms.isZKsyncOS()) {
            return
                super.getProposedUpgrade(
                    stateTransition,
                    chainCreationParams,
                    config.l1ChainId,
                    config.ownerAddress,
                    factoryDepsHashes,
                    protocolUpgradeNonce
                );
        }

        // For ZKsyncOS v31 upgrades, upgrade the version-specific upgrader via proxy upgrade.
        // Prepare bytecode info for getL2UpgradeTargetAndData (used in composeUpgradeTx).
        l2V31UpgradeBytecodeInfo = Utils.getZKOSProxyUpgradeBytecodeInfo("L2V31Upgrade.sol", "L2V31Upgrade");
        // ZKsyncOS uses UniversalContractUpgradeInfo instead of ForceDeployment[];
        // buildUpgradeForceDeployments returns empty for ZKsyncOS.
        IL2ContractDeployer.ForceDeployment[] memory forceDeployments = buildUpgradeForceDeployments(
            config.l1ChainId,
            config.ownerAddress
        );

        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: composeUpgradeTx(forceDeployments, factoryDepsHashes, protocolUpgradeNonce),
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
        if (!vms.isZKsyncOS()) {
            return super.getFullListOfFactoryDependencies();
        }

        bytes memory l2V31UpgradeDeployed = Utils.readFoundryDeployedBytecodeL1("L2V31Upgrade.sol", "L2V31Upgrade");
        factoryDeps = new bytes[](1);
        factoryDeps[0] = l2V31UpgradeDeployed;
    }
}
