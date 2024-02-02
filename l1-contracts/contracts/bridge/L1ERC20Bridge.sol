// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IL1BridgeLegacy} from "./interfaces/IL1BridgeLegacy.sol";
import {IL1ERC20Bridge, ConfirmL2TxStatus} from "./interfaces/IL1ERC20Bridge.sol";
import {IL2Bridge} from "./interfaces/IL2Bridge.sol";

import {IMailbox} from "../state-transition/chain-interfaces/IMailbox.sol";
import {L2Message, TxStatus} from "../common/Messaging.sol";
import {UnsafeBytes} from "../common/libraries/UnsafeBytes.sol";
import {L2ContractHelper} from "../common/libraries/L2ContractHelper.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {ERA_CHAIN_ID, ERA_TOKEN_BEACON_ADDRESS, ERA_ERC20_BRIDGE_ADDRESS, ETH_TOKEN_ADDRESS, TWO_BRIDGES_MAGIC_VALUE} from "../common/Config.sol";
import {IBridgehub, L2TransactionRequestTwoBridgesInner, L2TransactionRequestDirect} from "../bridgehub/IBridgehub.sol";
import {InitializableRandomStorage} from "../common/random-storage/InitializableRandomStorage.sol";
import {L2_ETH_TOKEN_SYSTEM_CONTRACT_ADDR} from "../common/L2ContractAddresses.sol";
import {Ownable2StepRandomStorage} from "../common/random-storage/Ownable2StepRandomStorage.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Smart contract that allows depositing ERC20 tokens from Ethereum to hyperchains
/// @dev It is standard implementation of ERC20 Bridge that can be used as a reference
/// for any other custom token bridges.
contract L1ERC20Bridge is IL1ERC20Bridge, ReentrancyGuard, InitializableRandomStorage, Ownable2StepRandomStorage {
    using SafeERC20 for IERC20;

    /// @dev Bridgehub smart contract that is used to operate with L2s via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override bridgehub;

    /// @dev A mapping L2 batch number => message number => flag.
    /// @dev Used to indicate that L2 -> L1 message was already processed for zkSync Era withdrawals.
    /// @dev Please note, this mapping is used only for Era withdrawals, while `isWithdrawalFinalizedShared` is used for every other hyperchains.
    mapping(uint256 l2BatchNumber => mapping(uint256 l2ToL1MessageNumber => bool isFinalized))
        internal isWithdrawalFinalizedEra;

    /// @dev A mapping account => L1 token address => L2 deposit transaction hash => amount.
    /// @dev Used for saving the number of deposited funds, to claim them in case the deposit transaction will fail in zkSync Era.
    /// @dev Please note, this mapping is used only for Era deposits, while `depositHappened` is used for every other hyperchains.
    mapping(address account => mapping(address l1Token => mapping(bytes32 depositL2TxHash => uint256 amount)))
        internal depositAmountEra;

    /// @dev The address that was used as a L2 bridge counterpart in zkSync Era.
    /// Note, it is deprecated in favour of `l2BridgeAddress` mapping.
    address internal __DEPRECATED_l2Bridge;

    /// @dev The address that was used as a beacon for L2 tokens in zkSync Era.
    /// Note, it is deprecated in favour of `l2TokenBeaconAddress` mapping.
    address internal __DEPRECATED_l2TokenBeacon;

    /// @notice Stores the hash of the L2 token proxy contract's bytecode. 
    /// @dev L2 token proxy bytecode is the same for all hyperchains and the owner can NOT override this value for a custom hyperchain.
    bytes32 public l2TokenProxyBytecodeHash;

    /// @dev Deprecated storage variable related to withdrawal limitations.
    mapping(address => uint256) private __DEPRECATED_lastWithdrawalLimitReset;

    /// @dev Deprecated storage variable related to withdrawal limitations.
    mapping(address => uint256) private __DEPRECATED_withdrawnAmountInWindow;

    /// @dev Deprecated storage variable related to deposit limitations.
    mapping(address => mapping(address => uint256)) private __DEPRECATED_totalDepositedAmountPerUser;

    /// @dev A mapping chainId => bridgeProxy. Used to store the bridge proxy's address, and to see if it has been deployed yet.
    mapping(uint256 chainId => address l2Bridge) public override l2BridgeAddress;

    /// @dev A mapping chainId => l2TokenBeacon. Used to store the token beacon proxy's address, and to see if it has been deployed yet.
    mapping(uint256 chainId => address l2TokenBeacon) public override l2TokenBeaconAddress;

    /// @dev A mapping L2 _chainId => Batch number => message number => flag
    /// @dev Used to indicate that L2 -> L1 message was already processed
    mapping(uint256 chainId => mapping(uint256 l2BatchNumber => mapping(uint256 l2ToL1MessageNumber => bool isFinalized))) public isWithdrawalFinalizedShared;

    /// @dev A mapping chainId => L2 deposit transaction hash  => keccak256(account, tokenAddress, amount)
    /// @dev Used for saving the number of deposited funds, to claim them in case the deposit transaction will fail.
    /// @dev the l2TxHash is unique, as it is determined by the contracts, while dataHash is not, so we that is the output.
    mapping(uint256 chainId => mapping(bytes32 l2DepositTxHash => bytes32 depositDataHash)) public override depositHappened;

    /// @dev Used for extra security until hyperbridging is implemented.
    mapping(uint256 chainId => mapping(address l1Token => uint256 balance)) internal chainBalance;

    /// @dev Indicates whether the hyperbridging is enabled for a given chain.
    mapping(uint256 chainId => bool enabled) internal hyperbridgingEnabled;

    /// @notice Checks that the message sender is the governor
    modifier onlyBridgehub() {
        require(msg.sender == address(bridgehub), "EB not BH");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IBridgehub _bridgehub) reentrancyGuardInitializer {
        bridgehub = _bridgehub;
    }

    /// @dev Initializes the reentrancy guard for new blockchain deployments.
    /// @dev For the proper initialization one should use `initializeV2` after calling this.
    function initialize() external reentrancyGuardInitializer {}

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy
    /// @dev During initialization deploys L2 bridge counterpart as well as provides some factory deps for it
    /// @param _owner Address which can change L2 token implementation and upgrade the bridge
    /// implementation. The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge
    function initializeV2(
        address _owner
    ) external reinitializer(2) {
        require(_owner != address(0), "EB owner 0");
        _transferOwnership(_owner);

        l2TokenBeaconAddress[ERA_CHAIN_ID] = ERA_TOKEN_BEACON_ADDRESS;
        l2BridgeAddress[ERA_CHAIN_ID] = ERA_ERC20_BRIDGE_ADDRESS;
    }

    /// @dev Initializes governance settings for a specific chain by setting the addresses of the L2 bridge and the L2 token beacon. 
    /// @dev This function is designed to configure special or custom bridges that are not deployed through this contract.
    /// It opens the integration of unique bridging solutions across different chains.
    function initializeChainGovernance(
        uint256 _chainId,
        address _l2BridgeAddress,
        address _l2TokenBeaconAddress
    ) external onlyOwner {
        l2BridgeAddress[_chainId] = _l2BridgeAddress;
        l2TokenBeaconAddress[_chainId] = _l2TokenBeaconAddress;
    }

    /// @notice Initiates a deposit by locking funds on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted
    /// only used for eth based chains
    /// @dev If the token is bridged for the first time, the L2 token contract will be deployed. Note however, that the
    /// newly-deployed token does not support any custom logic, i.e. rebase tokens' functionality is not supported.
    /// @param _l2Receiver The account address that should receive funds on L2
    /// @param _l1Token The L1 token address which is deposited
    /// @param _mintValue The amount of baseTokens to be minted on L2. In this case Eth
    /// @param _amount The total amount of tokens to be bridged
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction
    /// @param _refundRecipient The address on L2 that will receive the refund for the transaction.
    /// @dev If the L2 deposit finalization transaction fails, the `_refundRecipient` will receive the `_l2Value`.
    /// Please note, the contract may change the refund recipient's address to eliminate sending funds to addresses
    /// out of control.
    /// - If `_refundRecipient` is a contract on L1, the refund will be sent to the aliased `_refundRecipient`.
    /// - If `_refundRecipient` is set to `address(0)` and the sender has NO deployed bytecode on L1, the refund will
    /// be sent to the `msg.sender` address.
    /// - If `_refundRecipient` is set to `address(0)` and the sender has deployed bytecode on L1, the refund will be
    /// sent to the aliased `msg.sender` address.
    /// @dev The address aliasing of L1 contracts as refund recipient on L2 is necessary to guarantee that the funds
    /// are controllable through the Mailbox, since the Mailbox applies address aliasing to the from address for the
    /// L2 tx if the L1 msg.sender is a contract. Without address aliasing for L1 contracts as refund recipients they
    /// would not be able to make proper L2 tx requests through the Mailbox to use or withdraw the funds from L2, and
    /// the funds would be lost.
    /// @return l2TxHash The L2 transaction hash of deposit finalization
    function deposit(
        uint256 _chainId,
        address _l2Receiver,
        address _l1Token,
        uint256 _mintValue,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) public payable nonReentrant returns (bytes32 l2TxHash) {
        require(l2BridgeAddress[_chainId] != address(0), "EB b. n dep");
        {
            bool ethIsBaseToken = (bridgehub.baseToken(_chainId) == ETH_TOKEN_ADDRESS);
            require(ethIsBaseToken, "EB d.it n E chain");
            require(_mintValue == msg.value, "EB w mintV");

            require(_amount != 0, "2T"); // empty deposit amount
            uint256 amount = _depositFunds(msg.sender, IERC20(_l1Token), _amount);
            require(amount == _amount, "1T"); // The token has non-standard transfer logic

            if (!hyperbridgingEnabled[_chainId]) {
                chainBalance[_chainId][_l1Token] += _amount;
            }
        }
        bytes memory l2TxCalldata = _getDepositL2Calldata(msg.sender, _l2Receiver, _l1Token, _amount);
        // If the refund recipient is not specified, the refund will be sent to the sender of the transaction.
        // Otherwise, the refund will be sent to the specified address.
        // If the recipient is a contract on L1, the address alias will be applied.
        address refundRecipient = _refundRecipient;
        if (_refundRecipient == address(0)) {
            refundRecipient = msg.sender != tx.origin ? AddressAliasHelper.applyL1ToL2Alias(msg.sender) : msg.sender;
        }

        l2TxHash = _depositSendTx(
            _chainId,
            _mintValue,
            l2TxCalldata,
            _l2TxGasLimit,
            _l2TxGasPerPubdataByte,
            refundRecipient
        );

        // Save the deposited amount to claim funds on L1 if the deposit failed on L2
        bytes32 txDataHash = keccak256(abi.encode(msg.sender, _l1Token, _amount));
        depositHappened[_chainId][l2TxHash] = txDataHash;

        emit DepositInitiatedSharedBridge(_chainId, txDataHash, msg.sender, _l2Receiver, _l1Token, _amount);
        if (_chainId == ERA_CHAIN_ID) {
            emit DepositInitiated(l2TxHash, msg.sender, _l2Receiver, _l1Token, _amount);
        }
    }

    /// @dev internal to avoid stack too deep error
    function _depositSendTx(
        uint256 _chainId,
        uint256 _mintValue,
        bytes memory _l2TxCalldata,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) internal returns (bytes32 l2TxHash) {
        // note msg.value is 0 for not eth base tokens.

        L2TransactionRequestDirect memory request = L2TransactionRequestDirect({
            chainId: _chainId,
            l2Contract: l2BridgeAddress[_chainId],
            mintValue: _mintValue, // l2 gas + l2 msg.Value the bridgehub will withdraw the mintValue from the base token bridge for gas
            l2Value: 0, // L2 msg.value, this contract doesn't support base token deposits or wrapping functionality, for direct deposits use bridgehub
            l2Calldata: _l2TxCalldata,
            l2GasLimit: _l2TxGasLimit,
            l2GasPerPubdataByteLimit: _l2TxGasPerPubdataByte,
            l1GasPriceConverted: tx.gasprice,
            factoryDeps: new bytes[](0),
            refundRecipient: _refundRecipient
        });

        l2TxHash = bridgehub.requestL2Transaction{value: msg.value}(request);
    }

    /// @notice used by bridgehub to aquire mintValue. If l2Tx fails refunds are sent to refundrecipient on L2
    /// we also use it to keep to track each chain's assets
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        address _prevMsgSender,
        address _l1Token,
        uint256 _amount
    ) public payable onlyBridgehub {
        require(msg.value == 0, "EB m.v > 0 b d.it"); // this bridge does not hold eth, the weth bridge does
        require(_amount != 0, "4T"); // empty deposit amount
        // #if ERC20_BRIDGE_IS_BASETOKEN_BRIDGE
        if (_prevMsgSender != address(this)) {
            // the bridge might be calling itself, in which case the funds are already in the contract. This only happens in testing, as we will not support the ERC20 contract as a base token bridge
            uint256 amount = _depositFunds(_prevMsgSender, IERC20(_l1Token), _amount);
            require(amount == _amount, "3T"); // The token has non-standard transfer logic
        }
        // #else
        uint256 amount = _depositFunds(_prevMsgSender, IERC20(_l1Token), _amount);
        require(amount == _amount, "3T"); // The token has non-standard transfer logic
        // #endif
        if (!hyperbridgingEnabled[_chainId]) {
            chainBalance[_chainId][_l1Token] += _amount;
        }
        // Note we don't save the deposited amount, as this is for the base token, which gets sent to the refundRecipient if the tx fails
    }

    /// @dev Transfers tokens from the depositor address to the smart contract address
    /// @return The difference between the contract balance before and after the transferring of funds
    function _depositFunds(address _from, IERC20 _token, uint256 _amount) internal returns (uint256) {
        uint256 balanceBefore = _token.balanceOf(address(this));
        _token.safeTransferFrom(_from, address(this), _amount);
        uint256 balanceAfter = _token.balanceOf(address(this));

        return balanceAfter - balanceBefore;
    }

    /// @notice used by requestL2TransactionTwoBridges in Bridgehub
    /// specifies called chainId and caller, and requested transaction in _data.
    /// currently we only support a single tx, depositing.
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable override onlyBridgehub returns (L2TransactionRequestTwoBridgesInner memory request) {
        (address _l1Token, uint256 _amount, address _l2Receiver) = abi.decode(_data, (address, uint256, address));
        require(msg.value == 0, "EB m.v > 0 for BH dep");
        require(l2BridgeAddress[_chainId] != address(0), "EB b. n dep");
        require(bridgehub.baseToken(_chainId) != _l1Token, "EB base d.it");

        require(_amount != 0, "6T"); // empty deposit amount
        uint256 amount = _depositFunds(_prevMsgSender, IERC20(_l1Token), _amount);
        require(amount == _amount, "5T"); // The token has non-standard transfer logic

        if (!hyperbridgingEnabled[_chainId]) {
            chainBalance[_chainId][_l1Token] += _amount;
        }
        bytes32 txDataHash = keccak256(abi.encode(_prevMsgSender, _l1Token, _amount));

        {
            // Request the finalization of the deposit on the L2 side
            bytes memory l2TxCalldata = _getDepositL2Calldata(msg.sender, _l2Receiver, _l1Token, _amount);

            request = L2TransactionRequestTwoBridgesInner({
                magicValue: TWO_BRIDGES_MAGIC_VALUE,
                l2Contract: l2BridgeAddress[_chainId],
                l2Calldata: l2TxCalldata,
                factoryDeps: new bytes[](0),
                txDataHash: txDataHash
            });
        }
        emit BridgehubDepositInitiatedSharedBridge(
            _chainId,
            txDataHash,
            _prevMsgSender,
            _l2Receiver,
            _l1Token,
            _amount
        );
        if (_chainId == ERA_CHAIN_ID) {
            // kl todo. Should emit this event here? Should we not allow this method for era?
            emit DepositInitiated(0, _prevMsgSender, _l2Receiver, _l1Token, _amount);
        }
    }

    /// @notice used by requestL2TransactionTwoBridges in Bridgehub
    /// used to confirm that the Mailbox has accepted a transaction.
    /// we can store the fact that the tx has happened using txDataHash and txHash
    function bridgehubConfirmL2Transaction(
        uint256 _chainId,
        bytes32 _txDataHash,
        bytes32 _txHash
    ) external override onlyBridgehub {
        require(depositHappened[_chainId][_txHash] == 0x00, "EB tx hap");
        depositHappened[_chainId][_txHash] = _txDataHash;
        emit BridgehubDepositFinalized(_chainId, _txDataHash, _txHash);
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
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization
    function claimFailedDeposit(
        uint256 _chainId,
        address _depositSender,
        address _l1Token,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) public nonReentrant {
        {
            bool proofValid = bridgehub.proveL1ToL2TransactionStatus(
                _chainId,
                _l2TxHash,
                _l2BatchNumber,
                _l2MessageIndex,
                _l2TxNumberInBatch,
                _merkleProof,
                TxStatus.Failure
            );
            require(proofValid, "yn");
        }
        require(_amount > 0, "y1");

        bytes32 txDataHash = keccak256(abi.encode(_depositSender, _l1Token, _amount));
        bool usingLegacyDepositAmountStorageVar = _checkDeposited(
            _chainId,
            _depositSender,
            _l1Token,
            txDataHash,
            _l2TxHash,
            _amount
        );

        if ((_chainId == ERA_CHAIN_ID) && usingLegacyDepositAmountStorageVar) {
            delete depositAmountEra[_depositSender][_l1Token][_l2TxHash];
        } else {
            delete depositHappened[_chainId][_l2TxHash];
        }
        if (!hyperbridgingEnabled[_chainId]) {
            // check that the chain has sufficient balance
            require(chainBalance[_chainId][_l1Token] >= _amount, "EB n funds");
            chainBalance[_chainId][_l1Token] -= _amount;
        }
        // Withdraw funds
        IERC20(_l1Token).safeTransfer(_depositSender, _amount);

        emit ClaimedFailedDepositSharedBridge(_chainId, _depositSender, _l1Token, _amount);
        if (_chainId == ERA_CHAIN_ID) {
            emit ClaimedFailedDeposit(_depositSender, _l1Token, _amount);
        }
    }

    /// @dev internal to avoid stack too deep error
    function _checkDeposited(
        uint256 _chainId,
        address _depositSender,
        address _l1Token,
        bytes32 _txDataHash,
        bytes32 _l2TxHash,
        uint256 _amount
    ) internal view returns (bool usingLegacyDepositAmountStorageVar) {
        if (_chainId == ERA_CHAIN_ID) {
            uint256 amount = depositAmountEra[_depositSender][_l1Token][_l2TxHash];
            if (amount > 0) {
                usingLegacyDepositAmountStorageVar = true;
                require(_amount == amount, "EB w amnt");
            } else {
                bytes32 dataHash = depositHappened[_chainId][_l2TxHash];
                require(dataHash == _txDataHash, "EB: d.it not hap");
            }
        } else {
            bytes32 dataHash = depositHappened[_chainId][_l2TxHash];
            require(dataHash == _txDataHash, "EB w d.it 2"); // wrong/invalid deposit
        }
    }

    /// @notice Finalize the withdrawal and release funds
    /// @param _l2BatchNumber The L2 batch number where the withdrawal was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization
    function finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) public nonReentrant {
        if (_chainId == ERA_CHAIN_ID) {
            require(!isWithdrawalFinalizedEra[_l2BatchNumber][_l2MessageIndex], "pw");
        } else {
            require(!isWithdrawalFinalizedShared[_chainId][_l2BatchNumber][_l2MessageIndex], "pw2");
        }

        (address l1Receiver, address l1Token, uint256 amount) = _checkWithdrawal(
            _chainId,
            _l2BatchNumber,
            _l2MessageIndex,
            _l2TxNumberInBatch,
            _message,
            _merkleProof
        );

        if (!hyperbridgingEnabled[_chainId]) {
            // Check that the chain has sufficient balance
            require(chainBalance[_chainId][l1Token] >= amount, "EB n funds 2"); // not enought funds
            chainBalance[_chainId][l1Token] -= amount;
        }

        if (_chainId == ERA_CHAIN_ID) {
            isWithdrawalFinalizedEra[_l2BatchNumber][_l2MessageIndex] = true;
        } else {
            isWithdrawalFinalizedShared[_chainId][_l2BatchNumber][_l2MessageIndex] = true;
        }

        // Withdraw funds
        IERC20(l1Token).safeTransfer(l1Receiver, amount);

        if (_chainId == ERA_CHAIN_ID) {
            emit WithdrawalFinalized(l1Receiver, l1Token, amount);
        }
        emit WithdrawalFinalizedSharedBridge(_chainId, l1Receiver, l1Token, amount);
    }

    /// @dev check that the withdrawal is valid
    function _checkWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) internal view returns (address l1Receiver, address l1Token, uint256 amount) {
        (l1Receiver, l1Token, amount) = _parseL2WithdrawalMessage(_chainId, _message);
        address l2Sender;
        {
            bool thisIsBaseTokenBridge = (bridgehub.baseTokenBridge(_chainId) == address(this)) &&
                (l1Token == bridgehub.baseToken(_chainId));
            l2Sender = thisIsBaseTokenBridge ? L2_ETH_TOKEN_SYSTEM_CONTRACT_ADDR : l2BridgeAddress[_chainId];
        }
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: _l2TxNumberInBatch,
            sender: l2Sender,
            data: _message
        });

        // Preventing the stack too deep error
        {
            bool success = bridgehub.proveL2MessageInclusion(
                _chainId,
                _l2BatchNumber,
                _l2MessageIndex,
                l2ToL1Message,
                _merkleProof
            );
            require(success, "EB withd w pf"); // withdrawal wrong proof
        }
    }

    function _parseL2WithdrawalMessage(
        uint256 _chainId,
        bytes memory _l2ToL1message
    ) internal view returns (address l1Receiver, address l1Token, uint256 amount) {
        // We check that the message is long enough to read the data.
        // Please note that there are two versions of the message:
        // 1. The message that is sent by `withdraw(address _l1Receiver)`
        // It should be equal to the length of the bytes4 function signature + address l1Receiver + uint256 amount = 4 + 20 + 32 = 56 (bytes).
        // 2. The message that is sent by `withdrawWithMessage(address _l1Receiver, bytes calldata _additionalData)`
        // It should be equal to the length of the following:
        // bytes4 function signature + address l1Receiver + uint256 amount + address l2Sender + bytes _additionalData =
        // = 4 + 20 + 32 + 32 + _additionalData.length >= 68 (bytes).

        // So the data is expected to be at least 56 bytes long.
        require(_l2ToL1message.length >= 56, "EB w msg len"); // wrong messsage length

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        if (bytes4(functionSignature) == IMailbox.finalizeEthWithdrawal.selector) {
            // this message is a base token withdrawal
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);
            l1Token = bridgehub.baseToken(_chainId);
        } else if (bytes4(functionSignature) == IL1BridgeLegacy.finalizeWithdrawal.selector) {
            // We use the IL1BridgeLegacy for backward compatibility with old withdrawals.

            // this message is a token withdrawal

            // Check that the message length is correct.
            // It should be equal to the length of the function signature + address + address + uint256 = 4 + 20 + 20 + 32 =
            // 76 (bytes).
            require(_l2ToL1message.length == 76, "kk");
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (l1Token, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);
        } else {
            revert("W msg f slctr");
        }
    }

    /// @return The address of the L2 token that would be minted for the deposit of the given L1 token on the hyperchain with specified chain ID. 
    /// Note, Returns zero address if the hyperchain with specified chain ID isn't supported by the bridge.
    function l2TokenAddressSharedBridge(uint256 _chainId, address _l1Token) public view returns (address) {
        address l2TokenBeaconAddr = l2TokenBeaconAddress[_chainId];
        address l2BridgeAddr = l2BridgeAddress[_chainId];

        // Returns early if the L2 bridge or L2 beacon hasn't been set by the owner.
        if (l2TokenBeaconAddr == address(0) || l2BridgeAddr == address(0)) {
            return address(0);
        }

        bytes32 constructorInputHash = keccak256(abi.encode(address(l2TokenBeaconAddr), ""));
        bytes32 salt = bytes32(uint256(uint160(_l1Token)));

        return L2ContractHelper.computeCreate2Address(l2BridgeAddr, salt, l2TokenProxyBytecodeHash, constructorInputHash);
    }

    /*//////////////////////////////////////////////////////////////
                            ERA LEGACY GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Legacy function gives the l2Bridge address on Era.
    function l2Bridge() external view override returns (address) {
        return l2BridgeAddress[ERA_CHAIN_ID];
    }

    /// @dev Legacy getter function gives the l2TokenBeacon address on Era.
    function l2TokenBeacon() external view override returns (address) {
        return l2TokenBeaconAddress[ERA_CHAIN_ID];
    }

    /// @return The L2 token address that would be minted for deposit of the given L1 token on zkSync Era.
    function l2TokenAddress(address _l1Token) public view returns (address) {
        bytes32 constructorInputHash = keccak256(abi.encode(address(l2TokenBeaconAddress[ERA_CHAIN_ID]), ""));
        bytes32 salt = bytes32(uint256(uint160(_l1Token)));

        return
            L2ContractHelper.computeCreate2Address(
                l2BridgeAddress[ERA_CHAIN_ID],
                salt,
                l2TokenProxyBytecodeHash,
                constructorInputHash
            );
    }

    /// @dev Legacy getter function gives the state of a withdrawal from Era.
    function isWithdrawalFinalized(uint256 _l2BatchNumber, uint256 _l2MessageIndex) external view returns (bool) {
        return isWithdrawalFinalizedEra[_l2BatchNumber][_l2MessageIndex];
    }

    /// @dev Legacy getter function used for saving the number of deposited funds, to claim them in case the deposit transaction fails.
    function depositAmount(
        address _account,
        address _l1Token,
        bytes32 _depositL2TxHash
    ) external view returns (uint256 amount) {
        return depositAmountEra[_account][_l1Token][_depositL2TxHash];
    }

    /*//////////////////////////////////////////////////////////////
                            ERA LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Legacy deposit method with refunding the fee to the caller, use another `deposit` method instead.
    /// @dev Initiates a deposit by locking funds on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted.
    /// @dev If the token is bridged for the first time, the L2 token contract will be deployed. Note however, that the
    /// newly-deployed token does not support any custom logic, i.e. rebase tokens' functionality is not supported.
    /// @param _l2Receiver The account address that should receive funds on L2
    /// @param _l1Token The L1 token address which is deposited
    /// @param _amount The total amount of tokens to be bridged
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction
    /// @return l2TxHash The L2 transaction hash of deposit finalization
    /// NOTE: the function doesn't use `nonreentrant` modifier, because the inner method does.
    function deposit(
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte
    ) external payable returns (bytes32 l2TxHash) {
        l2TxHash = deposit(
            ERA_CHAIN_ID,
            _l2Receiver,
            _l1Token,
            msg.value,
            _amount,
            _l2TxGasLimit,
            _l2TxGasPerPubdataByte,
            address(0)
        );
    }

    /// @notice Legacy deposit method with no chainId, use another `deposit` method instead.
    /// @dev Initiates a deposit by locking funds on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted
    /// @param _l2Receiver The account address that should receive funds on L2
    /// @param _l1Token The L1 token address which is deposited
    /// @param _amount The total amount of tokens to be bridged
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction
    /// @return l2TxHash The L2 transaction hash of deposit finalization
    /// @param _refundRecipient The address on L2 that will receive the refund for the transaction.
    /// NOTE: the function doesn't use `nonreentrant` modifier, because the inner method does.
    function deposit(
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable returns (bytes32 l2TxHash) {
        l2TxHash = deposit(
            ERA_CHAIN_ID,
            _l2Receiver,
            _l1Token,
            msg.value,
            _amount,
            _l2TxGasLimit,
            _l2TxGasPerPubdataByte,
            _refundRecipient
        );
    }

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2
    /// @param _depositSender The address of the deposit initiator
    /// @param _l1Token The address of the deposited L1 ERC20 token
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization
    function claimFailedDeposit(
        address _depositSender,
        address _l1Token,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external {
        claimFailedDeposit(
            ERA_CHAIN_ID,
            _depositSender,
            _l1Token,
            depositAmountEra[_depositSender][_l1Token][_l2TxHash],
            _l2TxHash,
            _l2BatchNumber,
            _l2MessageIndex,
            _l2TxNumberInBatch,
            _merkleProof
        );
    }

    function finalizeWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external {
        finalizeWithdrawal(
            ERA_CHAIN_ID,
            _l2BatchNumber,
            _l2MessageIndex,
            _l2TxNumberInBatch,
            _message,
            _merkleProof
        );
    }
}
