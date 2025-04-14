// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {DEPLOYER_SYSTEM_CONTRACT, L2_BRIDGE_HUB, L2_ASSET_ROUTER, L2_MESSAGE_ROOT, L2_NATIVE_TOKEN_VAULT_ADDR} from "./Constants.sol";
import {IContractDeployer, ForceDeployment} from "./interfaces/IContractDeployer.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {FixedForceDeploymentsData, ZKChainSpecificForceDeploymentsData} from "./interfaces/IL2GenesisUpgrade.sol";
import {IL2SharedBridgeLegacy} from "./interfaces/IL2SharedBridgeLegacy.sol";
import {WRAPPED_BASE_TOKEN_IMPL_ADDRESS, L2_ASSET_ROUTER} from "./Constants.sol";
import {IL2WrappedBaseToken} from "./interfaces/IL2WrappedBaseToken.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title L2GenesisForceDeploymentsHelper
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A helper library for initializing and managing force-deployed contracts during either the L2 gateway upgrade or
/// the genesis after the gateway protocol upgrade.
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
        // Decode and retrieve the force deployments data.
        ForceDeployment[] memory forceDeployments = _getForceDeploymentsData(
            _fixedForceDeploymentsData,
            _additionalForceDeploymentsData
        );

        // Force deploy the contracts on specified addresses.
        IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses{value: msg.value}(forceDeployments);

        // It is expected that either through the force deployments above
        // or upon initialization, both the L2 deployment of BridgeHub, AssetRouter, and MessageRoot are deployed.
        // However, there is still some follow-up finalization that needs to be done.

        // Retrieve the owner of the BridgeHub contract.
        address bridgehubOwner = L2_BRIDGE_HUB.owner();

        // Prepare calldata to set addresses in BridgeHub.
        bytes memory data = abi.encodeCall(
            L2_BRIDGE_HUB.setAddresses,
            (L2_ASSET_ROUTER, _ctmDeployer, address(L2_MESSAGE_ROOT))
        );

        // Execute the call to set addresses in BridgeHub.
        (bool success, bytes memory returnData) = SystemContractHelper.mimicCall(
            address(L2_BRIDGE_HUB),
            bridgehubOwner,
            data
        );

        // Revert with the original revert reason if the call failed.
        if (!success) {
            /// @dev Propagate the revert reason from the failed call.
            assembly {
                revert(add(returnData, 0x20), returndatasize())
            }
        }
    }

    /// @notice Retrieves and constructs the force deployments array.
    /// @dev Decodes the provided force deployments data and organizes them into an array of `ForceDeployment` to
    /// to execute.
    /// @param _fixedForceDeploymentsData Encoded data for forced deployment that
    /// is the same for all the chains.
    /// @param _additionalForceDeploymentsData Encoded data for force deployments that
    /// is specific for each ZK Chain.
    /// @return forceDeployments An array of `ForceDeployment` structs containing deployment details.
    function _getForceDeploymentsData(
        bytes memory _fixedForceDeploymentsData,
        bytes memory _additionalForceDeploymentsData
    ) internal returns (ForceDeployment[] memory forceDeployments) {
        // Decode the fixed and additional force deployments data.
        FixedForceDeploymentsData memory fixedForceDeploymentsData = abi.decode(
            _fixedForceDeploymentsData,
            (FixedForceDeploymentsData)
        );
        ZKChainSpecificForceDeploymentsData memory additionalForceDeploymentsData = abi.decode(
            _additionalForceDeploymentsData,
            (ZKChainSpecificForceDeploymentsData)
        );

        forceDeployments = new ForceDeployment[](4);

        // Configure the MessageRoot deployment.
        forceDeployments[0] = ForceDeployment({
            bytecodeHash: fixedForceDeploymentsData.messageRootBytecodeHash,
            newAddress: address(L2_MESSAGE_ROOT),
            callConstructor: true,
            value: 0,
            // solhint-disable-next-line func-named-parameters
            input: abi.encode(address(L2_BRIDGE_HUB))
        });

        // Configure the BridgeHub deployment.
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

        // Configure the AssetRouter deployment.
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

        // Ensure the WETH token is deployed and retrieve its address.
        address wrappedBaseTokenAddress = _ensureWethToken({
            _predeployedWethToken: additionalForceDeploymentsData.predeployedL2WethAddress,
            _aliasedL1Governance: fixedForceDeploymentsData.aliasedL1Governance,
            _baseTokenL1Address: additionalForceDeploymentsData.baseTokenL1Address,
            _baseTokenAssetId: additionalForceDeploymentsData.baseTokenAssetId,
            _baseTokenName: additionalForceDeploymentsData.baseTokenName,
            _baseTokenSymbol: additionalForceDeploymentsData.baseTokenSymbol
        });

        address deployedTokenBeacon;
        bool contractsDeployedAlready;
        if (additionalForceDeploymentsData.l2LegacySharedBridge != address(0)) {
            // In production, the `fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon` must always
            // be equal to 0. It is only for simplifying testing.
            if (fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon == address(0)) {
                deployedTokenBeacon = address(
                    IL2SharedBridgeLegacy(additionalForceDeploymentsData.l2LegacySharedBridge).l2TokenBeacon()
                );
            } else {
                deployedTokenBeacon = fixedForceDeploymentsData.dangerousTestOnlyForcedBeacon;
            }

            contractsDeployedAlready = true;
        }

        // Configure the Native Token Vault deployment.
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
                contractsDeployedAlready,
                wrappedBaseTokenAddress,
                additionalForceDeploymentsData.baseTokenAssetId
            )
        });
    }

    /// @notice Constructs the initialization calldata for the L2WrappedBaseToken.
    /// @param _wrappedBaseTokenName The name of the wrapped base token.
    /// @param _wrappedBaseTokenSymbol The symbol of the wrapped base token.
    /// @param _baseTokenL1Address The L1 address of the base token.
    /// @param _baseTokenAssetId The asset ID of the base token.
    /// @return initData The encoded initialization calldata.
    function getWethInitData(
        string memory _wrappedBaseTokenName,
        string memory _wrappedBaseTokenSymbol,
        address _baseTokenL1Address,
        bytes32 _baseTokenAssetId
    ) internal pure returns (bytes memory initData) {
        initData = abi.encodeCall(
            IL2WrappedBaseToken.initializeV3,
            (_wrappedBaseTokenName, _wrappedBaseTokenSymbol, L2_ASSET_ROUTER, _baseTokenL1Address, _baseTokenAssetId)
        );
    }

    /// @notice Ensures that the WETH token is deployed. If not predeployed, deploys it.
    /// @param _predeployedWethToken The potential address of the predeployed WETH token.
    /// @param _aliasedL1Governance Address of the aliased L1 governance.
    /// @param _baseTokenL1Address L1 address of the base token.
    /// @param _baseTokenAssetId Asset ID of the base token.
    /// @param _baseTokenName Name of the base token.
    /// @param _baseTokenSymbol Symbol of the base token.
    /// @return The address of the ensured WETH token.
    function _ensureWethToken(
        address _predeployedWethToken,
        address _aliasedL1Governance,
        address _baseTokenL1Address,
        bytes32 _baseTokenAssetId,
        string memory _baseTokenName,
        string memory _baseTokenSymbol
    ) private returns (address) {
        if (_predeployedWethToken != address(0)) {
            return _predeployedWethToken;
        }

        string memory wrappedBaseTokenName = string.concat("Wrapped ", _baseTokenName);
        string memory wrappedBaseTokenSymbol = string.concat("W", _baseTokenSymbol);

        bytes memory initData = getWethInitData(
            wrappedBaseTokenName,
            wrappedBaseTokenSymbol,
            _baseTokenL1Address,
            _baseTokenAssetId
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy{salt: bytes32(0)}(
            WRAPPED_BASE_TOKEN_IMPL_ADDRESS,
            _aliasedL1Governance,
            initData
        );

        return address(proxy);
    }
}
