// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";

import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {Call} from "contracts/governance/Common.sol";

import {
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_VERSION_SPECIFIC_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";

import {IL2V29Upgrade} from "contracts/upgrades/IL2V29Upgrade.sol";

import {Utils} from "../../utils/Utils.sol";
import {StateTransitionDeployedAddresses, ChainCreationParamsConfig} from "../../utils/Types.sol";
import {EraZkosContract, FactoryDepsResult} from "../../utils/EraZkosRouter.sol";
import {DefaultGatewayUpgrade} from "../default-upgrade/DefaultGatewayUpgrade.s.sol";

// FIXME: consider deleting this script, it is not used.
/// @notice Script used for v31 gateway upgrade flow
contract GatewayUpgrade_v31 is Script, DefaultGatewayUpgrade {
    /// @dev Prepared in getProposedUpgrade, consumed in getL2UpgradeTargetAndData (which must be view).
    bytes internal l2V29UpgradeBytecodeInfo;

    function getForceDeploymentContracts()
        internal
        override
        returns (EraZkosContract[] memory forceDeploymentContracts)
    {
        if (config.isZKsyncOS) {
            return new EraZkosContract[](0);
        }
        forceDeploymentContracts = new EraZkosContract[](1);
        forceDeploymentContracts[0] = EraZkosContract.L2V29Upgrade;
    }

    function getProposedUpgrade(
        StateTransitionDeployedAddresses memory stateTransition,
        ChainCreationParamsConfig memory chainCreationParams,
        uint256,
        address,
        FactoryDepsResult memory _factoryDepsResult,
        uint256 protocolUpgradeNonce
    ) public virtual override returns (ProposedUpgrade memory proposedUpgrade) {
        if (!config.isZKsyncOS) {
            return
                super.getProposedUpgrade(
                    stateTransition,
                    chainCreationParams,
                    config.l1ChainId,
                    config.ownerAddress,
                    _factoryDepsResult,
                    protocolUpgradeNonce
                );
        }

        // For ZKsyncOS, prepare bytecode info before composeUpgradeTx calls getL2UpgradeTargetAndData.
        l2V29UpgradeBytecodeInfo = Utils.getZKOSProxyUpgradeBytecodeInfo("L2V29Upgrade.sol", "L2V29Upgrade");
        IL2ContractDeployer.ForceDeployment[] memory forceDeployments = buildUpgradeForceDeployments(
            config.l1ChainId,
            config.ownerAddress
        );

        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: composeUpgradeTx(forceDeployments, _factoryDepsResult, protocolUpgradeNonce),
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

    function getL2UpgradeTargetAndData(
        IL2ContractDeployer.ForceDeployment[] memory _forceDeployments
    ) internal view override returns (address, bytes memory) {
        bytes32 ethAssetId = IL1AssetRouter(address(bridgehub.assetRouter())).ETH_TOKEN_ASSET_ID();
        bytes memory v29UpgradeCalldata = abi.encodeCall(
            IL2V29Upgrade.upgrade,
            (AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress), ethAssetId)
        );

        if (config.isZKsyncOS) {
            require(l2V29UpgradeBytecodeInfo.length > 0, "L2V29Upgrade bytecode info not prepared");
            IComplexUpgrader.UniversalContractUpgradeInfo[]
                memory universalDeployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
            universalDeployments[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade,
                deployedBytecodeInfo: l2V29UpgradeBytecodeInfo,
                newAddress: L2_VERSION_SPECIFIC_UPGRADER_ADDR
            });
            return (
                address(L2_COMPLEX_UPGRADER_ADDR),
                abi.encodeCall(
                    IComplexUpgrader.forceDeployAndUpgradeUniversal,
                    (universalDeployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, v29UpgradeCalldata)
                )
            );
        }

        return (
            address(L2_COMPLEX_UPGRADER_ADDR),
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgrade,
                (_forceDeployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, v29UpgradeCalldata)
            )
        );
    }
}
