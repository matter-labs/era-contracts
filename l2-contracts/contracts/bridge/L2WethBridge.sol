// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IL2Bridge} from "./interfaces/IL2Bridge.sol";
import {IL2Weth} from "./interfaces/IL2Weth.sol";
import {IL2StandardToken} from "./interfaces/IL2StandardToken.sol";

import {L2_ETH_ADDRESS} from "../L2ContractHelper.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev This contract works in conjunction with the L1WethBridge to streamline the process of bridging WETH tokens between L1 and L2.
/// @dev This contract accepts Ether from the L1 Bridge during deposits, converts it to WETH, and sends it to the user.
/// @dev For withdrawals, it processes the user's WETH tokens by unwrapping them and transferring the equivalent Ether to the L1 Bridge.
/// @dev This custom bridge differs from the standard ERC20 bridge by handling the conversion between Ether and WETH directly,
/// eliminating the need for users to perform additional wrapping and unwrapping transactions on both L1 and L2 networks.
contract L2WethBridge is IL2Bridge, Initializable {
    /// @dev Event emitted when ETH is received by the contract.
    event EthReceived(uint256 amount);

    /// @dev The address of the L1 bridge counterpart.
    address public override l1Bridge;

    /// @dev WETH token address on L1.
    address public l1WethAddress;

    /// @dev WETH token address on L2.
    address public l2WethAddress;

    /// @dev isEthBaseToken
    bool public isEthBaseToken;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Disable the initialization to prevent Parity hack.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract with parameters needed for its functionality.
    /// @param _l1Bridge The address of the L1 Bridge contract.
    /// @param _l1WethAddress The address of the L1 WETH token.
    /// @dev The function can only be called once during contract deployment due to the 'initializer' modifier.
    function initialize(
        address _l1Bridge,
        address _l1WethAddress,
        address _proxyAdmin,
        bool _isEthBaseToken
    ) external initializer {
        require(_l1Bridge != address(0), "L1 WETH bridge address cannot be zero");
        require(_l1WethAddress != address(0), "L1 WETH token address cannot be zero");

        l1Bridge = _l1Bridge;
        l1WethAddress = _l1WethAddress;
        isEthBaseToken = _isEthBaseToken;

        address l2WethImplementation = address(new L2Weth{salt: bytes32(0)}());
        bytes memory initData = abi.encodeWithSelector(L2Weth.initialize.selector, "Wrapped Ether", "WETH");
        TransparentUpgradeableProxy l2Weth = new TransparentUpgradeableProxy{salt: bytes32(0)}(
            l2WethImplementation,
            _proxyAdmin,
            initData
        );
        L2Weth(payable(address(l2Weth))).initializeV2(address(this), l1WethAddress, _isEthBaseToken);
        l2WethAddress = address(l2Weth);
    }

    /// @notice Initiate the withdrawal of WETH from L2 to L1 by sending a message to L1 and calling withdraw on L2EthToken contract
    /// @param _l1Receiver The account address that would receive the WETH on L1
    /// @param _l2Token Address of the L2 WETH token
    /// @param _amount Total amount of WETH to withdraw
    function withdraw(address _l1Receiver, address _l2Token, uint256 _amount) external override {
        require(_l2Token == l2WethAddress, "Only WETH can be withdrawn");
        require(_amount > 0, "Amount cannot be zero");

        // Burn WETH on L2, receive ETH.
        IL2StandardToken(l2WethAddress).bridgeBurn(msg.sender, _amount);

        if (isEthBaseToken) {
            // WETH withdrawal message.
            bytes memory wethMessage = abi.encodePacked(_l1Receiver);

            // Withdraw ETH to L1 bridge.
            L2_ETH_ADDRESS.withdrawWithMessage{value: _amount}(l1Bridge, wethMessage);
        } else {
            bytes memory message = _getL1WithdrawMessage(_l1Receiver, l1WethAddress, _amount);
            L2ContractHelper.sendMessageToL1(message);
        }

        emit WithdrawalInitiated(msg.sender, _l1Receiver, l2WethAddress, _amount);
    }

    /// @dev Encode the message for l2ToL1log sent with withdraw initialization
    function _getL1WithdrawMessage(
        address _to,
        address _l1Token,
        uint256 _amount
    ) internal pure returns (bytes memory) {
        // note we use the IL1BridgeDeprecated only to send L1<>L2 messages,
        // and we use this interface so that when the switch happened the old messages could be processed
        return abi.encodePacked(IL1BridgeDeprecated.finalizeWithdrawal.selector, _to, _l1Token, _amount);
    }

    /// @notice Finalize the deposit of WETH from L1 to L2 by calling deposit on L2Weth contract
    /// @param _l1Sender The account address that initiated the deposit on L1
    /// @param _l2Receiver The account address that would receive the WETH on L2
    /// @param _l1Token Address of the L1 WETH token
    /// @param _amount Total amount of WETH to deposit
    function finalizeDeposit(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        bytes calldata // _data
    ) external payable override {
        require(
            AddressAliasHelper.undoL1ToL2Alias(msg.sender) == l1Bridge,
            "Only L1 WETH bridge can call this function"
        );

        require(_l1Token == l1WethAddress, "Only WETH can be deposited");

        if (isEthBaseToken) {
            require(msg.value == _amount, "Amount mismatch");
            // Deposit WETH to L2 receiver.
            IL2Weth(l2WethAddress).depositTo{value: msg.value}(_l2Receiver);
        } else {
            require(msg.value == 0, "Value should be 0 for ERC20 bridge");
            IL2StandardToken(l2WethAddress).bridgeMint(_l2Receiver, _amount);
        }

        emit FinalizeDeposit(_l1Sender, _l2Receiver, l2WethAddress, _amount);
    }

    /// @return l1Token Address of an L1 token counterpart.
    function l1TokenAddress(address _l2Token) public view override returns (address l1Token) {
        l1Token = _l2Token == l2WethAddress ? l1WethAddress : address(0);
    }

    /// @return l2Token Address of an L2 token counterpart.
    function l2TokenAddress(address _l1Token) public view override returns (address l2Token) {
        l2Token = _l1Token == l1WethAddress ? l2WethAddress : address(0);
    }

    receive() external payable {
        require(msg.sender == l2WethAddress, "pd");
        require(isEthBaseToken, "Base token can only be deposited if it is ETH");
        emit EthReceived(msg.value);
    }
}
