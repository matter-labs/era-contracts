// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";
import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {
    IL2GenesisUpgrade,
    ZKChainSpecificForceDeploymentsData
} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {L2CanonicalTransaction, TokenBridgingData, TokenMetadata} from "contracts/common/Messaging.sol";
import {
    ETH_TOKEN_ADDRESS,
    PRIORITY_TX_MAX_GAS_LIMIT,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE
} from "contracts/common/Config.sol";
import {
    L2_COMPLEX_UPGRADER_ADDR,
    L2_FORCE_DEPLOYER_ADDR,
    L2_GENESIS_UPGRADE_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

/// @notice The genesis transaction EXACTLY as it was composed before the envelope and the per-chain
///         builder were shared — the struct literal of `L1GenesisUpgrade` and the probing body of
///         `L1FixedForceDeploymentsHelper`, transcribed here and nowhere else.
/// @dev This is a deliberate duplicate of retired production code, kept only so the refactoring can
///      be held against the behaviour it replaced (see `L1GenesisUpgrade.t.sol`). The one change is
///      mechanical: the chain identity arrives as arguments instead of through `ZKChainStorage`,
///      because the old body was reachable only under delegatecall. Nothing about the values
///      computed is adjusted, including the quirk that a conforming 32-byte `decimals()` answer is
///      filtered out and the ERC20 default stands.
library LegacyGenesisComposition {
    /// @param _bridgehub The chain's Bridgehub, as the old code read it from `s.bridgehub`.
    /// @param _chainId The chain, as the old code read it from `s.chainId`.
    /// @param _baseTokenAssetId The base token asset id, as the old code read it from `s.baseTokenAssetId`.
    /// @param _protocolVersion The chain's version, as the old code read it from `s.protocolVersion`.
    /// @param _fixedForceDeploymentsData The release's pinned blob.
    function genesisUpgradeTx(
        address _bridgehub,
        uint256 _chainId,
        bytes32 _baseTokenAssetId,
        uint256 _protocolVersion,
        bytes memory _fixedForceDeploymentsData
    ) internal view returns (L2CanonicalTransaction memory) {
        IBridgehubBase bridgehub = IBridgehubBase(_bridgehub);
        bytes memory complexUpgraderCalldata = abi.encodeCall(
            IComplexUpgrader.upgrade,
            (
                L2_GENESIS_UPGRADE_ADDR,
                abi.encodeCall(
                    IL2GenesisUpgrade.genesisUpgrade,
                    (
                        _chainId,
                        address(bridgehub.l1CtmDeployer()),
                        _fixedForceDeploymentsData,
                        _perChainData(_bridgehub, _baseTokenAssetId, bridgehub.baseToken(_chainId))
                    )
                )
            )
        );

        // slither-disable-next-line unused-return
        (, uint32 minorVersion, ) = SemVer.unpackSemVer(SafeCast.toUint96(_protocolVersion));
        return
            L2CanonicalTransaction({
                txType: ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE,
                from: uint256(uint160(L2_FORCE_DEPLOYER_ADDR)),
                to: uint256(uint160(L2_COMPLEX_UPGRADER_ADDR)),
                gasLimit: PRIORITY_TX_MAX_GAS_LIMIT,
                gasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                maxFeePerGas: uint256(0),
                maxPriorityFeePerGas: uint256(0),
                paymaster: uint256(0),
                // Note, that the protocol version is used as "nonce" for system upgrade transactions
                nonce: minorVersion,
                value: 0,
                reserved: [uint256(0), 0, 0, 0],
                data: complexUpgraderCalldata,
                signature: new bytes(0),
                factoryDeps: new uint256[](0),
                paymasterInput: new bytes(0),
                reservedDynamic: new bytes(0)
            });
    }

    function _perChainData(
        address _bridgehub,
        bytes32 _baseTokenAssetId,
        address _baseTokenAddress
    ) private view returns (bytes memory) {
        address sharedBridge = address(IBridgehubBase(_bridgehub).assetRouter());

        TokenMetadata memory tokenData;
        if (_baseTokenAddress == ETH_TOKEN_ADDRESS) {
            tokenData = TokenMetadata({name: string("Ether"), symbol: string("ETH"), decimals: 18});
        } else {
            (string memory stringResult, bool success) = _safeCallTokenMetadataString(
                _baseTokenAddress,
                abi.encodeCall(IERC20Metadata.name, ())
            );
            if (success) {
                tokenData.name = stringResult;
            } else {
                tokenData.name = string("Base Token");
            }

            (stringResult, success) = _safeCallTokenMetadataString(
                _baseTokenAddress,
                abi.encodeCall(IERC20Metadata.symbol, ())
            );
            if (success) {
                tokenData.symbol = stringResult;
            } else {
                tokenData.symbol = string("BT");
            }

            uint256 uintResult;
            (uintResult, success) = _safeCallTokenMetadataUint256(
                _baseTokenAddress,
                abi.encodeCall(IERC20Metadata.decimals, ())
            );
            if (success) {
                tokenData.decimals = uintResult;
            } else {
                tokenData.decimals = 18;
            }
        }

        INativeTokenVaultBase nativeTokenVault = IL1AssetRouter(sharedBridge).nativeTokenVault();
        return
            abi.encode(
                ZKChainSpecificForceDeploymentsData({
                    l2LegacySharedBridge: address(0),
                    predeployedL2WethAddress: address(0),
                    baseTokenL1Address: _baseTokenAddress,
                    baseTokenMetadata: tokenData,
                    baseTokenBridgingData: TokenBridgingData({
                        assetId: _baseTokenAssetId,
                        originChainId: nativeTokenVault.originChainId(_baseTokenAssetId),
                        originToken: nativeTokenVault.originToken(_baseTokenAssetId)
                    })
                })
            );
    }

    function _safeCallTokenMetadataBytes(address _token, bytes memory _data) private view returns (bytes memory, bool) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool callSuccess, bytes memory returnData) = _token.staticcall(_data);
        if (!callSuccess) {
            return ("", false);
        }
        if (returnData.length == 32) {
            return ("", false);
        }
        return (returnData, true);
    }

    function _safeCallTokenMetadataString(
        address _token,
        bytes memory _data
    ) private view returns (string memory, bool) {
        (bytes memory returnData, bool success) = _safeCallTokenMetadataBytes(_token, _data);
        if (!success) {
            return ("", false);
        }
        return (abi.decode(returnData, (string)), true);
    }

    function _safeCallTokenMetadataUint256(address _token, bytes memory _data) private view returns (uint256, bool) {
        (bytes memory returnData, bool success) = _safeCallTokenMetadataBytes(_token, _data);
        if (!success) {
            return (0, false);
        }
        return (abi.decode(returnData, (uint256)), true);
    }
}
