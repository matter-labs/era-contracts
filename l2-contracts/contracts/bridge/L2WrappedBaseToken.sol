// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";

import {IL2WrappedBaseToken} from "./interfaces/IL2WrappedBaseToken.sol";
import {IL2StandardToken} from "./interfaces/IL2StandardToken.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The canonical implementation of the WETH token.
/// @dev The idea is to replace the legacy WETH9 (which has well-known issues) with something better.
/// This implementation has the following differences from the WETH9:
/// - It does not have a silent fallback method and will revert if it's called for a method it hasn't implemented.
/// - It implements `receive` method to allow users to deposit ether directly.
/// - It implements `permit` method to allow users to sign a message instead of calling `approve`.
/// - It implements `depositTo` method to allow users to deposit to another address.
/// - It implements `withdrawTo` method to allow users to withdraw to another address.
///
/// Note: This is an upgradeable contract. In the future, we will remove upgradeability to make it trustless.
/// But for now, when the Rollup has instant upgradability, we leave the possibility of upgrading to improve the contract if needed.
contract L2WrappedBaseToken is ERC20PermitUpgradeable, IL2WrappedBaseToken, IL2StandardToken {
    /// @dev Address of the L2 WETH Bridge.
    address public override l2Bridge;

    /// @dev Address of the L1 base token. It can be deposited to mint this L2 token.
    address public override l1Address;

    /// @dev Contract is expected to be used as proxy implementation.
    constructor() {
        // Disable initialization to prevent Parity hack.
        _disableInitializers();
    }

    /// @notice Initializes a contract token for later use. Expected to be used in the proxy.
    /// @notice This function is used to integrate the previously deployed WETH token with the bridge.
    /// @dev Sets up `name`/`symbol`/`decimals` getters.
    /// @param name_ The name of the token.
    /// @param symbol_ The symbol of the token.
    /// @param _l2Bridge Address of the L2 bridge
    /// @param _l1Address Address of the L1 token that can be deposited to mint this L2 WETH.
    /// Note: The decimals are hardcoded to 18, the same as on Ether.
    function initializeV2(
        string memory name_,
        string memory symbol_,
        address _l2Bridge,
        address _l1Address
    ) external reinitializer(2) {
        require(_l2Bridge != address(0), "L2 bridge address cannot be zero");
        require(_l1Address != address(0), "L1 WETH token address cannot be zero");
        l2Bridge = _l2Bridge;
        l1Address = _l1Address;

        // Set decoded values for name and symbol.
        __ERC20_init_unchained(name_, symbol_);

        // Set the name for EIP-712 signature.
        __ERC20Permit_init(name_);

        emit Initialize(name_, symbol_, 18);
    }

    modifier onlyBridge() {
        require(msg.sender == l2Bridge, "permission denied"); // Only L2 bridge can call this method
        _;
    }

    /// @notice Function for minting tokens on L2, implemented only to be compatible with IL2StandardToken interface.
    /// Always reverts instead of minting anything!
    /// Note: Use `deposit`/`depositTo` methods instead.
    // solhint-disable-next-line no-unused-vars
    function bridgeMint(address _to, uint256 _amount) external override onlyBridge {
        revert("bridgeMint is not implemented! Use deposit/depositTo methods instead.");
    }

    /// @dev Burn tokens from a given account and send the same amount of Ether to the bridge.
    /// @param _from The account from which tokens will be burned.
    /// @param _amount The amount that will be burned.
    /// @notice Should be called by the bridge before withdrawing tokens to L1.
    function bridgeBurn(address _from, uint256 _amount) external override onlyBridge {
        _burn(_from, _amount);
        // sends Ether to the bridge
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Failed withdrawal");

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
        require(success, "Failed withdrawal");
    }

    /// @dev Fallback function to allow receiving Ether.
    receive() external payable {
        depositTo(msg.sender);
    }
}
