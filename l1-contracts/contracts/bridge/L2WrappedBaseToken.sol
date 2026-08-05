// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";

import {IL2WrappedBaseToken} from "./interfaces/IL2WrappedBaseToken.sol";
import {IBridgedStandardToken} from "./interfaces/IBridgedStandardToken.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";

import {BridgeMintNotImplemented, Unauthorized, WithdrawFailed, ZeroAddress} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The canonical WETH-style wrapped-base-token implementation: unlike the legacy WETH9 it has no
/// silent fallback and adds `receive`, `permit`, `depositTo` and `withdrawTo`. See {protocol-docs/bridging.md#base-token-handling}.
/// @dev Still upgradeable for now; upgradeability will be removed later to make it trustless.
contract L2WrappedBaseToken is ERC20PermitUpgradeable, IL2WrappedBaseToken, IBridgedStandardToken {
    /// @dev Address of the L2 WETH Bridge.
    address public override l2Bridge;

    /// @dev Address of the L1 base token. It can be deposited to mint this L2 token.
    address public override l1Address;

    /// @dev Address of the native token vault.
    address public override nativeTokenVault;

    /// @dev The assetId of the base token. The wrapped token does not have its own assetId.
    bytes32 public baseTokenAssetId;

    modifier onlyBridge() {
        require(msg.sender == l2Bridge, Unauthorized(msg.sender));
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    constructor() {
        // Disable initialization to prevent Parity hack.
        _disableInitializers();
    }

    /// @dev Ether sent directly to the contract is deposited to the sender.
    receive() external payable {
        depositTo(msg.sender);
    }

    /// @notice Initializes a contract token for later use. Expected to be used in the proxy.
    /// @notice This function is used to integrate the previously deployed WETH token with the bridge.
    /// @dev Sets up `name`/`symbol`/`decimals` getters.
    /// @param name_ The name of the token.
    /// @param symbol_ The symbol of the token.
    /// @param _l2Bridge Address of the L2 bridge
    /// @param _l1Address Address of the L1 token that can be deposited to mint this L2 WETH.
    /// Note: The decimals are hardcoded to 18, the same as on Ether.
    function initializeV3(
        string calldata name_,
        string calldata symbol_,
        address _l2Bridge,
        address _l1Address,
        bytes32 _baseTokenAssetId
    ) external reinitializer(3) {
        require(_l2Bridge != address(0), ZeroAddress());

        require(_l1Address != address(0), ZeroAddress());
        require(_baseTokenAssetId != bytes32(0), ZeroAddress());
        l2Bridge = _l2Bridge;
        l1Address = _l1Address;
        nativeTokenVault = L2_NATIVE_TOKEN_VAULT_ADDR;
        baseTokenAssetId = _baseTokenAssetId;

        // Set decoded values for name and symbol.
        __ERC20_init_unchained(name_, symbol_);

        // Set the name for EIP-712 signature.
        __ERC20Permit_init(name_);

        emit Initialize(name_, symbol_, 18);
    }

    /// @inheritdoc IBridgedStandardToken
    /// @dev Always reverts: the wrapper cannot be bridge-minted; use `deposit`/`depositTo` instead.
    // solhint-disable-next-line no-unused-vars
    function bridgeMint(address _to, uint256 _amount) external view override onlyBridge {
        revert BridgeMintNotImplemented();
    }

    /// @inheritdoc IBridgedStandardToken
    /// @dev Burns the tokens and sends the same amount of ether to the bridge (msg.sender).
    function bridgeBurn(address _from, uint256 _amount) external override onlyBridge {
        _burn(_from, _amount);
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, WithdrawFailed());

        emit BridgeBurn(_from, _amount);
    }

    /// @notice Deposit Ether to mint WETH.
    function deposit() external payable override {
        depositTo(msg.sender);
    }

    /// @notice Withdraw WETH to get Ether.
    function withdraw(uint256 _amount) external override {
        withdrawTo(msg.sender, _amount);
    }

    /// @notice Deposit Ether to mint WETH to a given account.
    function depositTo(address _to) public payable override {
        _mint(_to, msg.value);
    }

    /// @notice Withdraw WETH to get Ether to a given account.
    /// burns sender's tokens and sends Ether to the given account
    function withdrawTo(address _to, uint256 _amount) public override {
        _burn(msg.sender, _amount);
        (bool success, ) = _to.call{value: _amount}("");
        require(success, WithdrawFailed());
    }

    /// @inheritdoc IBridgedStandardToken
    function originToken() external view override returns (address) {
        return l1Address;
    }

    /// @inheritdoc IBridgedStandardToken
    /// @dev Returns the base token's asset ID — the wrapper has no asset ID of its own.
    function assetId() external view override returns (bytes32) {
        return baseTokenAssetId;
    }
}
