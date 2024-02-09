// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IL1ERC20Bridge} from "./interfaces/IL1ERC20Bridge.sol";
import {IL1SharedBridge} from "./interfaces/IL1SharedBridge.sol";
import {IL2Bridge} from "./interfaces/IL2Bridge.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";

import {IMailbox} from "../state-transition/chain-interfaces/IMailbox.sol";
import {L2Message, TxStatus} from "../common/Messaging.sol";
import {UnsafeBytes} from "../common/libraries/UnsafeBytes.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {ERA_CHAIN_ID, ERA_ERC20_BRIDGE_ADDRESS, ETH_TOKEN_ADDRESS, ERA_DIAMOND_PROXY, TWO_BRIDGES_MAGIC_VALUE} from "../common/Config.sol";
import {IBridgehub, L2TransactionRequestTwoBridgesInner, L2TransactionRequestDirect} from "../bridgehub/IBridgehub.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "../common/L2ContractAddresses.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Smart contract that allows depositing ERC20 tokens from Ethereum to hyperchains
/// @dev It is standard implementation of ERC20 Bridge that can be used as a reference
/// for any other custom token bridges.
contract L1SharedBridge is IL1SharedBridge, ReentrancyGuard, Initializable, Ownable2Step {
    using SafeERC20 for IERC20;

    /// @dev The address of the WETH token on L1
    address payable public immutable override l1WethAddress;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication
    IBridgehub public immutable override bridgehub;

    /// @dev Legacy bridge smart contract that used to hold the tokens
    IL1ERC20Bridge public immutable override legacyBridge;

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
    mapping(uint256 chainId => mapping(bytes32 l2DepositTxHash => bytes32 depositDataHash))
        public
        override depositHappened;

    /// @dev A mapping L2 _chainId => Batch number => message number => flag
    /// @dev Used to indicate that L2 -> L1 message was already processed
    mapping(uint256 chainId => mapping(uint256 l2BatchNumber => mapping(uint256 l2ToL1MessageNumber => bool isFinalized)))
        public isWithdrawalFinalizedShared;

    /// @dev Used for extra security until hyperbridging is implemented.
    mapping(uint256 chainId => mapping(address l1Token => uint256 balance)) internal chainBalance;

    /// @dev Indicates whether the hyperbridging is enabled for a given chain.
    mapping(uint256 chainId => bool enabled) internal hyperbridgingEnabled;

    /// @notice Checks that the message sender is the bridgehub
    modifier onlyBridgehub() {
        require(msg.sender == address(bridgehub), "ShB not BH");
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

    /// @notice Checks that the message sender is the legacy bridge
    modifier onlyLegacyBridge() {
        require(msg.sender == address(legacyBridge), "ShB not legacy bridge");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(
        address payable _l1WethAddress,
        IBridgehub _bridgehub,
        IL1ERC20Bridge _legacyBridge
    ) reentrancyGuardInitializer {
        l1WethAddress = _l1WethAddress;
        bridgehub = _bridgehub;
        legacyBridge = _legacyBridge;
    }

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy
    /// @param _owner Address which can change L2 token implementation and upgrade the bridge
    /// implementation. The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge
    function initialize(
        address _owner,
        uint256 _eraIsEthWithdrawalFinalizedStorageSwitchBatchNumber
    ) external reentrancyGuardInitializer reinitializer(2) {
        _transferOwnership(_owner);
        require(_owner != address(0), "ShB owner 0");

        eraIsEthWithdrawalFinalizedStorageSwitchBatchNumber = _eraIsEthWithdrawalFinalizedStorageSwitchBatchNumber;

        l2BridgeAddress[ERA_CHAIN_ID] = ERA_ERC20_BRIDGE_ADDRESS;
    }

    /// @dev Initializes the l2Bridge address by governance for a specific chain
    function initializeChainGovernance(uint256 _chainId, address _l2BridgeAddress) external onlyOwner {
        l2BridgeAddress[_chainId] = _l2BridgeAddress;
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

        if (_l1Token == ETH_TOKEN_ADDRESS) {
            require(msg.value == _amount, "L1WETHBridge: msg.value not equal to amount");
        } else {
            /// This breaks the _depositeFunds function, it returns 0, as our balance doesn't increase
            /// This should not happen, this bridge only calls the Bridgehub if Eth is the baseToken or for wrapped base token deposits
            require(_prevMsgSender != address(this), "ShB calling itself");

            // The Bridgehub also checks this, but we want to be sure
            require(msg.value == 0, "ShB m.v > 0 b d.it");

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
        if (_token == l1WethAddress) {
            // Deposit WETH tokens from the depositor address to the smart contract address
            uint256 balanceBefore = address(this).balance;
            IERC20(l1WethAddress).safeTransferFrom(_from, address(this), _amount);
            // Unwrap WETH tokens (smart contract address receives the equivalent amount of ETH)
            IWETH9(l1WethAddress).withdraw(_amount);
            uint256 balanceAfter = address(this).balance;

            return balanceAfter - balanceBefore;
        } else {
            IERC20 token = IERC20(_token);
            uint256 balanceBefore = token.balanceOf(address(this));
            token.safeTransferFrom(_from, address(this), _amount);
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
        uint256 _l2Value,
        bytes calldata _data
    ) external payable override onlyBridgehub returns (L2TransactionRequestTwoBridgesInner memory request) {
        require(l2BridgeAddress[_chainId] != address(0), "ShB l2 bridge n deployed");

        (address _l1Token, uint256 _depositAmount, address _l2Receiver) = abi.decode(
            _data,
            (address, uint256, address)
        );
        if (_depositAmount != 0) {
            /// This breaks the _depositeFunds function, it returns 0, as we are withdrawing funds from ourselves, so our balance doesn't increase
            /// This should not happen, this bridge only calls the Bridgehub if Eth is the baseToken or for wrapped base token deposits
            require(_prevMsgSender != address(this), "ShB calling itself");

            uint256 withdrawAmount = _depositFunds(_prevMsgSender, _l1Token, _depositAmount);
            require(withdrawAmount == _depositAmount, "5T"); // The token has non-standard transfer logic
        }
        uint256 amount;
        bytes32 txDataHash;

        if (bridgehub.baseToken(_chainId) == _l1Token) {
            // we are depositing wrapped baseToken
            amount = _l2Value;
            require(msg.value == 0, "ShB m.v > 0 for BH d.it 1");
            require(_depositAmount == 0, "ShB wrong withdraw amount"); // there is no point in withdrawing now, the l2Value is already set
            txDataHash = 0x00; // we don't save for baseToken deposits, as the refundRecipient will receive the funds if the tx fails
        } else {
            if ((_l1Token == ETH_TOKEN_ADDRESS) || (_l1Token == l1WethAddress)) {
                amount = _depositAmount + msg.value;
            } else {
                require(msg.value == 0, "ShB m.v > 0 for BH d.it 2");
                amount = _depositAmount;
            }
            txDataHash = keccak256(abi.encode(_prevMsgSender, _l1Token, amount));
            if (!hyperbridgingEnabled[_chainId]) {
                chainBalance[_chainId][_l1Token] += amount;
            }
        }
        require(amount != 0, "6T"); // empty deposit amount

        {
            // Request the finalization of the deposit on the L2 side
            bytes memory l2TxCalldata = _getDepositL2Calldata(_chainId, _prevMsgSender, _l2Receiver, _l1Token, amount);

            request = L2TransactionRequestTwoBridgesInner({
                magicValue: TWO_BRIDGES_MAGIC_VALUE,
                l2Contract: l2BridgeAddress[_chainId],
                l2Calldata: l2TxCalldata,
                factoryDeps: new bytes[](0),
                txDataHash: txDataHash
            });
        }
        emit BridgehubDepositInitiatedSharedBridge(_chainId, txDataHash, _prevMsgSender, _l2Receiver, _l1Token, amount);
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
        if (_txDataHash != 0x00) {
            require(depositHappened[_chainId][_txHash] == 0x00, "ShB tx hap");
            depositHappened[_chainId][_txHash] = _txDataHash;
            emit BridgehubDepositFinalized(_chainId, _txDataHash, _txHash);
        }
    }

    /// @dev Generate a calldata for calling the deposit finalization on the L2 bridge contract
    function _getDepositL2Calldata(
        uint256 _chainId,
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount
    ) internal view returns (bytes memory txCalldata) {
        bytes memory gettersData;
        if (_l1Token == bridgehub.baseToken(_chainId)) {
            gettersData = new bytes(0);
        } else {
            gettersData = _getERC20Getters(_l1Token);
        }
        address l1Token = _l1Token == l1WethAddress ? ETH_TOKEN_ADDRESS : _l1Token;
        txCalldata = abi.encodeCall(IL2Bridge.finalizeDeposit, (_l1Sender, _l2Receiver, l1Token, _amount, gettersData));
    }

    /// @dev Receives and parses (name, symbol, decimals) from the token contract
    function _getERC20Getters(address _token) internal view returns (bytes memory data) {
        if ((_token == ETH_TOKEN_ADDRESS) || (_token == l1WethAddress)) {
            return abi.encode("Ether", "ETH", uint8(18)); // when depositing eth to a non-eth based chain
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
    ) public override {
        _claimFailedDeposit(
            false,
            _chainId,
            _depositSender,
            _l1Token,
            _amount,
            _l2TxHash,
            _l2BatchNumber,
            _l2MessageIndex,
            _l2TxNumberInBatch,
            _merkleProof
        );
    }

    function claimFailedDepositLegacyErc20Bridge(
        address _depositSender,
        address _l1Token,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) public override onlyLegacyBridge {
        _claimFailedDeposit(
            true,
            ERA_CHAIN_ID,
            _depositSender,
            _l1Token,
            _amount,
            _l2TxHash,
            _l2BatchNumber,
            _l2MessageIndex,
            _l2TxNumberInBatch,
            _merkleProof
        );
    }

    function _claimFailedDeposit(
        bool _checkedInLegacyBridge,
        uint256 _chainId,
        address _depositSender,
        address _l1Token,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) internal nonReentrant {
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

        {
            bool notCheckedInLegacyBridgeOrNewTransaction;
            {
                // Deposits that happened before the upgrade cannot be checked here, they have to be claimed and checked in the legacyBridge
                bool weCanCheckDepositHere = ((_chainId != ERA_CHAIN_ID) ||
                    (_l2BatchNumber >= eraIsEthWithdrawalFinalizedStorageSwitchBatchNumber));
                // Double claims are not possible, as we this check except for legacy bridge withdrawals
                // Funds claimed before the update will still be recorded in the legacy bridge
                // Note we double check NEW deposits if they are called from the legacy bridge
                notCheckedInLegacyBridgeOrNewTransaction = (!_checkedInLegacyBridge) || weCanCheckDepositHere;
            }
            if (notCheckedInLegacyBridgeOrNewTransaction) {
                bytes32 dataHash = depositHappened[_chainId][_l2TxHash];
                bytes32 txDataHash = keccak256(abi.encode(_depositSender, _l1Token, _amount));
                require(dataHash == txDataHash, "ShB: d.it not hap");
                delete depositHappened[_chainId][_l2TxHash];
            }
        }

        if (!hyperbridgingEnabled[_chainId]) {
            // check that the chain has sufficient balance
            require(chainBalance[_chainId][_l1Token] >= _amount, "ShB n funds");
            chainBalance[_chainId][_l1Token] -= _amount;
        }

        // Withdraw funds
        if (_l1Token == ETH_TOKEN_ADDRESS) {
            payable(_depositSender).transfer(_amount);
        } else if (_l1Token == l1WethAddress) {
            // Wrap ETH to WETH tokens (smart contract address receives the equivalent _amount of WETH)
            IWETH9(l1WethAddress).deposit{value: _amount}();
            // Transfer WETH tokens from the smart contract address to the withdrawal receiver
            IERC20(l1WethAddress).safeTransfer(_depositSender, _amount);
        } else {
            IERC20(_l1Token).safeTransfer(_depositSender, _amount);
        }

        emit ClaimedFailedDepositSharedBridge(_chainId, _depositSender, _l1Token, _amount);
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
    ) public override {
        // To avoid rewithdrawing txs that have already happened on the legacy bridge
        // note: new withdraws are all recorded here, so double withdrawing them is not possible
        bool legacyWithdrawal = (_chainId == ERA_CHAIN_ID) &&
            (_l2BatchNumber < eraIsEthWithdrawalFinalizedStorageSwitchBatchNumber);
        if (legacyWithdrawal) {
            require(!legacyBridge.isWithdrawalFinalized(_l2BatchNumber, _l2MessageIndex), "ShB: legacy withdrawal");
        }
        _finalizeWithdrawal(_chainId, _l2BatchNumber, _l2MessageIndex, _l2TxNumberInBatch, _message, _merkleProof);
    }

    function finalizeWithdrawalLegacyErc20Bridge(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) public override onlyLegacyBridge returns (address l1Receiver, address l1Token, uint256 amount) {
        return
            _finalizeWithdrawal(
                ERA_CHAIN_ID,
                _l2BatchNumber,
                _l2MessageIndex,
                _l2TxNumberInBatch,
                _message,
                _merkleProof
            );
    }

    struct MessageParams {
        uint256 l2BatchNumber;
        uint256 l2MessageIndex;
        uint16 l2TxNumberInBatch;
    }

    function _finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) internal nonReentrant returns (address l1Receiver, address l1Token, uint256 amount) {
        require(
            !isWithdrawalFinalizedShared[_chainId][_l2BatchNumber][_l2MessageIndex],
            "Withdrawal is already finalized"
        );
        isWithdrawalFinalizedShared[_chainId][_l2BatchNumber][_l2MessageIndex] = true;

        if ((_chainId == ERA_CHAIN_ID) && (_l2BatchNumber < eraIsEthWithdrawalFinalizedStorageSwitchBatchNumber)) {
            // in this case we have to check we don't double withdraw ether
            // we are not fully finalized if eth has not been withdrawn
            // note the WETH bridge has not yet been deployed, so it cannot be the case that we withdrew Eth but not WETH.
            bool alreadyFinalized = IGetters(ERA_DIAMOND_PROXY).isEthWithdrawalFinalized(
                _l2BatchNumber,
                _l2MessageIndex
            );
            require(!alreadyFinalized, "Withdrawal is already finalized 2");
        }

        bool wrapToWeth;

        {
            MessageParams memory messageParams = MessageParams({
                l2BatchNumber: _l2BatchNumber,
                l2MessageIndex: _l2MessageIndex,
                l2TxNumberInBatch: _l2TxNumberInBatch
            });

            (l1Receiver, l1Token, amount, wrapToWeth) = _checkWithdrawal(
                _chainId,
                messageParams,
                _message,
                _merkleProof
            );
        }

        if (!hyperbridgingEnabled[_chainId]) {
            // Check that the chain has sufficient balance
            require(chainBalance[_chainId][l1Token] >= amount, "ShB not enough funds 2"); // not enought funds
            chainBalance[_chainId][l1Token] -= amount;
        }

        if (wrapToWeth) {
            // Wrap ETH to WETH tokens (smart contract address receives the equivalent amount of WETH)
            IWETH9(l1WethAddress).deposit{value: amount}();
            // Transfer WETH tokens from the smart contract address to the withdrawal receiver
            IERC20(l1WethAddress).safeTransfer(l1Receiver, amount);

            emit EthWithdrawalFinalized(_chainId, l1Receiver, amount);
        } else if ((l1Token == ETH_TOKEN_ADDRESS) || (l1Token == l1WethAddress)) {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), l1Receiver, amount, 0, 0, 0, 0)
            }
            require(callSuccess, "ShB: withdraw failed");
            emit EthWithdrawalFinalized(_chainId, l1Receiver, amount);
        } else {
            // Withdraw funds
            IERC20(l1Token).safeTransfer(l1Receiver, amount);

            emit WithdrawalFinalizedSharedBridge(_chainId, l1Receiver, l1Token, amount);
        }
    }

    /// @dev check that the withdrawal is valid
    function _checkWithdrawal(
        uint256 _chainId,
        MessageParams memory _messageParams,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) internal view returns (address l1Receiver, address l1Token, uint256 amount, bool wrapToWeth) {
        (l1Receiver, l1Token, amount, wrapToWeth) = _parseL2WithdrawalMessage(_chainId, _message);
        L2Message memory l2ToL1Message;
        {
            bool baseTokenWithdrawal = (l1Token == bridgehub.baseToken(_chainId));
            address l2Sender = baseTokenWithdrawal ? L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR : l2BridgeAddress[_chainId];

            l2ToL1Message = L2Message({
                txNumberInBatch: _messageParams.l2TxNumberInBatch,
                sender: l2Sender,
                data: _message
            });
        }
        // Preventing the stack too deep error
        {
            bool success = bridgehub.proveL2MessageInclusion(
                _chainId,
                _messageParams.l2BatchNumber,
                _messageParams.l2MessageIndex,
                l2ToL1Message,
                _merkleProof
            );
            require(success, "ShB withd w proof"); // withdrawal wrong proof
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
        require(_l2ToL1message.length >= 56, "ShB wrong msg len"); // wrong messsage length

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        if (bytes4(functionSignature) == IMailbox.finalizeEthWithdrawal.selector) {
            // this message is a base token withdrawal
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);
            l1Token = bridgehub.baseToken(_chainId);

            if (l1Receiver == address(this)) {
                // the user either specified a wrong receiver (so the withdrawal cannot be finished),
                // or the withdrawal is a wrapped base token withdrawal. We assume the later.
                if ((l1Token == ETH_TOKEN_ADDRESS) || (l1Token == l1WethAddress)) {
                    wrapToWeth = true;
                }

                // Check that the message length is correct.
                // additionalData (WETH withdrawal data): l2 sender address + weth receiver address = 20 + 20 = 40 (bytes)
                // It should be equal to the length of the function signature + eth receiver address + uint256 amount +
                // additionalData = 4 + 20 + 32 + 40 = 96 (bytes).
                require(_l2ToL1message.length == 96, "Incorrect BaseToken message with additional data length 2");

                address l2Sender;
                (l2Sender, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
                require(l2Sender == l2BridgeAddress[_chainId], "The withdrawal was not initiated by L2 bridge");

                // Parse additional data
                (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            }
        } else if (bytes4(functionSignature) == IL1ERC20Bridge.finalizeWithdrawal.selector) {
            // We use the IL1ERC20Bridge for backward compatibility with old withdrawals.

            // this message is a token withdrawal

            // Check that the message length is correct.
            // It should be equal to the length of the function signature + address + address + uint256 = 4 + 20 + 20 + 32 =
            // 76 (bytes).
            require(_l2ToL1message.length == 76, "kk");
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (l1Token, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);
            // this is for withdrawals from weth bridged to Era via the legacy ERC20Bridge.
            if (l1Token == l1WethAddress) {
                wrapToWeth = true;
            }
        } else {
            revert("ShB Incorrect message function selector");
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
                            ERA LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
    function depositLegacyErc20Bridge(
        address _msgSender,
        address _l2Receiver,
        address _l1Token,
        uint256 _mintValue,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) public payable override onlyLegacyBridge nonReentrant returns (bytes32 l2TxHash) {
        require(_amount != 0, "2T"); // empty deposit amount
        require(l2BridgeAddress[ERA_CHAIN_ID] != address(0), "ShB b. n dep");
        uint256 l2Value;
        {
            bool ethIsBaseToken = (bridgehub.baseToken(ERA_CHAIN_ID) == ETH_TOKEN_ADDRESS);
            require(ethIsBaseToken, "ShB d.it n E chain");
            if (_l1Token == l1WethAddress) {
                require(msg.value + _amount == _mintValue, "ShB wrong ETH sent weth d.it");
                l2Value = _amount;
                // we don't increase chainBalance in this case since we do it in bridgehubDepositBaseToken
            } else {
                require(_mintValue == msg.value, "ShB w mintV");
                l2Value = 0;

                if (!hyperbridgingEnabled[ERA_CHAIN_ID]) {
                    chainBalance[ERA_CHAIN_ID][_l1Token] += _amount;
                }
            }

            /// we don't deposit the funds here, as we did that in the legacy bridge
            /// we do need to unwrap weth though
            if (_l1Token == l1WethAddress) {
                uint256 balanceBefore = address(this).balance;
                // Unwrap WETH tokens (smart contract address receives the equivalent amount of ETH)
                IWETH9(l1WethAddress).withdraw(_amount);
                uint256 balanceAfter = address(this).balance;
                require(balanceAfter - balanceBefore == _amount, "ShB: w eth w");
            }
        }
        bytes memory l2TxCalldata = _getDepositL2Calldata(ERA_CHAIN_ID, _msgSender, _l2Receiver, _l1Token, _amount);

        {
            // If the refund recipient is not specified, the refund will be sent to the sender of the transaction.
            // Otherwise, the refund will be sent to the specified address.
            // If the recipient is a contract on L1, the address alias will be applied.
            address refundRecipient = _refundRecipient;
            if (_refundRecipient == address(0)) {
                refundRecipient = _msgSender != tx.origin
                    ? AddressAliasHelper.applyL1ToL2Alias(_msgSender)
                    : _msgSender;
            }

            l2TxHash = _depositSendTx(
                ERA_CHAIN_ID,
                _mintValue,
                l2Value,
                l2TxCalldata,
                _l2TxGasLimit,
                _l2TxGasPerPubdataByte,
                refundRecipient
            );
        }

        // for weth we don't save the depositHappened, since funds are sent to refundRecipient on L2 if the tx fails
        if (_l1Token != l1WethAddress) {
            bytes32 txDataHash = keccak256(abi.encode(_msgSender, _l1Token, _amount));
            // Save the deposited amount to claim funds on L1 if the deposit failed on L2
            depositHappened[ERA_CHAIN_ID][l2TxHash] = txDataHash;
        }

        emit DepositInitiatedSharedBridge(ERA_CHAIN_ID, l2TxHash, _msgSender, _l2Receiver, _l1Token, _amount);
    }

    /// @dev internal to avoid stack too deep error. Only used for Era legacy bridge deposits
    function _depositSendTx(
        uint256 _chainId,
        uint256 _mintValue,
        uint256 _l2Value,
        bytes memory _l2TxCalldata,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) internal returns (bytes32 l2TxHash) {
        L2TransactionRequestDirect memory request = L2TransactionRequestDirect({
            chainId: _chainId,
            l2Contract: l2BridgeAddress[_chainId],
            mintValue: _mintValue, // l2 gas + l2 msg.Value the bridgehub will withdraw the mintValue from the base token bridge for gas
            l2Value: _l2Value, // L2 msg.value, this contract doesn't support base token deposits or wrapping functionality, for direct deposits use bridgehub
            l2Calldata: _l2TxCalldata,
            l2GasLimit: _l2TxGasLimit,
            l2GasPerPubdataByteLimit: _l2TxGasPerPubdataByte,
            l1GasPriceConverted: 0,
            factoryDeps: new bytes[](0),
            refundRecipient: _refundRecipient
        });

        l2TxHash = bridgehub.requestL2TransactionDirect{value: _mintValue}(request);
    }
}
