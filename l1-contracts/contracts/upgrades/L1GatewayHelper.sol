// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL1SharedBridgeLegacy} from "../bridge/interfaces/IL1SharedBridgeLegacy.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {ZKChainSpecificForceDeploymentsData} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {ZKChainStorage} from "../state-transition/chain-deps/ZKChainStorage.sol";

import {L2WrappedBaseTokenStore} from "../bridge/L2WrappedBaseTokenStore.sol";
import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";

/// @title L1GatewayHelper
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
library L1GatewayHelper {
    /// @notice The function to retrieve the chain-specific upgrade data.
    /// @param s The pointer to the storage of the chain.
    /// @param _wrappedBaseTokenStore The address of the `L2WrappedBaseTokenStore` contract.
    /// It is expected to be zero during creation of new chains and non-zero during upgrades.
    /// @param _baseTokenAddress The L1 address of the base token of the chain. Note, that for
    /// chains whose token originates from an L2, this address will be the address of its bridged
    /// representation on L1.
    function getZKChainSpecificForceDeploymentsData(
        ZKChainStorage storage s,
        address _wrappedBaseTokenStore,
        address _baseTokenAddress
    ) internal view returns (bytes memory) {
        address sharedBridge = IBridgehub(s.bridgehub).sharedBridge();
        address legacySharedBridge = IL1SharedBridgeLegacy(sharedBridge).l2BridgeAddress(s.chainId);

        address l2WBaseToken;
        if (_wrappedBaseTokenStore != address(0)) {
            l2WBaseToken = L2WrappedBaseTokenStore(_wrappedBaseTokenStore).l2WBaseTokenAddress(s.chainId);
        }

        // It is required for a base token to implement the following methods
        string memory baseTokenName;
        string memory baseTokenSymbol;
        if (_baseTokenAddress == ETH_TOKEN_ADDRESS) {
            baseTokenName = string("Ether");
            baseTokenSymbol = string("ETH");
        } else {
            baseTokenName = IERC20Metadata(_baseTokenAddress).name();
            baseTokenSymbol = IERC20Metadata(_baseTokenAddress).symbol();
        }

        ZKChainSpecificForceDeploymentsData
            memory additionalForceDeploymentsData = ZKChainSpecificForceDeploymentsData({
                baseTokenAssetId: s.baseTokenAssetId,
                l2LegacySharedBridge: legacySharedBridge,
                predeployedL2WethAddress: l2WBaseToken,
                baseTokenL1Address: _baseTokenAddress,
                baseTokenName: baseTokenName,
                baseTokenSymbol: baseTokenSymbol
            });
        return abi.encode(additionalForceDeploymentsData);
    }
}
