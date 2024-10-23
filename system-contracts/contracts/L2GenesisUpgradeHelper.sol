// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {DEPLOYER_SYSTEM_CONTRACT, L2_BRIDGE_HUB, L2_ASSET_ROUTER, L2_MESSAGE_ROOT, L2_NATIVE_TOKEN_VAULT_ADDR} from "./Constants.sol";
import {IContractDeployer, ForceDeployment} from "./interfaces/IContractDeployer.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {FixedForceDeploymentsData, ZKChainSpecificForceDeploymentsData} from "./interfaces/IL2GenesisUpgrade.sol";
import {IL2SharedBridgeLegacy} from "./interfaces/IL2SharedBridgeLegacy.sol";
import {L2_CREATE2_FACTORY, WRAPPED_BASE_TOKEN_IMPL_ADDRESS, DEPLOYER_SYSTEM_CONTRACT, L2_ASSET_ROUTER} from "./Constants.sol";
import {IL2WrappedBaseToken} from "./interfaces/IL2WrappedBaseToken.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

library L2GenesisUpgradeHelper {
    function performForceDeployedContractsInit(
        address _ctmDeployer,
        bytes memory _fixedForceDeploymentsData,
        bytes memory _additionalForceDeploymentsData
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
        bytes memory _fixedForceDeploymentsData,
        bytes memory _additionalForceDeploymentsData
    ) internal returns (ForceDeployment[] memory forceDeployments) {
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

        address wrappedBaseTokenAddress = _ensureWethToken(
            additionalForceDeploymentsData.predeployedL2WethAddress,
            fixedForceDeploymentsData.aliasedL1Governance,
            additionalForceDeploymentsData.baseTokenL1Address,
            additionalForceDeploymentsData.baseTokenName,
            additionalForceDeploymentsData.baseTokenSymbol
        );

        address deployedTokenBeacon;
        if (additionalForceDeploymentsData.l2LegacySharedBridge != address(0)) {
            deployedTokenBeacon = address(IL2SharedBridgeLegacy(additionalForceDeploymentsData.l2LegacySharedBridge).l2TokenBeacon());
        }

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
                deployedTokenBeacon,
                false,
                wrappedBaseTokenAddress,
                additionalForceDeploymentsData.baseTokenAssetId
            )
        });
    }

    function _ensureWethToken(
        address _predeployedWethToken,
        address _aliasedL1Governance,
        address _baseTokenL1Address,
        string memory _baseTokenName,
        string memory _baseTokenSymbol
    ) internal returns (address) {
        if(_predeployedWethToken != address(0) && _predeployedWethToken.code.length > 0) {
            return _predeployedWethToken;
        }

        string memory wrappedBaseTokenName = string.concat(
            "Wrapped ",
            _baseTokenName
        );
        string memory wrappedBaseTokenSymbol = string.concat(
            "W",
            _baseTokenSymbol
        );

        bytes memory initData = abi.encodeCall(
            IL2WrappedBaseToken.initializeV2,
            (wrappedBaseTokenName, wrappedBaseTokenSymbol, L2_ASSET_ROUTER, _baseTokenL1Address)
        );  
        bytes memory constructoParams = abi.encode(
            WRAPPED_BASE_TOKEN_IMPL_ADDRESS,
            _aliasedL1Governance,
            initData
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy{salt: bytes32(0)}(WRAPPED_BASE_TOKEN_IMPL_ADDRESS, _aliasedL1Governance, initData);

        return address(proxy);
    }
}
