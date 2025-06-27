// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {IBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {Create2} from "@openzeppelin/contracts-v4/utils/Create2.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {INativeTokenVault} from "./INativeTokenVault.sol";
import {IL2NativeTokenVault} from "./IL2NativeTokenVault.sol";
import {NativeTokenVault} from "./NativeTokenVault.sol";

import {IL2SharedBridgeLegacy} from "../interfaces/IL2SharedBridgeLegacy.sol";
import {BridgedStandardERC20} from "../BridgedStandardERC20.sol";
import {IL2AssetRouter} from "../asset-router/IL2AssetRouter.sol";

import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_ASSET_ROUTER_ADDR} from "../../common/L2ContractAddresses.sol";
import {L2ContractHelper, IContractDeployer} from "../../common/libraries/L2ContractHelper.sol";

import {SystemContractsCaller} from "../../common/libraries/SystemContractsCaller.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";

import {AssetIdAlreadyRegistered, NoLegacySharedBridge, TokenIsLegacy, TokenNotLegacy, EmptyAddress, EmptyBytes32, AddressMismatch, DeployFailed, AssetIdNotSupported} from "../../common/L1ContractErrors.sol";

import {L2NativeTokenVault} from "./L2NativeTokenVault.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
/// @dev Important: L2 contracts are not allowed to have any immutable variables. This is needed for compatibility with ZKsyncOS.
/// @dev For the ease of future use of ZKOS, this contract should not have ANY storage variables and all of those should be part of the
/// parent `L2NativeTokenVault` contract.
contract L2NativeTokenVaultZKOS is L2NativeTokenVault {
    using SafeERC20 for IERC20;

    /// @notice Deploys the beacon proxy for the L2 token, while using ContractDeployer system contract.
    /// @dev This function uses raw call to ContractDeployer to make sure that exactly `L2_TOKEN_PROXY_BYTECODE_HASH` is used
    /// for the code of the proxy.
    /// @param _salt The salt used for beacon proxy deployment of L2 bridged token.
    /// @param _tokenOriginChainId The origin chain id of the token.
    /// @return proxy The beacon proxy, i.e. L2 bridged token.
    function _deployBeaconProxy(
        bytes32 _salt,
        uint256 _tokenOriginChainId
    ) internal virtual override returns (BeaconProxy proxy) {
        // For all zkOS-first chains, `L2_LEGACY_SHARED_BRIDGE` is zero and so L2NativeTokenVault
        // is the sole deployer of all bridged tokens.

        // TODO: is it okay that the bytecode of the proxy changes with the implementation
        // of the l2 native token vault?

        // Use CREATE2 to deploy the BeaconProxy
        address proxyAddress = Create2.deploy(
            0,
            _salt,
            abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(bridgedTokenBeacon, ""))
        );
        return BeaconProxy(payable(proxyAddress));
    }

    /// @notice Calculates L2 wrapped token address given the currently stored beacon proxy bytecode hash and beacon address.
    /// @param _tokenOriginChainId The chain id of the origin token.
    /// @param _nonNativeToken The address of token on its origin chain.
    /// @return Address of an L2 token counterpart.
    function calculateCreate2TokenAddress(
        uint256 _tokenOriginChainId,
        address _nonNativeToken
    ) public view override returns (address) {
        bytes32 salt = _getCreate2Salt(_tokenOriginChainId, _nonNativeToken);
        return
            Create2.computeAddress(
                salt,
                keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(bridgedTokenBeacon, "")))
            );
    }
}
