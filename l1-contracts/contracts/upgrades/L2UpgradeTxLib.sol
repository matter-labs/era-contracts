// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";

import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "../bridge/ntv/INativeTokenVaultBase.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {IL2V31Upgrade} from "./IL2V31Upgrade.sol";
import {UnexpectedUpgradeSelector} from "../common/L1ContractErrors.sol";
import {UnexpectedZKsyncOSFlag} from "./ZkSyncUpgradeErrors.sol";
import {ZKChainSpecificForceDeploymentsData} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {TokenBridgingData, TokenMetadata} from "../common/Messaging.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {Bytes} from "../vendor/Bytes.sol";

/// @author Matter Labs
/// @title L2UpgradeTxLib
/// @notice Pure library for constructing the per-chain L2 upgrade tx data.
/// @dev Intentionally a library (not a contract) so the compiler enforces that no
/// ZKChain diamond storage (`s`) is accessed. This is critical because
/// `getL2UpgradeTxData` is called both via delegatecall from the diamond and
/// directly by the server — in the latter case `s` would be empty.
library L2UpgradeTxLib {
    using Bytes for bytes;

    /// @notice Replace the placeholder inner calldata with real per-chain data.
    /// @dev The inner calldata is IL2V31Upgrade.upgrade() — we decode the placeholder to
    /// extract ecosystem-wide fields, then re-encode with per-chain additionalForceDeploymentsData.
    /// @param _bridgehub The address of the bridgehub.
    /// @param _chainId The chain ID to build the upgrade data for.
    /// @param _existingUpgradeCalldata The placeholder L2V31Upgrade.upgrade() calldata.
    function buildL2V31UpgradeCalldata(
        address _bridgehub,
        uint256 _chainId,
        bytes memory _existingUpgradeCalldata
    ) internal view returns (bytes memory) {
        // Decode the placeholder to extract isZKsyncOS, ctmDeployer, and fixedForceDeploymentsData
        // (these are ecosystem-wide and don't change per chain).
        (bool isZKsyncOS, address ctmDeployer, bytes memory fixedForceDeploymentsData, ) = abi.decode(
            // ignore placeholder additionalForceDeploymentsData
            _existingUpgradeCalldata.slice(4),
            (bool, address, bytes, bytes)
        );

        // Read the zksyncOS flag from the diamond proxy (the authoritative source).
        address diamondProxy = IBridgehubBase(_bridgehub).getZKChain(_chainId);
        bool chainZksyncOS = IGetters(diamondProxy).getZKsyncOS();
        if (isZKsyncOS != chainZksyncOS) {
            revert UnexpectedZKsyncOSFlag(chainZksyncOS, isZKsyncOS);
        }

        // Construct per-chain ZKChainSpecificForceDeploymentsData from L1 state.
        bytes memory additionalForceDeploymentsData = buildChainSpecificForceDeploymentsData(_bridgehub, _chainId);

        return
            abi.encodeCall(
                IL2V31Upgrade.upgrade,
                (isZKsyncOS, ctmDeployer, fixedForceDeploymentsData, additionalForceDeploymentsData)
            );
    }

    /// @notice Build per-chain ZKChainSpecificForceDeploymentsData from L1 state.
    function buildChainSpecificForceDeploymentsData(
        address _bridgehub,
        uint256 _chainId
    ) internal view returns (bytes memory) {
        IBridgehubBase bridgehub = IBridgehubBase(_bridgehub);
        address assetRouter = address(bridgehub.assetRouter());
        address nativeTokenVaultAddr = address(IL1AssetRouter(assetRouter).nativeTokenVault());
        bytes32 baseTokenAssetId = bridgehub.baseTokenAssetId(_chainId);
        INativeTokenVaultBase nativeTokenVault = INativeTokenVaultBase(nativeTokenVaultAddr);
        address originToken = nativeTokenVault.originToken(baseTokenAssetId);

        string memory baseTokenName;
        string memory baseTokenSymbol;
        uint256 baseTokenDecimals;

        if (originToken == ETH_TOKEN_ADDRESS) {
            baseTokenName = "Ether";
            baseTokenSymbol = "ETH";
            baseTokenDecimals = 18;
        } else {
            // Use `tokenAddress` (the local bridged representation on this settlement layer)
            // instead of `originToken` (which is the address on the origin chain and may have no
            // code here if the token was bridged from another chain).
            address localToken = nativeTokenVault.tokenAddress(baseTokenAssetId);
            baseTokenName = IERC20Metadata(localToken).name();
            baseTokenSymbol = IERC20Metadata(localToken).symbol();
            baseTokenDecimals = IERC20Metadata(localToken).decimals();
        }

        return
            abi.encode(
                ZKChainSpecificForceDeploymentsData({
                    l2LegacySharedBridge: address(0),
                    predeployedL2WethAddress: address(0),
                    baseTokenL1Address: originToken,
                    baseTokenMetadata: TokenMetadata({
                        name: baseTokenName,
                        symbol: baseTokenSymbol,
                        decimals: baseTokenDecimals
                    }),
                    baseTokenBridgingData: TokenBridgingData({
                        assetId: baseTokenAssetId,
                        originChainId: nativeTokenVault.originChainId(baseTokenAssetId),
                        originToken: originToken
                    })
                })
            );
    }

    /// @notice Validate that the inner calldata targets L2V31Upgrade.
    function validateWrappedUpgrade(bytes memory _existingUpgradeCalldata) internal pure {
        if (bytes4(_existingUpgradeCalldata) != IL2V31Upgrade.upgrade.selector) {
            revert UnexpectedUpgradeSelector();
        }
    }
}
