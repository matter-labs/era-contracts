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

    /// @dev The address of the WETH token on L1
    address payable public immutable override l1WethAddress;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication
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

    /// @dev The address that is used as a beacon for L2 tokens in zkSync Era.
    address internal l2TokenBeacon;

    /// @notice Stores the hash of the L2 token proxy contract's bytecode. 
    /// @dev L2 token proxy bytecode is the same for all hyperchains and the owner can NOT override this value for a custom hyperchain.
    /// kl todo this is wrong Vlad. L2TokenProxy is just used for Era, for the l2TokenAddressLegacy function.
    bytes32 public l2TokenProxyBytecodeHash;

    /// @dev Deprecated storage variable related to withdrawal limitations.
    mapping(address => uint256) private __DEPRECATED_lastWithdrawalLimitReset;

    /// @dev Deprecated storage variable related to withdrawal limitations.
    mapping(address => uint256) private __DEPRECATED_withdrawnAmountInWindow;

    /// @dev Deprecated storage variable related to deposit limitations.
    mapping(address => mapping(address => uint256)) private __DEPRECATED_totalDepositedAmountPerUser;
    
    /// new fields from here

    /// @dev we need to switch over from the diamondProxy Storage's isWithdrawalFinalized to this one for era
    /// we first deploy the new Mailbox facet, then transfer the Eth, then deploy this.
    /// this number is the first batch number that is settled on Era ST Diamond  before we update the Mailbox,
    /// as withdrawals from batches older than this might already be finalized
    uint256 internal eraIsEthWithdrawalFinalizedStorageSwitchBatchNumber;

    /// @dev A mapping chainId => bridgeProxy. Used to store the bridge proxy's address, and to see if it has been deployed yet.
    mapping(uint256 chainId => address l2Bridge) public override l2BridgeAddress;

    /// @dev A mapping chainId => L2 deposit transaction hash  => keccak256(account, tokenAddress, amount)
    /// @dev Used for saving the number of deposited funds, to claim them in case the deposit transaction will fail.
    /// @dev the l2TxHash is unique, as it is determined by the contracts, while dataHash is not, so we that is the output.
    mapping(uint256 chainId => mapping(bytes32 l2DepositTxHash => bytes32 depositDataHash)) public override depositHappened;

    /// @dev A mapping L2 _chainId => Batch number => message number => flag
    /// @dev Used to indicate that L2 -> L1 message was already processed
    mapping(uint256 chainId=> mapping(uint256 l2BatchNumber => mapping(uint256 l2ToL1MessageNumber => bool isFinalized)))
    public isWithdrawalFinalizedShared;

    /// @dev Used for extra security until hyperbridging is implemented.
    mapping(uint256 chainId=> mapping(address l1Token => uint256 balance)) internal chainBalance;

    /// @dev Indicates whether the hyperbridging is enabled for a given chain.
    mapping(uint256 chainId => bool enabled) internal hyperbridgingEnabled;

    /// @return The L2 token address that would be minted for deposit of the given L1 token
    function l2TokenAddress(address _l1Token) public view returns (address) {
        bytes32 constructorInputHash = keccak256(abi.encode(address(l2TokenBeacon), ""));
        bytes32 salt = bytes32(uint256(uint160(_l1Token)));

        return
            L2ContractHelper.computeCreate2Address(
                l2BridgeAddress[ERA_CHAIN_ID],
                salt,
                l2TokenProxyBytecodeHash,
                constructorInputHash
            );
    }

    /// @notice Checks that the message sender is the governor
    modifier onlyBridgehub() {
        require(msg.sender == address(bridgehub), "EB not BH");
        _;
    }

    /// @notice Checks that the message sender is the bridgehub or an Eth based Chain
    modifier onlyBridgehubOrEthChain(uint256 _chainId) {
        require(
            (msg.sender == address(bridgehub)) ||
                ((bridgehub.baseToken(_chainId) == ETH_TOKEN_ADDRESS) &&
                    msg.sender == bridgehub.getStateTransition(_chainId)),
            "L1WETHBridge: not bridgehub or eth chain"
        );
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(address payable _l1WethAddress, IBridgehub _bridgehub) reentrancyGuardInitializer {
        l1WethAddress = _l1WethAddress;
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
        address _owner,
        uint256 _eraIsWithdrawalFinalizedStorageSwitchBatchNumber
    ) external reinitializer(2) {
        _transferOwnership(_owner);
        require(_owner != address(0), "EB owner 0");

        eraIsWithdrawalFinalizedStorageSwitchBatchNumber = _eraIsWithdrawalFinalizedStorageSwitchBatchNumber;

        l2BridgeAddress[ERA_CHAIN_ID] = ERA_ERC20_BRIDGE_ADDRESS;
        l2TokenBeacon = ERA_TOKEN_BEACON_ADDRESS;
    }

    /// @dev Initializes governance settings for a specific chain by setting the addresses of the L2 bridge and the L2 token beacon. 
    /// @dev This function is designed to configure special or custom bridges that are not deployed through this contract.
    /// It opens the integration of unique bridging solutions across different chains.
    function initializeChainGovernance(
        uint256 _chainId,
        address _l2BridgeAddress
    ) external onlyOwner {
        l2BridgeAddress[_chainId] = _l2BridgeAddress;
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
        uint256 l2Value;
        {
            bool ethIsBaseToken = (bridgehub.baseToken(_chainId) == ETH_TOKEN_ADDRESS);
            require(ethIsBaseToken, "EB d.it n E chain");
            if (_l1Token == l1WethAddress) {
                require(msg.value + _amount == _mintValue, "EB wrong ETH sent weth d.it");
                l2Value =  _amount;
                // we don't increase chainBalance in this case since we do it in bridgehubDepositBaseToken
            } else {
                require(_mintValue == msg.value, "EB w mintV");
                l2Value = 0;

                if (!hyperbridgingEnabled[_chainId]) {
                    chainBalance[_chainId][_l1Token] += _amount;
                }
            }

            require(_amount != 0, "2T"); // empty deposit amount
            uint256 amount = _depositFunds(msg.sender, _l1Token, _amount);
            require(amount == _amount, "1T"); // The token has non-standard transfer logic


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
            l2Value,
            l2TxCalldata,
            _l2TxGasLimit,
            _l2TxGasPerPubdataByte,
            refundRecipient
        );

        // for weth we don't save the depositHappened, since funds are sent to refundRecipient on L2 if the tx fails
        if (_l1Token != l1WethAddress) {
            // Save the deposited amount to claim funds on L1 if the deposit failed on L2
            bytes32 txDataHash = keccak256(abi.encode(msg.sender, _l1Token, _amount));
            depositHappened[_chainId][l2TxHash] = txDataHash;
        }

        emit DepositInitiatedSharedBridge(_chainId, txDataHash, msg.sender, _l2Receiver, _l1Token, _amount);
        if (_chainId == ERA_CHAIN_ID) {
            emit DepositInitiated(l2TxHash, msg.sender, _l2Receiver, _l1Token, _amount);
        }
    }

    /// @dev internal to avoid stack too deep error. Only used for eth based chains
    function _depositSendTx(
        uint256 _chainId,
        uint256 _mintValue,
        uint256 _l2Value,
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
            l2Value: _l2Value, // L2 msg.value, this contract doesn't support base token deposits or wrapping functionality, for direct deposits use bridgehub
            l2Calldata: _l2TxCalldata,
            l2GasLimit: _l2TxGasLimit,
            l2GasPerPubdataByteLimit: _l2TxGasPerPubdataByte,
            l1GasPriceConverted: tx.gasprice,
            factoryDeps: new bytes[](0),
            refundRecipient: _refundRecipient
        });

        l2TxHash = bridgehub.requestL2TransactionDirect{value: _mintValue}(request);
    }

    /// @notice used by bridgehub to aquire mintValue. If l2Tx fails refunds are sent to refundrecipient on L2
    /// we also use it to keep to track each chain's assets
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        address _prevMsgSender,
        address _l1Token,
        uint256 _amount
    ) public payable onlyBridgehubOrEthChain(_chainId) {
        require(_amount != 0, "4T"); // empty deposit amount

        if (_l1Token == ETH_TOKEN_ADDRESS){
            require(msg.value == _amount, "L1WETHBridge: msg.value not equal to amount");
        } else {
            /// This breaks the _depositeFunds function, it returns 0, as our balance doesn't increase 
            /// This should not happen, this bridge only calls the Bridgehub if Eth is the baseToken
            require(_prevMsgSender != address(this), "EB calling itself"); 
            
            // The Bridgehub also checks this, but we want to be sure
            require(msg.value == 0, "EB m.v > 0 b d.it"); 

        
            uint256 amount = _depositFunds(_prevMsgSender, _l1Token, _amount);
            require(amount == _amount, "3T"); // The token has non-standard transfer logic
        }

        if (!hyperbridgingEnabled[_chainId]) {
            chainBalance[_chainId][_l1Token] += _amount;
        }
        // Note we don't save the deposited amount, as this is for the base token, which gets sent to the refundRecipient if the tx fails
    }

    /// @dev Transfers tokens from the depositor address to the smart contract address
    /// @return The difference between the contract balance before and after the transferring of funds
    function _depositFunds(address _from, address _token, uint256 _amount) internal returns (uint256) {
        if (_token = l1WethAddress){
            // Deposit WETH tokens from the depositor address to the smart contract address
            uint256 balanceBefore = address(this).balance;
            IERC20(l1WethAddress).safeTransferFrom(msg.sender, address(this), _amount);
            // Unwrap WETH tokens (smart contract address receives the equivalent amount of ETH)
            IWETH9(l1WethAddress).withdraw(_amount);
            uint256 balanceAfter = address(this).balance;

            return balanceAfter - balanceBefore;
        } else {
            IERC20 token = IERC20(_token);
            uint256 balanceBefore = token.balanceOf(address(this));
            _token.safeTransferFrom(_from, address(this), _amount);
            uint256 balanceAfter = token.balanceOf(address(this));

            return balanceAfter - balanceBefore;
        }
    }

    /// @notice used by requestL2TransactionTwoBridges in Bridgehub
    /// specifies called chainId and caller, and requested transaction in _data.
    /// currently we only support a single tx, depositing.
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable override onlyBridgehub returns (L2TransactionRequestTwoBridgesInner memory request) {
        require(l2BridgeAddress[_chainId] != address(0), "EB b. n dep");
        require(bridgehub.baseToken(_chainId) != _l1Token, "EB base d.it"); // because we cannot change mintValue
        // currently depositing a token to a chain where it is the baseToken, and receiving a wrapped version of it is only supported for ether/weth
        // if we want to implement this then we need to change the deposit function and use requestL2TransactionDirect
        // until then we can requestL2TransactionDirect and receive the non-wrapped token on L2

        (address _l1Token, uint256 _withdrawAmount, address _l2Receiver) = abi.decode(_data, (address, uint256, address));
        if (_withdrawAmount != 0) {
            uint256 withdrawAmount = _depositFunds(_prevMsgSender, _l1Token, _withdrawAmount);
            require(withdrawAmount == _withdrawAmount, "5T"); // The token has non-standard transfer logic
        }

        uint256 amount;
        if ((_l1Token == ETH_TOKEN_ADDRESS) && (_l1Token == l1WethAddress)){
            amount = _withdrawAmount + msg.value;
        } else {
            require(msg.value == 0, "EB m.v > 0 for BH dep");
            amount = _withdrawAmount;
        }
        require(amount != 0, "6T"); // empty deposit amount

        if (!hyperbridgingEnabled[_chainId]) {
            chainBalance[_chainId][_l1Token] += amount;
        }
        bytes32 txDataHash = keccak256(abi.encode(_prevMsgSender, _l1Token, amount));

        {
            // Request the finalization of the deposit on the L2 side
            bytes memory l2TxCalldata = _getDepositL2Calldata(_prevMsgSender, _l2Receiver, _l1Token, amount);

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
            amount
        );
        // kl todo. We are breaking the previous events here, as we don't have the txHash, so we can't emit a DepositInitiated event
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
        if ((_token == ETH_TOKEN_ADDRESS) || (_token == l1WethAddress)) {
            return new bytes(0);
        }

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

        if (!hyperbridgingEnabled[_chainId]) {
            // check that the chain has sufficient balance
            require(chainBalance[_chainId][_l1Token] >= _amount, "EB n funds");
            chainBalance[_chainId][_l1Token] -= _amount;
        }

        if (usingLegacyDepositAmountStorageVar) {
            delete depositAmountEra[_depositSender][_l1Token][_l2TxHash];
        } else {
            delete depositHappened[_chainId][_l2TxHash];
        }

        // Withdraw funds
        if (_l1Token == ETH_TOKEN_ADDRESS) {
            payable(_depositSender).transfer(_amount);
        } else if (_l1Token == l1WethAddress) {
            // Wrap ETH to WETH tokens (smart contract address receives the equivalent _amount of WETH)
            IWETH9(l1WethAddress).deposit{value: _amount}();
            // Transfer WETH tokens from the smart contract address to the withdrawal receiver
            IERC20(l1WethAddress).safeTransfer(_depositSender, _amount);
        }
        else {
            IERC20(_l1Token).safeTransfer(_depositSender, _amount);
        }

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

        if ((_chainId == ERA_CHAIN_ID) && ((_l2BatchNumber < eraIsWithdrawalFinalizedStorageSwitchBatchNumber))) {
            // in this case we have to check we don't double withdraw ether
            // we are not fully finalized if eth has not been withdrawn
            // note the WETH bridge has not yet been deployed, so it cannot be the case that we withdrew Eth but not WETH.
            bool alreadyFinalized = IGetters(ERA_DIAMOND_PROXY).isEthWithdrawalFinalized(
                _l2BatchNumber,
                _l2MessageIndex
            );
            require(!alreadyFinalized, "Withdrawal is already finalized");
        }

        (address l1Receiver, address l1Token, uint256 amount, bool wrapToWeth) = _checkWithdrawal(
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

        if (wrapToWeth) {
            // Wrap ETH to WETH tokens (smart contract address receives the equivalent amount of WETH)
            IWETH9(l1WethAddress).deposit{value: amount}();
            // Transfer WETH tokens from the smart contract address to the withdrawal receiver
            IERC20(l1WethAddress).safeTransfer(l1WithdrawReceiver, amount);

            emit EthWithdrawalFinalized(_chainId, l1WithdrawReceiver, amount);
        } else if ((l1Token == ETH_TOKEN_ADDRESS) || (l1Token == l1WethAddress)) {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), l1WithdrawReceiver, amount, 0, 0, 0, 0)
            }
            require(callSuccess, "L1WB: withdraw failed");
            emit EthWithdrawalFinalized(_chainId, l1WithdrawReceiver, amount);
        } else {
            // Withdraw funds
            IERC20(l1Token).safeTransfer(l1Receiver, amount);

            if (_chainId == ERA_CHAIN_ID) {
                emit WithdrawalFinalized(l1Receiver, l1Token, amount);
            }
            emit WithdrawalFinalizedSharedBridge(_chainId, l1Receiver, l1Token, amount);
        }
    }

    /// @dev check that the withdrawal is valid
    function _checkWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) internal view returns (address l1Receiver, address l1Token, uint256 amount, bool wrapToWeth) {
        (l1Receiver, l1Token, amount, wrapToWeth) = _parseL2WithdrawalMessage(_chainId, _message);
        L2Message memory l2ToL1Message;
        {
            bool thisIsBaseTokenBridge = (bridgehub.baseTokenBridge(_chainId) == address(this)) &&
                (l1Token == bridgehub.baseToken(_chainId));
            address l2Sender = thisIsBaseTokenBridge ? L2_ETH_TOKEN_SYSTEM_CONTRACT_ADDR : l2BridgeAddress[_chainId];
            
            l2ToL1Message = L2Message({
                txNumberInBatch: _l2TxNumberInBatch,
                sender: l2Sender,
                data: _message
            });
        }
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
    ) internal view returns (address l1Receiver, address l1Token, uint256 amount, bool wrapToWeth) {
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

            if (l1Receiver == address(this)) {
                // the user either specified a wrong receiver (so the withdrawal cannot be finished), or the withdrawal is a weth withdrawal
                require((l1Token == ETH_TOKEN_ADDRESS) || (l1Token == l1WethAddress), "EB w eth w");
                wrapToWeth = true;

                // Check that the message length is correct.
                // additionalData (WETH withdrawal data): l2 sender address + weth receiver address = 20 + 20 = 40 (bytes)
                // It should be equal to the length of the function signature + eth receiver address + uint256 amount +
                // additionalData = 4 + 20 + 32 + 40 = 96 (bytes).
                require(_message.length == 96, "Incorrect ETH message with additional data length 2");

                address l2Sender;
                (l2Sender, offset) = UnsafeBytes.readAddress(_message, offset);
                require(l2Sender == l2BridgeAddress[_chainId], "The withdrawal was not initiated by L2 bridge");

                // Parse additional data
                (l1Receiver, offset) = UnsafeBytes.readAddress(_message, offset);
            }
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

    /// @dev The receive function is called when ETH is sent directly to the contract.
    receive() external payable {
        // Expected to receive ether in cases:
        // 1. l1 WETH sends ether on `withdraw`
        require(msg.sender == l1WethAddress, "pn");
        emit EthReceived(msg.value);
    }


    /*//////////////////////////////////////////////////////////////
                            ERA LEGACY GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Legacy function gives the l2Bridge address on Era.
    function l2Bridge() external view override returns (address) {
        return l2BridgeAddress[ERA_CHAIN_ID];
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
