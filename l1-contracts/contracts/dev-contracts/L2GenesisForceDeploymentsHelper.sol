// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {FixedForceDeploymentsData, ZKChainSpecificForceDeploymentsData} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {ICTMDeploymentTracker} from "../bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "../bridgehub/IMessageRoot.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

address constant L2_ASSET_ROUTER = address(uint160(0x10000 + 0x03));
IBridgehub constant L2_BRIDGE_HUB = IBridgehub(address(uint160(0x10000 + 0x02)));
IMessageRoot constant L2_MESSAGE_ROOT = IMessageRoot(address(uint160(0x10000 + 0x05)));
address constant L2_CHAIN_ASSET_HANDLER = address(uint160(0x10000 + 0x0a));

/// @title L2GenesisForceDeploymentsHelper (EVM-compatible version)
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice EVM-compatible version of system-contracts/contracts/L2GenesisForceDeploymentsHelper.sol.
/// The real version uses forceDeployOnAddresses and mimicCall (ZKsync VM-specific).
/// On Anvil, contracts are pre-deployed via anvil_setCode, so this version:
/// - Decodes the same force deployments data (validates encoding)
/// - Skips forceDeployOnAddresses (contracts already deployed via anvil_setCode)
/// - Calls setAddresses directly instead of via mimicCall
library L2GenesisForceDeploymentsHelper {
    /// @notice Initializes force-deployed contracts required for the L2 genesis upgrade.
    /// @param _ctmDeployer Address of the CTM Deployer contract.
    /// @param _fixedForceDeploymentsData Encoded data for forced deployment that
    /// is the same for all the chains.
    /// @param _additionalForceDeploymentsData Encoded data for force deployments that
    /// is specific for each ZK Chain.
    function performForceDeployedContractsInit(
        address _ctmDeployer,
        bytes memory _fixedForceDeploymentsData,
        bytes memory _additionalForceDeploymentsData
    ) internal {
        // Decode the fixed and additional force deployments data.
        FixedForceDeploymentsData memory fixedForceDeploymentsData = abi.decode(
            _fixedForceDeploymentsData,
            (FixedForceDeploymentsData)
        );
        ZKChainSpecificForceDeploymentsData memory additionalForceDeploymentsData = abi.decode(
            _additionalForceDeploymentsData,
            (ZKChainSpecificForceDeploymentsData)
        );

        // Silence unused variable warnings — on the real ZKsync VM, these are used
        // to build ForceDeployment[] for IContractDeployer.forceDeployOnAddresses.
        // On Anvil, contracts are pre-deployed via anvil_setCode.
        fixedForceDeploymentsData;
        additionalForceDeploymentsData;

        // The real version calls:
        //   IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses{value: msg.value}(forceDeployments);
        // On Anvil, contracts are already deployed via anvil_setCode, so we skip this.

        // The real version retrieves bridgehubOwner and uses mimicCall to call setAddresses
        // as the owner. On Anvil, Bridgehub is deployed via anvil_setCode without a constructor,
        // so owner is address(0) and onlyOwner will revert. Use a low-level call — the deployer
        // script handles owner setup and setAddresses via impersonation separately.
        bytes memory data = abi.encodeCall(
            L2_BRIDGE_HUB.setAddresses,
            (L2_ASSET_ROUTER, ICTMDeploymentTracker(_ctmDeployer), L2_MESSAGE_ROOT, L2_CHAIN_ASSET_HANDLER)
        );
        (bool success, ) = address(L2_BRIDGE_HUB).call(data);
        // Not fatal if it fails — deployer handles it via impersonation
        success;
    }
}
