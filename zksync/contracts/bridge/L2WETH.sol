// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";
import "./interfaces/IL2WETH.sol";
import "./interfaces/IL2StandardToken.sol";

/// @author Matter Labs
/// @notice The canonical implementation of the WETH token.
/// @dev The idea is to replace the legacy WETH9 (which has well-known issues) with something better.
/// This implementation has the following differences from the WETH9:
/// - It does not have a silent fallback method and will revert if it's called for a method it hasn't implemented.
/// - It implements `receive` method to allow users to deposit ether directly.
/// - It implements `permit` method to allow users to sign a message instead of calling `approve`.
///
/// Note: This is an upgradeable contract. In the future, we will remove upgradeability to make it trustless.
/// But for now, when the Rollup has instant upgradability, we leave the possibility of upgrading to improve the contract if needed.
contract L2WETH is ERC20PermitUpgradeable, IL2WETH, IL2StandardToken {
    /// @dev Contract is expected to be used as proxy implementation.
    constructor() {
        // Disable initialization to prevent Parity hack.
        _disableInitializers();
    }

    /// @notice Initializes a contract token for later use. Expected to be used in the proxy.
    /// @dev Stores the L1 address of the bridge and set `name`/`symbol`/`decimals` getters.
    /// @param name_ The name of the token.
    /// @param symbol_ The symbol of the token.
    /// Note: The decimals are hardcoded to 18, the same as on Ether.
    function initialize(string memory name_, string memory symbol_) external initializer {
        // Set decoded values for name and symbol.
        __ERC20_init_unchained(name_, symbol_);

        // Set the name for EIP-712 signature.
        __ERC20Permit_init(name_);

        emit Initialize(name_, symbol_, 18);
    }

    /// @notice Function for minting tokens on L2, is implemented †o be compatible with StandardToken interface.
    /// @dev Should be never called because the WETH should be collateralized with Ether.
    /// Note: Use `deposit`/`depositTo` methods instead.
    function bridgeMint(
        address, // _to
        uint256 // _amount
    ) external override {
        revert("bridgeMint is not implemented");
    }

    /// @dev Burn tokens from a given account and send the same amount of Ether to the bridge.
    /// @param _from The account from which tokens will be burned.
    /// @param _amount The amount that will be burned.
    /// @notice Should be called by the bridge before withdrawing tokens to L1.
    function bridgeBurn(address _from, uint256 _amount) external override {
        revert("bridgeBurn is not implemented yet");
    }

    function l2Bridge() external view returns (address) {
        revert("l2Bridge is not implemented yet");
    }

    function l1Address() external view returns (address) {
        revert("l1Address is not implemented yet");
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
