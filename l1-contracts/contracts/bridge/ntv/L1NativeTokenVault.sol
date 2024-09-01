// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {Create2} from "@openzeppelin/contracts-v4/utils/Create2.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IL1NativeTokenVault} from "./IL1NativeTokenVault.sol";
import {NativeTokenVault} from "./NativeTokenVault.sol";

import {IL1AssetHandler} from "../interfaces/IL1AssetHandler.sol";
import {IL1Nullifier} from "../interfaces/IL1Nullifier.sol";

import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";

import {Unauthorized, ZeroAddress, NoFundsTransferred, InsufficientChainBalance} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Vault holding L1 native ETH and ERC20 tokens bridged into the ZK chains.
/// @dev Designed for use with a proxy for upgradability.
contract L1NativeTokenVault is IL1NativeTokenVault, IL1AssetHandler, NativeTokenVault {
    using SafeERC20 for IERC20;

    /// @dev L1 nullifier contract that handles legacy functions & finalize withdrawal, confirm l2 tx mappings
    IL1Nullifier public immutable override L1_NULLIFIER;

    /// @dev Era's chainID
    uint256 public immutable ERA_CHAIN_ID;

    bytes public bridgedTokenProxyBytecode;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    /// @param _l1WethAddress Address of WETH on deployed chain
    /// @param _l1AssetRouter Address of Asset Router on L1.
    /// @param _eraChainId ID of Era.
    /// @param _l1Nullifier Address of the nullifier contract, which handles transaction progress between L1 and ZK chains.
    /// @param _bridgedTokenProxyBytecode The bytecode hash of the proxy for tokens deployed by the bridge.
    /// @param _baseTokenAddress Address of Base token
    constructor(
        address _l1WethAddress,
        address _l1AssetRouter,
        uint256 _eraChainId,
        IL1Nullifier _l1Nullifier,
        bytes memory _bridgedTokenProxyBytecode,
        address _baseTokenAddress
    ) NativeTokenVault(_l1WethAddress, _l1AssetRouter, _baseTokenAddress) {
        ERA_CHAIN_ID = _eraChainId;
        L1_NULLIFIER = _l1Nullifier;
        bridgedTokenProxyBytecode = _bridgedTokenProxyBytecode;
    }

    /// @dev Accepts ether only from the contract that was the shared Bridge.
    receive() external payable {
        if ((address(L1_NULLIFIER) != msg.sender) && (address(ASSET_ROUTER) != msg.sender)) {
            revert Unauthorized(msg.sender);
        }
    }

    /// @dev Initializes a contract for later use. Expected to be used in the proxy
    /// @param _owner Address which can change pause / unpause the NTV
    /// implementation. The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge.
    function initialize(address _owner) external initializer {
        if (_owner == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(_owner);
    }

    /// @notice Transfers tokens from shared bridge as part of the migration process.
    /// @dev Both ETH and ERC20 tokens can be transferred. Exhausts balance of shared bridge after the first call.
    /// @dev Calling second time for the same token will revert.
    /// @param _token The address of token to be transferred (address(1) for ether and contract address for ERC20).
    function transferFundsFromSharedBridge(address _token) external {
        if (_token == ETH_TOKEN_ADDRESS) {
            uint256 balanceBefore = address(this).balance;
            L1_NULLIFIER.transferTokenToNTV(_token);
            uint256 balanceAfter = address(this).balance;
            if (balanceAfter <= balanceBefore) {
                revert NoFundsTransferred();
            }
        } else {
            uint256 balanceBefore = IERC20(_token).balanceOf(address(this));
            uint256 sharedBridgeChainBalance = IERC20(_token).balanceOf(address(ASSET_ROUTER));
            require(sharedBridgeChainBalance > 0, "NTV: 0 amount to transfer");
            L1_NULLIFIER.transferTokenToNTV(_token);
            uint256 balanceAfter = IERC20(_token).balanceOf(address(this));
            require(balanceAfter - balanceBefore >= sharedBridgeChainBalance, "NTV: wrong amount transferred");
        }
    }

    /// @notice Updates chain token balance within NTV to account for tokens transferred from the shared bridge (part of the migration process).
    /// @dev Clears chain balance on the shared bridge after the first call. Subsequent calls will not affect the state.
    /// @param _token The address of token to be transferred (address(1) for ether and contract address for ERC20).
    /// @param _targetChainId The chain ID of the corresponding ZK chain.
    function updateChainBalancesFromSharedBridge(address _token, uint256 _targetChainId) external {
        uint256 sharedBridgeChainBalance = L1_NULLIFIER.chainBalance(_targetChainId, _token);
        chainBalance[_targetChainId][_token] = chainBalance[_targetChainId][_token] + sharedBridgeChainBalance;
        L1_NULLIFIER.nullifyChainBalanceByNTV(_targetChainId, _token);
    }

    /*//////////////////////////////////////////////////////////////
                            L1 SPECIFIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _bridgeBurnNativeToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _prevMsgSender,
        bytes calldata _data
    ) internal override returns (bytes memory _bridgeMintData) {
        uint256 _depositAmount;
        (_depositAmount, ) = abi.decode(_data, (uint256, address));
        L1_NULLIFIER.transferAllowanceToNTV(_assetId, _depositAmount, _prevMsgSender);
        _bridgeMintData = super._bridgeBurnNativeToken(_chainId, _assetId, _prevMsgSender, _data);
    }

    ///  @inheritdoc IL1AssetHandler
    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        bytes32 _assetId,
        address _depositSender,
        bytes calldata _data
    ) external payable override onlyAssetRouter whenNotPaused {
        (uint256 _amount, ) = abi.decode(_data, (uint256, address));
        address l1Token = tokenAddress[_assetId];
        if (_amount == 0) {
            revert NoFundsTransferred();
        }

        // check that the chain has sufficient balance
        if (chainBalance[_chainId][l1Token] < _amount) {
            revert InsufficientChainBalance();
        }
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

    /*//////////////////////////////////////////////////////////////
                            INTERNAL & HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // get the computed address before the contract DeployWithCreate2 deployed using Bytecode of contract DeployWithCreate2 and salt specified by the sender
    function calculateCreate2TokenAddress(
        uint256 _originChainId,
        address _l1Token
    ) public view override returns (address) {
        bytes32 salt = _getCreate2Salt(_originChainId, _l1Token);
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bridgedTokenProxyBytecode))
        );
        return address(uint160(uint256(hash)));
    }

    /// @notice Transfers tokens from the depositor address to the smart contract address.
    /// @param _from The address of the depositor.
    /// @param _token The ERC20 token to be transferred.
    /// @param _amount The amount to be transferred.
    /// @return The difference between the contract balance before and after the transferring of funds.
    function _depositFunds(address _from, IERC20 _token, uint256 _amount) internal override returns (uint256) {
        address from = _from;
        // in the legacy scenario the SharedBridge = L1Nullifier was granting the allowance, we have to transfer from them instead of the user
        if (
            _token.allowance(address(L1_NULLIFIER), address(this)) >= _amount &&
            _token.allowance(_from, address(this)) < _amount
        ) {
            from = address(L1_NULLIFIER);
        }
        return super._depositFunds(from, _token, _amount);
    }

    // kl todo move to beacon proxy here as well
    function _deployBeaconProxy(bytes32 _salt) internal override returns (BeaconProxy proxy) {
        // Use CREATE2 to deploy the BeaconProxy
        address proxyAddress = Create2.deploy(0, _salt, bridgedTokenProxyBytecode);
        return BeaconProxy(payable(proxyAddress));
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE
    //////////////////////////////////////////////////////////////*/

    //     /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    //     function pause() external onlyOwner {
    //         _pause();
    //     }

    //     /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    //     function unpause() external onlyOwner {
    //         _unpause();
    //     }
}
