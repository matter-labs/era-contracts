// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {DEPLOYER_SYSTEM_CONTRACT, L2_BRIDGE_HUB, L2_ASSET_ROUTER, L2_MESSAGE_ROOT, L2_NATIVE_TOKEN_VAULT_ADDR} from "./Constants.sol";
import {IContractDeployer, ForceDeployment} from "./interfaces/IContractDeployer.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {FixedForceDeploymentsData, ZKChainSpecificForceDeploymentsData} from "./interfaces/IL2GenesisUpgrade.sol";

library L2GatewayUpgradeHelper {
    function performGatewayContractsInit(
        address _ctmDeployer,
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) internal {
        ForceDeployment[] memory forceDeployments = _getForceDeploymentsData(
            _fixedForceDeploymentsData,
            _additionalForceDeploymentsData
        );
        IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses{value: msg.value}(forceDeployments);

        // It is expected that either via to the force deployments above
        // or upon init both the L2 deployment of Bridgehub, AssetRouter and MessageRoot are deployed.
        // (The comment does not mention the exact order in case it changes)
        // However, there is still some follow up finalization that needs to be done.

        address bridgehubOwner = L2_BRIDGE_HUB.owner();

        bytes memory data = abi.encodeCall(
            L2_BRIDGE_HUB.setAddresses,
            (L2_ASSET_ROUTER, _ctmDeployer, address(L2_MESSAGE_ROOT))
        );

        (bool success, bytes memory returnData) = SystemContractHelper.mimicCall(
            address(L2_BRIDGE_HUB),
            bridgehubOwner,
            data
        );
        if (!success) {
            // Progapatate revert reason
            assembly {
                revert(add(returnData, 0x20), returndatasize())
            }
        }
    }

    function _getForceDeploymentsData(
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) internal view returns (ForceDeployment[] memory forceDeployments) {
        FixedForceDeploymentsData memory fixedForceDeploymentsData = abi.decode(
            _fixedForceDeploymentsData,
            (FixedForceDeploymentsData)
        );
        ZKChainSpecificForceDeploymentsData memory additionalForceDeploymentsData = abi.decode(
            _additionalForceDeploymentsData,
            (ZKChainSpecificForceDeploymentsData)
        );

        forceDeployments = new ForceDeployment[](4);

        forceDeployments[0] = ForceDeployment({
            bytecodeHash: fixedForceDeploymentsData.messageRootBytecodeHash,
            newAddress: address(L2_MESSAGE_ROOT),
            callConstructor: true,
            value: 0,
            // solhint-disable-next-line func-named-parameters
            input: abi.encode(address(L2_BRIDGE_HUB))
        });

        forceDeployments[1] = ForceDeployment({
            bytecodeHash: fixedForceDeploymentsData.bridgehubBytecodeHash,
            newAddress: address(L2_BRIDGE_HUB),
            callConstructor: true,
            value: 0,
            input: abi.encode(
                fixedForceDeploymentsData.l1ChainId,
                fixedForceDeploymentsData.aliasedL1Governance,
                fixedForceDeploymentsData.maxNumberOfZKChains
            )
        });

        forceDeployments[2] = ForceDeployment({
            bytecodeHash: fixedForceDeploymentsData.l2AssetRouterBytecodeHash,
            newAddress: address(L2_ASSET_ROUTER),
            callConstructor: true,
            value: 0,
            // solhint-disable-next-line func-named-parameters
            input: abi.encode(
                fixedForceDeploymentsData.l1ChainId,
                fixedForceDeploymentsData.eraChainId,
                fixedForceDeploymentsData.l1AssetRouter,
                additionalForceDeploymentsData.l2LegacySharedBridge,
                additionalForceDeploymentsData.baseTokenAssetId,
                fixedForceDeploymentsData.aliasedL1Governance
            )
        });

        forceDeployments[3] = ForceDeployment({
            bytecodeHash: fixedForceDeploymentsData.l2NtvBytecodeHash,
            newAddress: L2_NATIVE_TOKEN_VAULT_ADDR,
            callConstructor: true,
            value: 0,
            // solhint-disable-next-line func-named-parameters
            input: abi.encode(
                fixedForceDeploymentsData.l1ChainId,
                fixedForceDeploymentsData.aliasedL1Governance,
                fixedForceDeploymentsData.l2TokenProxyBytecodeHash,
                additionalForceDeploymentsData.l2LegacySharedBridge,
                address(0), // this is used if the contract were already deployed, so for the migration of Era.
                false,
                additionalForceDeploymentsData.l2Weth,
                additionalForceDeploymentsData.baseTokenAssetId
            )
        });
    }
}
