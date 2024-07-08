// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IL1NativeTokenVault} from "./interfaces/IL1NativeTokenVault.sol";
import {INativeTokenVault} from "./interfaces/INativeTokenVault.sol";
import {IL1AssetHandler} from "./interfaces/IL1AssetHandler.sol";
import {IAssetHandler} from "./interfaces/IAssetHandler.sol";
import {IAssetRouterBase} from "./interfaces/IAssetRouterBase.sol";
import {IL1Nullifier} from "./interfaces/IL1Nullifier.sol";
import {IAssetRouterBase} from "./interfaces/IAssetRouterBase.sol";

import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDRESS} from "../common/L2ContractAddresses.sol";

import {NativeTokenVault} from "./NativeTokenVault.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Vault holding L1 native ETH and ERC20 tokens bridged into the ZK chains.
/// @dev Designed for use with a proxy for upgradability.
contract L1NativeTokenVault is IL1NativeTokenVault, IL1AssetHandler, NativeTokenVault {
    using SafeERC20 for IERC20;

    /// @dev L1 nullifier contract that handles legacy functions & finalize withdrawal, confirm l2 tx mappings
    IL1Nullifier public immutable override NULLIFIER;

    /// @dev Era's chainID
    uint256 public immutable ERA_CHAIN_ID;

    bytes public wrappedTokenProxyBytecode;

    /// @notice Checks that the message sender is the native token vault itself.
    modifier onlySelf() {
        require(msg.sender == address(this), "NTV only");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(
        address _wethAddress,
        IAssetRouterBase _l1AssetRouter,
        uint256 _eraChainId,
        IL1Nullifier _l1Nullifier,
        bytes memory _wrappedTokenProxyBytecode
    ) NativeTokenVault(_wethAddress, _l1AssetRouter) {
        ERA_CHAIN_ID = _eraChainId;
        NULLIFIER = _l1Nullifier;
        wrappedTokenProxyBytecode = _wrappedTokenProxyBytecode;
    }

    /// @notice Transfers tokens from shared bridge as part of the migration process.
    /// @dev Both ETH and ERC20 tokens can be transferred. Exhausts balance of shared bridge after the first call.
    /// @dev Calling second time for the same token will revert.
    /// @param _token The address of token to be transferred (address(1) for ether and contract address for ERC20).
    function transferFundsFromSharedBridge(address _token) external {
        if (_token == ETH_TOKEN_ADDRESS) {
            uint256 balanceBefore = address(this).balance;
            NULLIFIER.transferTokenToNTV(_token);
            uint256 balanceAfter = address(this).balance;
            require(balanceAfter > balanceBefore, "NTV: 0 eth transferred");
        } else {
            uint256 balanceBefore = IERC20(_token).balanceOf(address(this));
            uint256 sharedBridgeChainBalance = IERC20(_token).balanceOf(address(ASSET_ROUTER));
            require(sharedBridgeChainBalance > 0, "NTV: 0 amount to transfer");
            NULLIFIER.transferTokenToNTV(_token);
            uint256 balanceAfter = IERC20(_token).balanceOf(address(this));
            require(balanceAfter - balanceBefore >= sharedBridgeChainBalance, "NTV: wrong amount transferred");
        }
    }

    /// @notice Updates chain token balance within NTV to account for tokens transferred from the shared bridge (part of the migration process).
    /// @dev Clears chain balance on the shared bridge after the first call. Subsequent calls will not affect the state.
    /// @param _token The address of token to be transferred (address(1) for ether and contract address for ERC20).
    /// @param _targetChainId The chain ID of the corresponding ZK chain.
    function transferBalancesFromSharedBridge(address _token, uint256 _targetChainId) external {
        uint256 sharedBridgeChainBalance = NULLIFIER.chainBalance(_targetChainId, _token);
        chainBalance[_targetChainId][_token] = chainBalance[_targetChainId][_token] + sharedBridgeChainBalance;
        NULLIFIER.clearChainBalance(_targetChainId, _token);
    }

    ///  @inheritdoc IL1AssetHandler
    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _data
    ) external payable override onlyBridge whenNotPaused {
        (uint256 _amount, address _depositSender) = abi.decode(_data, (uint256, address));
        address l1Token = tokenAddress[_assetId];
        require(_amount > 0, "y1");

        // check that the chain has sufficient balance
        require(chainBalance[_chainId][l1Token] >= _amount, "NTV n funds");
        chainBalance[_chainId][l1Token] -= _amount;

        if (l1Token == ETH_TOKEN_ADDRESS) {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), _depositSender, _amount, 0, 0, 0, 0)
            }
            require(callSuccess, "NTV: claimFailedDeposit failed, no funds or cannot transfer to receiver");
        } else {
            IERC20(l1Token).safeTransfer(_depositSender, _amount);
            // Note we don't allow weth deposits anymore, but there might be legacy weth deposits.
            // until we add Weth bridging capabilities, we don't wrap/unwrap weth to ether.
        }
    }

    // get the computed address before the contract DeployWithCreate2 deployed using Bytecode of contract DeployWithCreate2 and salt specified by the sender
    function wrappedTokenAddress(
        address _salt
    ) public view override(INativeTokenVault, NativeTokenVault) returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), uint256(uint160(_salt)), keccak256(wrappedTokenProxyBytecode))
        );
        return address(uint160(uint256(hash)));
    }

    function _deployBeaconProxy(bytes32 _salt) internal override returns (BeaconProxy proxy) {
        // Use CREATE2 to deploy the BeaconProxy
        address proxyAddress = Create2.deploy(0, _salt, wrappedTokenProxyBytecode);
        return BeaconProxy(payable(proxyAddress));
    }
}
