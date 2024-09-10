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

import {DEPLOYER_SYSTEM_CONTRACT, L2_ASSET_ROUTER_ADDR} from "../../common/L2ContractAddresses.sol";
import {L2ContractHelper, IContractDeployer} from "../../common/libraries/L2ContractHelper.sol";

import {SystemContractsCaller} from "../../common/libraries/SystemContractsCaller.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";

import {EmptyAddress, EmptyBytes32, AddressMismatch, DeployFailed, AssetIdNotSupported} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
contract L2NativeTokenVault is IL2NativeTokenVault, NativeTokenVault {
    using SafeERC20 for IERC20;

    IL2SharedBridgeLegacy public immutable L2_LEGACY_SHARED_BRIDGE;

    /// @dev Bytecode hash of the proxy for tokens deployed by the bridge.
    bytes32 internal l2TokenProxyBytecodeHash;

    /// @notice Initializes the bridge contract for later use.
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

        l2TokenProxyBytecodeHash = _l2TokenProxyBytecodeHash;
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

    /// @notice Sets the legacy token asset ID for the given L2 token address.
    function setLegacyTokenAssetId(address _l2TokenAddress) public {
        address l1TokenAddress = L2_LEGACY_SHARED_BRIDGE.l1TokenAddress(_l2TokenAddress);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1TokenAddress);
        tokenAddress[assetId] = _l2TokenAddress;
        originChainId[assetId] = L1_CHAIN_ID;
    }

    /// @notice Ensures that the token is deployed.
    /// @param _originChainId The chain ID of the origin chain.
    /// @param _assetId The asset ID.
    /// @param _originToken The origin token address.
    /// @param _erc20Data The ERC20 data.
    /// @return expectedToken The token address.
    function _ensureTokenDeployed(
        uint256 _originChainId,
        bytes32 _assetId,
        address _originToken,
        bytes memory _erc20Data
    ) internal override returns (address expectedToken) {
        expectedToken = _assetIdCheck(_originChainId, _assetId, _originToken);
        address l1LegacyToken;
        if (address(L2_LEGACY_SHARED_BRIDGE) != address(0)) {
            l1LegacyToken = L2_LEGACY_SHARED_BRIDGE.l1TokenAddress(expectedToken);
        }

        if (l1LegacyToken != address(0)) {
            /// token is a legacy token, no need to deploy
            if (l1LegacyToken != _originToken) {
                revert AddressMismatch(_originToken, l1LegacyToken);
            }
            tokenAddress[_assetId] = expectedToken;
        } else {
            super._ensureTokenDeployedInner({
                _originChainId: _originChainId,
                _assetId: _assetId,
                _originToken: _originToken,
                _erc20Data: _erc20Data,
                _expectedToken: expectedToken
            });
        }
    }

    /// @notice Deploys the beacon proxy for the L2 token, while using ContractDeployer system contract.
    /// @dev This function uses raw call to ContractDeployer to make sure that exactly `l2TokenProxyBytecodeHash` is used
    /// for the code of the proxy.
    /// @param _salt The salt used for beacon proxy deployment of L2 bridged token.
    /// @return proxy The beacon proxy, i.e. L2 bridged token.
    function _deployBeaconProxy(bytes32 _salt) internal override returns (BeaconProxy proxy) {
        if (address(L2_LEGACY_SHARED_BRIDGE) == address(0)) {
            // Deploy the beacon proxy for the L2 token

            (bool success, bytes memory returndata) = SystemContractsCaller.systemCallWithReturndata(
                uint32(gasleft()),
                DEPLOYER_SYSTEM_CONTRACT,
                0,
                abi.encodeCall(
                    IContractDeployer.create2,
                    (_salt, l2TokenProxyBytecodeHash, abi.encode(address(bridgedTokenBeacon), ""))
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
    /// @param _l1Token The address of token on L1.
    /// @return Address of an L2 token counterpart.
    function calculateCreate2TokenAddress(
        uint256 _originChainId,
        address _l1Token
    ) public view override(INativeTokenVault, NativeTokenVault) returns (address) {
        bytes32 constructorInputHash = keccak256(abi.encode(address(bridgedTokenBeacon), ""));
        bytes32 salt = _getCreate2Salt(_originChainId, _l1Token);
        if (address(L2_LEGACY_SHARED_BRIDGE) != address(0)) {
            return L2_LEGACY_SHARED_BRIDGE.l2TokenAddress(_l1Token);
        } else {
            return
                L2ContractHelper.computeCreate2Address(
                    address(this),
                    salt,
                    l2TokenProxyBytecodeHash,
                    constructorInputHash
                );
        }
    }

    /// @notice Calculates the salt for the Create2 deployment of the L2 token.
    function _getCreate2Salt(uint256 _originChainId, address _l1Token) internal view override returns (bytes32 salt) {
        salt = _originChainId == L1_CHAIN_ID
            ? bytes32(uint256(uint160(_l1Token)))
            : keccak256(abi.encode(_originChainId, _l1Token));
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
