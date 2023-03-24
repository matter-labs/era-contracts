// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IL1BridgeLegacy.sol";
import "./interfaces/IL1Bridge.sol";
import "./interfaces/IL2Bridge.sol";

import "../zksync/interfaces/IMailbox.sol";
import "../common/interfaces/IL2ContractDeployer.sol";
import "../common/interfaces/IAllowList.sol";
import "../common/AllowListed.sol";
import "../common/libraries/UnsafeBytes.sol";
import "../common/libraries/L2ContractHelper.sol";
import "../common/L2ContractAddresses.sol";
import "../common/ReentrancyGuard.sol";
import "../vendor/AddressAliasHelper.sol";

/// @author Matter Labs
/// @notice Smart contract that allows depositing ERC20 tokens from Ethereum to zkSync v2.0
/// @dev It is standard implementation of ERC20 Bridge that can be used as a reference
/// for any other custom token bridges.
contract L1ERC20Bridge is IL1Bridge, IL1BridgeLegacy, AllowListed, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev The smart contract that manages the list with permission to call contract functions
    IAllowList immutable allowList;

    /// @dev zkSync smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication
    IMailbox immutable zkSyncMailbox;

    /// @dev The L2 gas limit for requesting L1 -> L2 transaction of deploying L2 bridge instance
    /// NOTE: this constant will be accurately calculated in the future.
    uint256 constant DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT = $(DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT);

    /// @dev The default l2GasPricePerPubdata to be used in bridges.
    uint256 constant REQUIRED_L2_GAS_PRICE_PER_PUBDATA = $(REQUIRED_L2_GAS_PRICE_PER_PUBDATA);

    /// @dev A mapping L2 block number => message number => flag
    /// @dev Used to indicate that zkSync L2 -> L1 message was already processed
    mapping(uint256 => mapping(uint256 => bool)) public isWithdrawalFinalized;

    /// @dev A mapping account => L1 token address => L2 deposit transaction hash => amount
    /// @dev Used for saving the number of deposited funds, to claim them in case the deposit transaction will fail
    mapping(address => mapping(address => mapping(bytes32 => uint256))) depositAmount;

    /// @dev The address of deployed L2 bridge counterpart
    address public l2Bridge;

    /// @dev The address of the factory that deploys proxy for L2 tokens
    address public l2TokenBeacon;

    /// @dev The bytecode hash of the L2 token contract
    bytes32 public l2TokenProxyBytecodeHash;

    mapping(address => uint256) public __DEPRECATED_lastWithdrawalLimitReset;

    /// @dev A mapping L1 token address => the accumulated withdrawn amount during the withdrawal limit window
    mapping(address => uint256) public __DEPRECATED_withdrawnAmountInWindow;

    /// @dev The accumulated deposited amount per user.
    /// @dev A mapping L1 token address => user address => the total deposited amount by the user
    mapping(address => mapping(address => uint256)) public totalDepositedAmountPerUser;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IMailbox _mailbox, IAllowList _allowList) reentrancyGuardInitializer {
        zkSyncMailbox = _mailbox;
        allowList = _allowList;
    }

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy
    /// @dev During initialization deploys L2 bridge counterpart as well as provides some factory deps for it
    /// @param _factoryDeps A list of raw bytecodes that are needed for deployment of the L2 bridge
    /// @notice _factoryDeps[0] == a raw bytecode of L2 bridge implementation
    /// @notice _factoryDeps[1] == a raw bytecode of proxy that is used as L2 bridge
    /// @notice _factoryDeps[2] == a raw bytecode of token proxy
    /// @param _l2TokenBeacon Pre-calculated address of the L2 token upgradeable beacon
    /// @notice At the time of the function call, it is not yet deployed in L2, but knowledge of its address
    /// @notice is necessary for determining L2 token address by L1 address, see `l2TokenAddress(address)` function
    /// @param _governor Address which can change L2 token implementation and upgrade the bridge
    function initialize(
        bytes[] calldata _factoryDeps,
        address _l2TokenBeacon,
        address _governor,
        uint256 _deployBridgeImplementationFee,
        uint256 _deployBridgeProxyFee
    ) external payable reentrancyGuardInitializer {
        require(_l2TokenBeacon != address(0), "nf");
        require(_governor != address(0), "nh");
        // We are expecting to see the exact three bytecodes that are needed to initialize the bridge
        require(_factoryDeps.length == 3, "mk");
        // The caller miscalculated deploy transactions fees
        require(msg.value == _deployBridgeImplementationFee + _deployBridgeProxyFee, "fee");
        l2TokenProxyBytecodeHash = L2ContractHelper.hashL2Bytecode(_factoryDeps[2]);
        l2TokenBeacon = _l2TokenBeacon;

        bytes32 l2BridgeImplementationBytecodeHash = L2ContractHelper.hashL2Bytecode(_factoryDeps[0]);
        bytes32 l2BridgeProxyBytecodeHash = L2ContractHelper.hashL2Bytecode(_factoryDeps[1]);

        // Deploy L2 bridge implementation contract
        address bridgeImplementationAddr = _requestDeployTransaction(
            _deployBridgeImplementationFee,
            l2BridgeImplementationBytecodeHash,
            "", // Empty constructor data
            _factoryDeps // All factory deps are needed for L2 bridge
        );

        // Prepare the proxy constructor data
        bytes memory l2BridgeProxyConstructorData;
        {
            // Data to be used in delegate call to initialize the proxy
            bytes memory proxyInitializationParams = abi.encodeCall(
                IL2Bridge.initialize,
                (address(this), l2TokenProxyBytecodeHash, _governor)
            );
            l2BridgeProxyConstructorData = abi.encode(bridgeImplementationAddr, _governor, proxyInitializationParams);
        }

        // Deploy L2 bridge proxy contract
        l2Bridge = _requestDeployTransaction(
            _deployBridgeProxyFee,
            l2BridgeProxyBytecodeHash,
            l2BridgeProxyConstructorData,
            new bytes[](0) // No factory deps are needed for L2 bridge proxy, because it is already passed in previous step
        );
    }

    /// @notice Requests L2 transaction that will deploy a contract with a given bytecode hash and constructor data.
    /// NOTE: it is always use deploy via create2 with ZERO salt
    /// @param _deployTransactionFee The fee that will be paid for the L1 -> L2 transaction
    /// @param _bytecodeHash The hash of the bytecode of the contract to be deployed
    /// @param _constructorData The data to be passed to the contract constructor
    /// @param _factoryDeps A list of raw bytecodes that are needed for deployment
    function _requestDeployTransaction(
        uint256 _deployTransactionFee,
        bytes32 _bytecodeHash,
        bytes memory _constructorData,
        bytes[] memory _factoryDeps
    ) internal returns (address deployedAddress) {
        bytes memory deployCalldata = abi.encodeCall(
            IL2ContractDeployer.create2,
            (bytes32(0), _bytecodeHash, _constructorData)
        );
        zkSyncMailbox.requestL2Transaction{value: _deployTransactionFee}(
            L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
            0,
            deployCalldata,
            DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _factoryDeps,
            msg.sender
        );

        deployedAddress = L2ContractHelper.computeCreate2Address(
            // Apply the alias to the address of the bridge contract, to get the `msg.sender` in L2.
            AddressAliasHelper.applyL1ToL2Alias(address(this)),
            bytes32(0), // Zero salt
            _bytecodeHash,
            keccak256(_constructorData)
        );
    }

    /// @notice Legacy deposit method with refunding the fee to the caller, use another `deposit` method instead.
    /// @dev Initiates a deposit by locking funds on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted
    /// @param _l2Receiver The account address that should receive funds on L2
    /// @param _l1Token The L1 token address which is deposited
    /// @param _amount The total amount of tokens to be bridged
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction
    /// @return l2TxHash The L2 transaction hash of deposit finalization
    /// NOTE: the function doesn't use `nonreentrant` and `senderCanCallFunction` modifiers, because the inner method do.
    function deposit(
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte
    ) external payable returns (bytes32 l2TxHash) {
        l2TxHash = deposit(_l2Receiver, _l1Token, _amount, _l2TxGasLimit, _l2TxGasPerPubdataByte, address(0));
    }

    /// @notice Initiates a deposit by locking funds on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted
    /// @param _l2Receiver The account address that should receive funds on L2
    /// @param _l1Token The L1 token address which is deposited
    /// @param _amount The total amount of tokens to be bridged
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction
    /// @param _refundRecipient The address on L2 that will receive the refund for the transaction. If the transaction fails,
    /// it will also be the address to receive `_l2Value`. If zero, the refund will be sent to the sender of the transaction.
    /// @return l2TxHash The L2 transaction hash of deposit finalization
    function deposit(
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) public payable nonReentrant senderCanCallFunction(allowList) returns (bytes32 l2TxHash) {
        require(_amount != 0, "2T"); // empty deposit amount
        uint256 amount = _depositFunds(msg.sender, IERC20(_l1Token), _amount);
        require(amount == _amount, "1T"); // The token has non-standard transfer logic
        // verify the deposit amount is allowed
        _verifyDepositLimit(_l1Token, msg.sender, _amount, false);

        bytes memory l2TxCalldata = _getDepositL2Calldata(msg.sender, _l2Receiver, _l1Token, amount);
        // If the refund recipient is not specified, the refund will be sent to the sender of the transaction.
        // Otherwise, the refund will be sent to the specified address.
        // Please note, if the recipient is a contract (the only exception is a contracting contract, but it is shooting in the leg).
        address refundRecipient = _refundRecipient;
        if (_refundRecipient == address(0)) {
            refundRecipient = msg.sender != tx.origin ? AddressAliasHelper.applyL1ToL2Alias(msg.sender) : msg.sender;
        }
        l2TxHash = zkSyncMailbox.requestL2Transaction{value: msg.value}(
            l2Bridge,
            0, // L2 msg.value
            l2TxCalldata,
            _l2TxGasLimit,
            _l2TxGasPerPubdataByte,
            new bytes[](0),
            refundRecipient
        );

        // Save the deposited amount to claim funds on L1 if the deposit failed on L2
        depositAmount[msg.sender][_l1Token][l2TxHash] = amount;

        emit DepositInitiated(l2TxHash, msg.sender, _l2Receiver, _l1Token, amount);
    }

    /// @dev Transfers tokens from the depositor address to the smart contract address
    /// @return The difference between the contract balance before and after the transferring of funds
    function _depositFunds(
        address _from,
        IERC20 _token,
        uint256 _amount
    ) internal returns (uint256) {
        uint256 balanceBefore = _token.balanceOf(address(this));
        _token.safeTransferFrom(_from, address(this), _amount);
        uint256 balanceAfter = _token.balanceOf(address(this));

        return balanceAfter - balanceBefore;
    }

    /// @dev Generate a calldata for calling the deposit finalization on the L2 bridge contract
    function _getDepositL2Calldata(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount
    ) internal view returns (bytes memory txCalldata) {
        bytes memory gettersData = _getERC20Getters(_l1Token);

        txCalldata = abi.encodeCall(
            IL2Bridge.finalizeDeposit,
            (_l1Sender, _l2Receiver, _l1Token, _amount, gettersData)
        );
    }

    /// @dev Receives and parses (name, symbol, decimals) from the token contract
    function _getERC20Getters(address _token) internal view returns (bytes memory data) {
        (, bytes memory data1) = _token.staticcall(abi.encodeCall(IERC20Metadata.name, ()));
        (, bytes memory data2) = _token.staticcall(abi.encodeCall(IERC20Metadata.symbol, ()));
        (, bytes memory data3) = _token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        data = abi.encode(data1, data2, data3);
    }

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2
    /// @param _depositSender The address of the deposit initiator
    /// @param _l1Token The address of the deposited L1 ERC20 token
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization
    /// @param _l2BlockNumber The L2 block number where the deposit finalization was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBlock The L2 transaction number in a block, in which the log was sent
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization
    function claimFailedDeposit(
        address _depositSender,
        address _l1Token,
        bytes32 _l2TxHash,
        uint256 _l2BlockNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBlock,
        bytes32[] calldata _merkleProof
    ) external nonReentrant senderCanCallFunction(allowList) {
        bool proofValid = zkSyncMailbox.proveL1ToL2TransactionStatus(
            _l2TxHash,
            _l2BlockNumber,
            _l2MessageIndex,
            _l2TxNumberInBlock,
            _merkleProof,
            TxStatus.Failure
        );
        require(proofValid, "yn");

        uint256 amount = depositAmount[_depositSender][_l1Token][_l2TxHash];
        require(amount > 0, "y1");

        // Change the total deposited amount by the user
        _verifyDepositLimit(_l1Token, _depositSender, amount, true);

        delete depositAmount[_depositSender][_l1Token][_l2TxHash];
        // Withdraw funds
        IERC20(_l1Token).safeTransfer(_depositSender, amount);

        emit ClaimedFailedDeposit(_depositSender, _l1Token, amount);
    }

    /// @notice Finalize the withdrawal and release funds
    /// @param _l2BlockNumber The L2 block number where the withdrawal was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBlock The L2 transaction number in a block, in which the log was sent
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization
    function finalizeWithdrawal(
        uint256 _l2BlockNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBlock,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external nonReentrant senderCanCallFunction(allowList) {
        require(!isWithdrawalFinalized[_l2BlockNumber][_l2MessageIndex], "pw");

        L2Message memory l2ToL1Message = L2Message({
            txNumberInBlock: _l2TxNumberInBlock,
            sender: l2Bridge,
            data: _message
        });

        (address l1Receiver, address l1Token, uint256 amount) = _parseL2WithdrawalMessage(l2ToL1Message.data);
        // Preventing the stack too deep error
        {
            bool success = zkSyncMailbox.proveL2MessageInclusion(
                _l2BlockNumber,
                _l2MessageIndex,
                l2ToL1Message,
                _merkleProof
            );
            require(success, "nq");
        }

        isWithdrawalFinalized[_l2BlockNumber][_l2MessageIndex] = true;
        // Withdraw funds
        IERC20(l1Token).safeTransfer(l1Receiver, amount);

        emit WithdrawalFinalized(l1Receiver, l1Token, amount);
    }

    /// @dev Decode the withdraw message that came from L2
    function _parseL2WithdrawalMessage(bytes memory _l2ToL1message)
        internal
        pure
        returns (
            address l1Receiver,
            address l1Token,
            uint256 amount
        )
    {
        // Check that the message length is correct.
        // It should be equal to the length of the function signature + address + address + uint256 = 4 + 20 + 20 + 32 = 76 (bytes).
        require(_l2ToL1message.length == 76, "kk");

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        require(bytes4(functionSignature) == this.finalizeWithdrawal.selector, "nt");

        (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
        (l1Token, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
        (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);
    }

    /// @dev Verify the deposit limit is reached to its cap or not
    function _verifyDepositLimit(
        address _l1Token,
        address _depositor,
        uint256 _amount,
        bool _claiming
    ) internal {
        IAllowList.Deposit memory limitData = IAllowList(allowList).getTokenDepositLimitData(_l1Token);
        if (!limitData.depositLimitation) return; // no deposit limitation is placed for this token

        if (_claiming) {
            totalDepositedAmountPerUser[_l1Token][_depositor] -= _amount;
        } else {
            require(totalDepositedAmountPerUser[_l1Token][_depositor] + _amount <= limitData.depositCap, "d1");
            totalDepositedAmountPerUser[_l1Token][_depositor] += _amount;
        }
    }

    /// @return The L2 token address that would be minted for deposit of the given L1 token
    function l2TokenAddress(address _l1Token) public view returns (address) {
        bytes32 constructorInputHash = keccak256(abi.encode(address(l2TokenBeacon), ""));
        bytes32 salt = bytes32(uint256(uint160(_l1Token)));

        return L2ContractHelper.computeCreate2Address(l2Bridge, salt, l2TokenProxyBytecodeHash, constructorInputHash);
    }
}
