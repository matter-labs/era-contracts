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
contract L2NativeTokenVaultZKOS is L2NativeTokenVault {
    using SafeERC20 for IERC20;

    /// @notice Initializes the bridge contract for later use.
    /// @dev this contract is deployed in the L2GenesisUpgrade, and is meant as direct deployment without a proxy.
    /// @param _l1ChainId The L1 chain id differs between mainnet and testnets.
    /// @param _aliasedOwner The address of the governor contract.
    /// @param _legacySharedBridge The address of the L2 legacy shared bridge.
    /// @param _bridgedTokenBeacon The address of the L2 token beacon for legacy chains.
    /// @param _contractsDeployedAlready Ensures beacon proxy for standard ERC20 has not been deployed.
    /// @param _wethToken Address of WETH on deployed chain
    function initL2(
        uint256 _l1ChainId,
        address _aliasedOwner,
        address _legacySharedBridge,
        address _bridgedTokenBeacon,
        bool _contractsDeployedAlready,
        address _wethToken,
        bytes32 _baseTokenAssetId
    ) public {
        super.initL2(_l1ChainId, _aliasedOwner, bytes32(0), _legacySharedBridge, _bridgedTokenBeacon, _contractsDeployedAlready, _wethToken, _baseTokenAssetId);
    }

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
        proxy = new BeaconProxy{salt: _salt}(address(bridgedTokenBeacon), "");
    }

    /// @notice Calculates L2 wrapped token address given the currently stored beacon proxy bytecode hash and beacon address.
    /// @param _tokenOriginChainId The chain id of the origin token.
    /// @param _nonNativeToken The address of token on its origin chain.
    /// @return Address of an L2 token counterpart.
    function calculateCreate2TokenAddress(
        uint256 _tokenOriginChainId,
        address _nonNativeToken
    ) public view virtual override returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(BeaconProxy).creationCode,
            abi.encode(address(bridgedTokenBeacon), "")
        );
        return Create2.computeAddress(_getCreate2Salt(_tokenOriginChainId, _nonNativeToken), keccak256(bytecode));
    }

    function initialize(
        address _aliasedOwner,
        address _bridgedTokenBeacon,
        bool _contractsDeployedAlready
    ) external initializer {
        _initializeInner(_aliasedOwner, _bridgedTokenBeacon, bytes32(0), _contractsDeployedAlready);
    }
}
