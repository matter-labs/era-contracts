// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {IBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";

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

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
contract L2NativeTokenVault is IL2NativeTokenVault, NativeTokenVault {
    using SafeERC20 for IERC20;

    IL2SharedBridgeLegacy public immutable L2_LEGACY_SHARED_BRIDGE;

    /// @dev Bytecode hash of the proxy for tokens deployed by the bridge.
    bytes32 internal immutable L2_TOKEN_PROXY_BYTECODE_HASH;

    /// @notice Initializes the bridge contract for later use.
    /// @dev this contract is deployed in the L2GenesisUpgrade, and is meant as direct deployment without a proxy.
    /// @param _l1ChainId The L1 chain id differs between mainnet and testnets.
    /// @param _l2TokenProxyBytecodeHash The bytecode hash of the proxy for tokens deployed by the bridge.
    /// @param _aliasedOwner The address of the governor contract.
    /// @param _legacySharedBridge The address of the L2 legacy shared bridge.
    /// @param _bridgedTokenBeacon The address of the L2 token beacon for legacy chains.
    /// @param _contractsDeployedAlready Ensures beacon proxy for standard ERC20 has not been deployed.
    /// @param _wethToken Address of WETH on deployed chain
    constructor(
        uint256 _l1ChainId,
        address _aliasedOwner,
        bytes32 _l2TokenProxyBytecodeHash,
        address _legacySharedBridge,
        address _bridgedTokenBeacon,
        bool _contractsDeployedAlready,
        address _wethToken,
        bytes32 _baseTokenAssetId
    ) NativeTokenVault(_wethToken, L2_ASSET_ROUTER_ADDR, _baseTokenAssetId, _l1ChainId) {
        L2_LEGACY_SHARED_BRIDGE = IL2SharedBridgeLegacy(_legacySharedBridge);

        if (_l2TokenProxyBytecodeHash == bytes32(0)) {
            revert EmptyBytes32();
        }
        if (_aliasedOwner == address(0)) {
            revert EmptyAddress();
        }

        L2_TOKEN_PROXY_BYTECODE_HASH = _l2TokenProxyBytecodeHash;
        _transferOwnership(_aliasedOwner);

        if (_contractsDeployedAlready) {
            if (_bridgedTokenBeacon == address(0)) {
                revert EmptyAddress();
            }
            bridgedTokenBeacon = IBeacon(_bridgedTokenBeacon);
        } else {
            address l2StandardToken = address(new BridgedStandardERC20{salt: bytes32(0)}());

            UpgradeableBeacon tokenBeacon = new UpgradeableBeacon{salt: bytes32(0)}(l2StandardToken);

            tokenBeacon.transferOwnership(owner());
            bridgedTokenBeacon = IBeacon(address(tokenBeacon));
            emit L2TokenBeaconUpdated(address(bridgedTokenBeacon), _l2TokenProxyBytecodeHash);
        }
    }

    function _registerTokenIfBridgedLegacy(address _tokenAddress) internal override returns (bytes32) {
        // In zkEVM immutables are stored in a storage of a system contract,
        // so it makes sense to cache them for efficiency.
        IL2SharedBridgeLegacy legacyBridge = L2_LEGACY_SHARED_BRIDGE;
        if (address(legacyBridge) == address(0)) {
            // No legacy bridge, the token must be native
            return bytes32(0);
        }

        address l1TokenAddress = legacyBridge.l1TokenAddress(_tokenAddress);
        if (l1TokenAddress == address(0)) {
            // The token is not legacy
            return bytes32(0);
        }

        return _registerLegacyTokenAssetId(_tokenAddress, l1TokenAddress);
    }

    /// @notice Sets the legacy token asset ID for the given L2 token address.
    function setLegacyTokenAssetId(address _l2TokenAddress) public override {
        // some legacy tokens were bridged without setting the originChainId on testnets
        bytes32 assetId = assetId[_l2TokenAddress];
        if (assetId != bytes32(0) && originChainId[assetId] != 0) {
            revert AssetIdAlreadyRegistered();
        }
        if (address(L2_LEGACY_SHARED_BRIDGE) == address(0)) {
            revert NoLegacySharedBridge();
        }
        address l1TokenAddress = L2_LEGACY_SHARED_BRIDGE.l1TokenAddress(_l2TokenAddress);
        if (l1TokenAddress == address(0)) {
            revert TokenNotLegacy();
        }

        _registerLegacyTokenAssetId(_l2TokenAddress, l1TokenAddress);
    }

    function _registerLegacyTokenAssetId(
        address _l2TokenAddress,
        address _l1TokenAddress
    ) internal returns (bytes32 newAssetId) {
        newAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, _l1TokenAddress);
        IL2AssetRouter(L2_ASSET_ROUTER_ADDR).setLegacyTokenAssetHandler(newAssetId);
        tokenAddress[newAssetId] = _l2TokenAddress;
        assetId[_l2TokenAddress] = newAssetId;
        originChainId[newAssetId] = L1_CHAIN_ID;
    }

    /// @notice Ensures that the token is deployed.
    /// @param _assetId The asset ID.
    /// @param _originToken The origin token address.
    /// @param _erc20Data The ERC20 data.
    /// @return expectedToken The token address.
    function _ensureAndSaveTokenDeployed(
        bytes32 _assetId,
        address _originToken,
        bytes memory _erc20Data
    ) internal override returns (address expectedToken) {
        uint256 tokenOriginChainId;
        (expectedToken, tokenOriginChainId) = _calculateExpectedTokenAddress(_originToken, _erc20Data);
        address l1LegacyToken;
        if (address(L2_LEGACY_SHARED_BRIDGE) != address(0)) {
            l1LegacyToken = L2_LEGACY_SHARED_BRIDGE.l1TokenAddress(expectedToken);
        }

        if (l1LegacyToken != address(0)) {
            _ensureAndSaveTokenDeployedInnerLegacyToken({
                _assetId: _assetId,
                _originToken: _originToken,
                _expectedToken: expectedToken,
                _l1LegacyToken: l1LegacyToken
            });
        } else {
            super._ensureAndSaveTokenDeployedInner({
                _tokenOriginChainId: tokenOriginChainId,
                _assetId: _assetId,
                _originToken: _originToken,
                _erc20Data: _erc20Data,
                _expectedToken: expectedToken
            });
        }
    }

    /// @notice Ensures that the token is deployed inner for legacy tokens.
    function _ensureAndSaveTokenDeployedInnerLegacyToken(
        bytes32 _assetId,
        address _originToken,
        address _expectedToken,
        address _l1LegacyToken
    ) internal {
        _assetIdCheck(L1_CHAIN_ID, _assetId, _originToken);

        /// token is a legacy token, no need to deploy
        if (_l1LegacyToken != _originToken) {
            revert AddressMismatch(_originToken, _l1LegacyToken);
        }

        tokenAddress[_assetId] = _expectedToken;
        assetId[_expectedToken] = _assetId;
        originChainId[_assetId] = L1_CHAIN_ID;
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
        if (address(L2_LEGACY_SHARED_BRIDGE) == address(0) || _tokenOriginChainId != L1_CHAIN_ID) {
            // Deploy the beacon proxy for the L2 token

            (bool success, bytes memory returndata) = SystemContractsCaller.systemCallWithReturndata(
                uint32(gasleft()),
                L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
                0,
                abi.encodeCall(
                    IContractDeployer.create2,
                    (_salt, L2_TOKEN_PROXY_BYTECODE_HASH, abi.encode(address(bridgedTokenBeacon), ""))
                )
            );

            // The deployment should be successful and return the address of the proxy
            if (!success) {
                revert DeployFailed();
            }
            proxy = BeaconProxy(abi.decode(returndata, (address)));
        } else {
            // Deploy the beacon proxy for the L2 token
            address l2TokenAddr = L2_LEGACY_SHARED_BRIDGE.deployBeaconProxy(_salt);
            proxy = BeaconProxy(payable(l2TokenAddr));
        }
    }

    function _withdrawFunds(bytes32 _assetId, address _to, address _token, uint256 _amount) internal override {
        if (_assetId == BASE_TOKEN_ASSET_ID) {
            revert AssetIdNotSupported(BASE_TOKEN_ASSET_ID);
        } else {
            // Withdraw funds
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL & HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates L2 wrapped token address given the currently stored beacon proxy bytecode hash and beacon address.
    /// @param _tokenOriginChainId The chain id of the origin token.
    /// @param _nonNativeToken The address of token on its origin chain.
    /// @return Address of an L2 token counterpart.
    function calculateCreate2TokenAddress(
        uint256 _tokenOriginChainId,
        address _nonNativeToken
    ) public view virtual override(INativeTokenVault, NativeTokenVault) returns (address) {
        if (address(L2_LEGACY_SHARED_BRIDGE) != address(0) && _tokenOriginChainId == L1_CHAIN_ID) {
            return L2_LEGACY_SHARED_BRIDGE.l2TokenAddress(_nonNativeToken);
        } else {
            bytes32 constructorInputHash = keccak256(abi.encode(address(bridgedTokenBeacon), ""));
            bytes32 salt = _getCreate2Salt(_tokenOriginChainId, _nonNativeToken);
            return
                L2ContractHelper.computeCreate2Address(
                    address(this),
                    salt,
                    L2_TOKEN_PROXY_BYTECODE_HASH,
                    constructorInputHash
                );
        }
    }

    /// @notice Calculates the salt for the Create2 deployment of the L2 token.
    function _getCreate2Salt(
        uint256 _tokenOriginChainId,
        address _l1Token
    ) internal view override returns (bytes32 salt) {
        salt = _tokenOriginChainId == L1_CHAIN_ID
            ? bytes32(uint256(uint160(_l1Token)))
            : keccak256(abi.encode(_tokenOriginChainId, _l1Token));
    }

    function _handleChainBalanceIncrease(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isNative
    ) internal override {
        // on L2s we don't track the balance
    }

    function _handleChainBalanceDecrease(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isNative
    ) internal override {
        // on L2s we don't track the balance
    }

    function _registerToken(address _nativeToken) internal override returns (bytes32) {
        if (
            address(L2_LEGACY_SHARED_BRIDGE) != address(0) &&
            L2_LEGACY_SHARED_BRIDGE.l1TokenAddress(_nativeToken) != address(0)
        ) {
            // Legacy tokens should be registered via `setLegacyTokenAssetId`.
            revert TokenIsLegacy();
        }
        return super._registerToken(_nativeToken);
    }

    /*//////////////////////////////////////////////////////////////
                            LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates L2 wrapped token address corresponding to L1 token counterpart.
    /// @param _l1Token The address of token on L1.
    /// @return expectedToken The address of token on L2.
    function l2TokenAddress(address _l1Token) public view returns (address expectedToken) {
        bytes32 expectedAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, _l1Token);
        expectedToken = tokenAddress[expectedAssetId];
    }
}
