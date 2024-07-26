// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IBridgedStandardToken} from "./interfaces/IBridgedStandardToken.sol";
import {INativeTokenVault} from "l1-contracts-imported/contracts/bridge/interfaces/INativeTokenVault.sol";
import {IL2NativeTokenVault} from "./interfaces/IL2NativeTokenVault.sol";
import {IAssetHandler} from "./interfaces/IAssetHandler.sol";

import {BridgedStandardERC20} from "./BridgedStandardERC20.sol";
import {IAssetRouterBase} from "l1-contracts-imported/contracts/bridge/interfaces/IAssetRouterBase.sol";
import {NativeTokenVault} from "l1-contracts-imported/contracts/bridge/NativeTokenVault.sol";
import {L2ContractHelper, DEPLOYER_SYSTEM_CONTRACT, L2_NATIVE_TOKEN_VAULT, L2_ASSET_ROUTER, IContractDeployer} from "../L2ContractHelper.sol";
import {SystemContractsCaller} from "../SystemContractsCaller.sol";

import {EmptyAddress, EmptyBytes32, AddressMismatch, AssetIdMismatch, DeployFailed, AmountMustBeGreaterThanZero, InvalidCaller} from "../L2ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
contract L2NativeTokenVault is IL2NativeTokenVault, NativeTokenVault {
    /// @dev Contract that stores the implementation address for token.
    /// @dev For more details see https://docs.openzeppelin.com/contracts/3.x/api/proxy#UpgradeableBeacon.
    UpgradeableBeacon public l2TokenBeacon;

    /// @dev Bytecode hash of the proxy for tokens deployed by the bridge.
    bytes32 internal l2TokenProxyBytecodeHash;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Disable the initialization to prevent Parity hack.
    /// @param _l2TokenProxyBytecodeHash The bytecode hash of the proxy for tokens deployed by the bridge.
    /// @param _aliasedOwner The address of the governor contract.
    /// @param _contractsDeployedAlready Ensures beacon proxy for standard ERC20 has not been deployed
    /// @param _wethToken Address of WETH on deployed chain
    /// @param _baseTokenAddress Address of Base token
    constructor(
        bytes32 _l2TokenProxyBytecodeHash,
        address _aliasedOwner,
        bool _contractsDeployedAlready,
        address _wethToken,
        address _baseTokenAddress
    ) NativeTokenVault(_wethToken, address(L2_ASSET_ROUTER), _baseTokenAddress) {
        _disableInitializers();
        if (_l2TokenProxyBytecodeHash == bytes32(0)) {
            revert EmptyBytes32();
        }
        if (_aliasedOwner == address(0)) {
            revert EmptyAddress();
        }

        if (!_contractsDeployedAlready) {
            l2TokenProxyBytecodeHash = _l2TokenProxyBytecodeHash;
        }

        _transferOwnership(_aliasedOwner);
    }

    /// @notice Deploys the beacon proxy for the L2 token, while using ContractDeployer system contract.
    /// @dev This function uses raw call to ContractDeployer to make sure that exactly `l2TokenProxyBytecodeHash` is used
    /// for the code of the proxy.
    /// @param _salt The salt used for beacon proxy deployment of L2 bridged token.
    /// @return proxy The beacon proxy, i.e. L2 bridged token.
    function _deployBeaconProxy(bytes32 _salt) internal override returns (BeaconProxy proxy) {
        (bool success, bytes memory returndata) = SystemContractsCaller.systemCallWithReturndata(
            uint32(gasleft()),
            DEPLOYER_SYSTEM_CONTRACT,
            0,
            abi.encodeCall(
                IContractDeployer.create2,
                (_salt, l2TokenProxyBytecodeHash, abi.encode(address(l2TokenBeacon), ""))
            )
        );

        // The deployment should be successful and return the address of the proxy
        if (!success) {
            revert DeployFailed();
        }
        proxy = BeaconProxy(abi.decode(returndata, (address)));
    }

    /// @notice Calculates the bridged token address corresponding to native token counterpart.
    /// @param _nativeToken The address of native token.
    /// @return The address of bridged token.
    function bridgedTokenAddress(
        address _nativeToken
    ) public view override(NativeTokenVault, INativeTokenVault) returns (address) {
        return l2TokenAddress(_nativeToken);
    }

    /// @notice Calculates L2 wrapped token address corresponding to L1 token counterpart.
    /// @param _l1Token The address of token on L1.
    /// @return The address of token on L2.
    function l2TokenAddress(address _l1Token) public view returns (address) {
        bytes32 constructorInputHash = keccak256(abi.encode(address(l2TokenBeacon), ""));
        bytes32 salt = _getCreate2Salt(_l1Token);
        return
            L2ContractHelper.computeCreate2Address(address(this), salt, l2TokenProxyBytecodeHash, constructorInputHash);
    }
}
