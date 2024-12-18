// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {L2TransactionRequestTwoBridgesInner} from "../../bridgehub/IBridgehub.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";
import {TWO_BRIDGES_MAGIC_VALUE, ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {IL1NativeTokenVault} from "../../bridge/ntv/L1NativeTokenVault.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "../../common/L2ContractAddresses.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";
import {IL2SharedBridgeLegacy} from "../../bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {IL2SharedBridgeLegacyFunctions} from "../../bridge/interfaces/IL2SharedBridgeLegacyFunctions.sol";

contract DummySharedBridge is PausableUpgradeable {
    using SafeERC20 for IERC20;

    IL1NativeTokenVault public nativeTokenVault;

    event BridgehubDepositBaseTokenInitiated(
        uint256 indexed chainId,
        address indexed from,
        bytes32 assetId,
        uint256 amount
    );

    bytes32 dummyL2DepositTxHash;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across zkChains.
    /// This serves as a security measure until hyperbridging is implemented.
    mapping(uint256 chainId => mapping(address l1Token => uint256 balance)) public chainBalance;

    /// @dev Indicates whether the hyperbridging is enabled for a given chain.

    address l1ReceiverReturnInFinalizeWithdrawal;
    address l1TokenReturnInFinalizeWithdrawal;
    uint256 amountReturnInFinalizeWithdrawal;

    /// @dev A mapping assetId => assetHandlerAddress
    /// @dev Tracks the address of Asset Handler contracts, where bridged funds are locked for each asset
    /// @dev P.S. this liquidity was locked directly in SharedBridge before
    mapping(bytes32 assetId => address assetHandlerAddress) public assetHandlerAddress;

    constructor(bytes32 _dummyL2DepositTxHash) {
        dummyL2DepositTxHash = _dummyL2DepositTxHash;
    }

    function setDataToBeReturnedInFinalizeWithdrawal(address _l1Receiver, address _l1Token, uint256 _amount) external {
        l1ReceiverReturnInFinalizeWithdrawal = _l1Receiver;
        l1TokenReturnInFinalizeWithdrawal = _l1Token;
        amountReturnInFinalizeWithdrawal = _amount;
    }

    function receiveEth(uint256 _chainId) external payable {}

    function depositLegacyErc20Bridge(
        address, //_msgSender,
        address, //_l2Receiver,
        address, //_l1Token,
        uint256, //_amount,
        uint256, //_l2TxGasLimit,
        uint256, //_l2TxGasPerPubdataByte,
        address //_refundRecipient
    ) external payable returns (bytes32 txHash) {
        txHash = dummyL2DepositTxHash;
    }

    function claimFailedDepositLegacyErc20Bridge(
        address, //_depositSender,
        address, //_l1Token,
        uint256, //_amount,
        bytes32, //_l2TxHash,
        uint256, //_l2BatchNumber,
        uint256, //_l2MessageIndex,
        uint16, //_l2TxNumberInBatch,
        bytes32[] calldata // _merkleProof
    ) external {}

    function claimFailedDeposit(
        uint256, // _chainId,
        address, // _depositSender,
        address, // _l1Asset,
        uint256, // _amount,
        bytes32, // _l2TxHash,
        uint256, // _l2BatchNumber,
        uint256, // _l2MessageIndex,
        uint16, // _l2TxNumberInBatch,
        bytes32[] calldata //_merkleProof
    ) external {}

    function finalizeWithdrawalLegacyErc20Bridge(
        uint256, //_l2BatchNumber,
        uint256, //_l2MessageIndex,
        uint16, //_l2TxNumberInBatch,
        bytes calldata, //_message,
        bytes32[] calldata //_merkleProof
    ) external view returns (address l1Receiver, address l1Token, uint256 amount) {
        l1Receiver = l1ReceiverReturnInFinalizeWithdrawal;
        l1Token = l1TokenReturnInFinalizeWithdrawal;
        amount = amountReturnInFinalizeWithdrawal;
    }

    event Debugger(uint256);

    function pause() external {
        _pause();
    }

    function unpause() external {
        _unpause();
    }

    // This function expects abi encoded data
    function _parseL2WithdrawalMessage(
        bytes memory _l2ToL1message
    ) internal view returns (address l1Receiver, address l1Token, uint256 amount) {
        (l1Receiver, l1Token, amount) = abi.decode(_l2ToL1message, (address, address, uint256));
    }

    // simple function to just transfer the funds
    function finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external returns (address l1Receiver, address l1Token, uint256 amount) {
        (l1Receiver, l1Token, amount) = _parseL2WithdrawalMessage(_message);

        if (l1Token == address(1)) {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), l1Receiver, amount, 0, 0, 0, 0)
            }
            require(callSuccess, "ShB: withdraw failed");
        } else {
            // Withdraw funds
            IERC20(l1Token).safeTransfer(l1Receiver, amount);
        }
    }

    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        uint256 _amount
    ) external payable whenNotPaused {
        // Dummy bridge supports only working with ETH for simplicity.
        require(msg.value == _amount, "L1AR: msg.value not equal to amount");

        chainBalance[_chainId][address(1)] += _amount;

        // Note that we don't save the deposited amount, as this is for the base token, which gets sent to the refundRecipient if the tx fails
        emit BridgehubDepositBaseTokenInitiated(_chainId, _originalCaller, _assetId, _amount);
    }

    function _depositFunds(address _from, IERC20 _token, uint256 _amount) internal returns (uint256) {
        uint256 balanceBefore = _token.balanceOf(address(this));
        _token.transferFrom(_from, address(this), _amount);
        uint256 balanceAfter = _token.balanceOf(address(this));

        return balanceAfter - balanceBefore;
    }

    function bridgehubDeposit(
        uint256,
        address _originalCaller,
        uint256,
        bytes calldata _data
    ) external payable returns (L2TransactionRequestTwoBridgesInner memory request) {
        (address _l1Token, uint256 _depositAmount, address _l2Receiver) = abi.decode(
            _data,
            (address, uint256, address)
        );
        uint256 amount;

        if (_l1Token == ETH_TOKEN_ADDRESS) {
            amount = msg.value;
            require(_depositAmount == 0, "ShB wrong withdraw amount");
        } else {
            require(msg.value == 0, "ShB m.v > 0 for BH d.it 2");
            amount = _depositAmount;

            uint256 withdrawAmount = _depositFunds(_originalCaller, IERC20(_l1Token), _depositAmount);
            require(withdrawAmount == _depositAmount, "5T"); // The token has non-standard transfer logic
        }

        bytes memory l2TxCalldata = abi.encodeCall(
            IL2SharedBridgeLegacyFunctions.finalizeDeposit,
            (_originalCaller, _l2Receiver, _l1Token, amount, new bytes(0))
        );
        bytes32 txDataHash = keccak256(abi.encode(_originalCaller, _l1Token, amount));

        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: address(0xCAFE),
            l2Calldata: l2TxCalldata,
            factoryDeps: new bytes[](0),
            txDataHash: txDataHash
        });
    }

    function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external {}

    /// @dev Sets the L1ERC20Bridge contract address. Should be called only once.
    function setNativeTokenVault(IL1NativeTokenVault _nativeTokenVault) external {
        require(address(nativeTokenVault) == address(0), "L1AR: legacy bridge already set");
        require(address(_nativeTokenVault) != address(0), "L1AR: legacy bridge 0");
        nativeTokenVault = _nativeTokenVault;
    }

    /// @dev Used to set the assedAddress for a given assetId.
    function setAssetHandlerAddressThisChain(bytes32 _additionalData, address _assetHandlerAddress) external {
        address sender = msg.sender == address(nativeTokenVault) ? L2_NATIVE_TOKEN_VAULT_ADDR : msg.sender;
        bytes32 assetId = keccak256(abi.encode(uint256(block.chainid), sender, _additionalData));
        assetHandlerAddress[assetId] = _assetHandlerAddress;
        // assetDeploymentTracker[assetId] = sender;
        // emit AssetHandlerRegisteredInitial(assetId, _assetHandlerAddress, _additionalData, sender);
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
