// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IL1ERC20Bridge} from "./interfaces/IL1ERC20Bridge.sol";
import {IL1SharedBridge} from "./interfaces/IL1SharedBridge.sol";
import {IL2Bridge} from "./interfaces/IL2Bridge.sol";

import {IMailbox} from "../state-transition/chain-interfaces/IMailbox.sol";
import {L2Message, TxStatus} from "../common/Messaging.sol";
import {UnsafeBytes} from "../common/libraries/UnsafeBytes.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {ETH_TOKEN_ADDRESS, TWO_BRIDGES_MAGIC_VALUE} from "../common/Config.sol";
import {IBridgehub, L2TransactionRequestTwoBridgesInner, L2TransactionRequestDirect} from "../bridgehub/IBridgehub.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "../common/L2ContractAddresses.sol";
import {Unauthorized, ZeroAddress, SharedBridgeValueAlreadySet, SharedBridgeKey, NoFundsTransferred, ZeroBalance, ValueMismatch, TokensWithFeesNotSupported, NonEmptyMsgValue, L2BridgeNotSet, TokenNotSupported, DepositIncorrectAmount, EmptyDeposit, DepositExists, AddressAlreadyUsed, InvalidProof, DepositDoesNotExist, InsufficientChainBalance, SharedBridgeValueNotSet, WithdrawalAlreadyFinalized, WithdrawFailed, L2WithdrawalMessageWrongLength, InvalidSelector, SharedBridgeBalanceMismatch, SharedBridgeValueNotSet} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and hyperchains, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
contract L1SharedBridge is IL1SharedBridge, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev The address of the WETH token on L1.
    address public immutable override L1_WETH_TOKEN;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @dev Era's chainID
    uint256 internal immutable ERA_CHAIN_ID;

    /// @dev The address of zkSync Era diamond proxy contract.
    address internal immutable ERA_DIAMOND_PROXY;

    /// @dev Stores the first batch number on the zkSync Era Diamond Proxy that was settled after Diamond proxy upgrade.
    /// This variable is used to differentiate between pre-upgrade and post-upgrade Eth withdrawals. Withdrawals from batches older
    /// than this value are considered to have been finalized prior to the upgrade and handled separately.
    uint256 internal eraPostDiamondUpgradeFirstBatch;

    /// @dev Stores the first batch number on the zkSync Era Diamond Proxy that was settled after L1ERC20 Bridge upgrade.
    /// This variable is used to differentiate between pre-upgrade and post-upgrade ERC20 withdrawals. Withdrawals from batches older
    /// than this value are considered to have been finalized prior to the upgrade and handled separately.
    uint256 internal eraPostLegacyBridgeUpgradeFirstBatch;

    /// @dev Stores the zkSync Era batch number that processes the last deposit tx initiated by the legacy bridge
    /// This variable (together with eraLegacyBridgeLastDepositTxNumber) is used to differentiate between pre-upgrade and post-upgrade deposits. Deposits processed in older batches
    /// than this value are considered to have been processed prior to the upgrade and handled separately.
    /// We use this both for Eth and erc20 token deposits, so we need to update the diamond and bridge simultaneously.
    uint256 internal eraLegacyBridgeLastDepositBatch;

    /// @dev The tx number in the _eraLegacyBridgeLastDepositBatch of the last deposit tx initiated by the legacy bridge
    /// This variable (together with eraLegacyBridgeLastDepositBatch) is used to differentiate between pre-upgrade and post-upgrade deposits. Deposits processed in older txs
    /// than this value are considered to have been processed prior to the upgrade and handled separately.
    /// We use this both for Eth and erc20 token deposits, so we need to update the diamond and bridge simultaneously.
    uint256 internal eraLegacyBridgeLastDepositTxNumber;

    /// @dev Legacy bridge smart contract that used to hold ERC20 tokens.
    IL1ERC20Bridge public override legacyBridge;

    /// @dev A mapping chainId => bridgeProxy. Used to store the bridge proxy's address, and to see if it has been deployed yet.
    mapping(uint256 chainId => address l2Bridge) public override l2BridgeAddress;

    /// @dev A mapping chainId => L2 deposit transaction hash => keccak256(abi.encode(account, tokenAddress, amount))
    /// @dev Tracks deposit transactions from L2 to enable users to claim their funds if a deposit fails.
    mapping(uint256 chainId => mapping(bytes32 l2DepositTxHash => bytes32 depositDataHash))
        public
        override depositHappened;

    /// @dev Tracks the processing status of L2 to L1 messages, indicating whether a message has already been finalized.
    mapping(uint256 chainId => mapping(uint256 l2BatchNumber => mapping(uint256 l2ToL1MessageNumber => bool isFinalized)))
        public isWithdrawalFinalized;

    /// @dev Indicates whether the hyperbridging is enabled for a given chain.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 chainId => bool enabled) internal hyperbridgingEnabled;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across hyperchains.
    /// This serves as a security measure until hyperbridging is implemented.
    /// NOTE: this function may be removed in the future, don't rely on it!
    mapping(uint256 chainId => mapping(address l1Token => uint256 balance)) public chainBalance;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridgehub() {
        if (msg.sender != address(BRIDGE_HUB)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Checks that the message sender is the bridgehub or zkSync Era Diamond Proxy.
    modifier onlyBridgehubOrEra(uint256 _chainId) {
        if (msg.sender != address(BRIDGE_HUB) && (_chainId != ERA_CHAIN_ID || msg.sender != ERA_DIAMOND_PROXY)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Checks that the message sender is the legacy bridge.
    modifier onlyLegacyBridge() {
        if (msg.sender != address(legacyBridge)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Checks that the message sender is the shared bridge itself.
    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(
        address _l1WethAddress,
        IBridgehub _bridgehub,
        uint256 _eraChainId,
        address _eraDiamondProxy
    ) reentrancyGuardInitializer {
        _disableInitializers();
        L1_WETH_TOKEN = _l1WethAddress;
        BRIDGE_HUB = _bridgehub;
        ERA_CHAIN_ID = _eraChainId;
        ERA_DIAMOND_PROXY = _eraDiamondProxy;
    }

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy
    /// @param _owner Address which can change L2 token implementation and upgrade the bridge
    /// implementation. The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge.
    function initialize(address _owner) external reentrancyGuardInitializer initializer {
        if (_owner == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(_owner);
    }

    /// @dev This sets the first post diamond upgrade batch for era, used to check old eth withdrawals
    /// @param _eraPostDiamondUpgradeFirstBatch The first batch number on the zkSync Era Diamond Proxy that was settled after diamond proxy upgrade.
    function setEraPostDiamondUpgradeFirstBatch(uint256 _eraPostDiamondUpgradeFirstBatch) external onlyOwner {
        if (eraPostDiamondUpgradeFirstBatch != 0) {
            revert SharedBridgeValueAlreadySet(SharedBridgeKey.PostUpgradeFirstBatch);
        }
        eraPostDiamondUpgradeFirstBatch = _eraPostDiamondUpgradeFirstBatch;
    }

    /// @dev This sets the first post upgrade batch for era, used to check old token withdrawals
    /// @param _eraPostLegacyBridgeUpgradeFirstBatch The first batch number on the zkSync Era Diamond Proxy that was settled after legacy bridge upgrade.
    function setEraPostLegacyBridgeUpgradeFirstBatch(uint256 _eraPostLegacyBridgeUpgradeFirstBatch) external onlyOwner {
        if (eraPostLegacyBridgeUpgradeFirstBatch != 0) {
            revert SharedBridgeValueAlreadySet(SharedBridgeKey.LegacyBridgeFirstBatch);
        }
        eraPostLegacyBridgeUpgradeFirstBatch = _eraPostLegacyBridgeUpgradeFirstBatch;
    }

    /// @dev This sets the first post upgrade batch for era, used to check old withdrawals
    /// @param _eraLegacyBridgeLastDepositBatch The the zkSync Era batch number that processes the last deposit tx initiated by the legacy bridge
    /// @param _eraLegacyBridgeLastDepositTxNumber The tx number in the _eraLegacyBridgeLastDepositBatch of the last deposit tx initiated by the legacy bridge
    function setEraLegacyBridgeLastDepositTime(
        uint256 _eraLegacyBridgeLastDepositBatch,
        uint256 _eraLegacyBridgeLastDepositTxNumber
    ) external onlyOwner {
        if (eraLegacyBridgeLastDepositBatch != 0) {
            revert SharedBridgeValueAlreadySet(SharedBridgeKey.LegacyBridgeLastDepositBatch);
        }
        if (eraLegacyBridgeLastDepositTxNumber != 0) {
            revert SharedBridgeValueAlreadySet(SharedBridgeKey.LegacyBridgeLastDepositTxn);
        }
        eraLegacyBridgeLastDepositBatch = _eraLegacyBridgeLastDepositBatch;
        eraLegacyBridgeLastDepositTxNumber = _eraLegacyBridgeLastDepositTxNumber;
    }

    /// @dev Transfer tokens from legacy erc20 bridge or mailbox and set chainBalance as part of migration process.
    /// @param _token The address of token to be transferred (address(1) for ether and contract address for ERC20).
    /// @param _target The hyperchain or bridge contract address from where to transfer funds.
    /// @param _targetChainId The chain ID of the corresponding hyperchain.
    function transferFundsFromLegacy(address _token, address _target, uint256 _targetChainId) external onlySelf {
        if (_token == ETH_TOKEN_ADDRESS) {
            uint256 balanceBefore = address(this).balance;
            IMailbox(_target).transferEthToSharedBridge();
            uint256 balanceAfter = address(this).balance;
            if (balanceAfter <= balanceBefore) {
                revert NoFundsTransferred();
            }
            chainBalance[_targetChainId][ETH_TOKEN_ADDRESS] =
                chainBalance[_targetChainId][ETH_TOKEN_ADDRESS] +
                balanceAfter -
                balanceBefore;
        } else {
            uint256 balanceBefore = IERC20(_token).balanceOf(address(this));
            uint256 legacyBridgeBalance = IERC20(_token).balanceOf(address(legacyBridge));
            if (legacyBridgeBalance == 0) {
                revert ZeroBalance();
            }
            IL1ERC20Bridge(_target).transferTokenToSharedBridge(_token);
            uint256 balanceAfter = IERC20(_token).balanceOf(address(this));
            if (balanceAfter - balanceBefore < legacyBridgeBalance) {
                revert SharedBridgeBalanceMismatch();
            }
            chainBalance[_targetChainId][_token] = chainBalance[_targetChainId][_token] + legacyBridgeBalance;
        }
    }

    /// @dev transfer tokens from legacy erc20 bridge or mailbox and set chainBalance as part of migration process.
    /// @dev Unlike `transferFundsFromLegacy` is provides a concrete limit on the gas used for the transfer and even if it will fail, it will not revert the whole transaction.
    function safeTransferFundsFromLegacy(
        address _token,
        address _target,
        uint256 _targetChainId,
        uint256 _gasPerToken
    ) external onlyOwner {
        try this.transferFundsFromLegacy{gas: _gasPerToken}(_token, _target, _targetChainId) {} catch {
            // A reasonable amount of gas will be provided to transfer the token.
            // If the transfer fails, we don't want to revert the whole transaction.
        }
    }

    /// @dev Accepts ether only from the hyperchain associated with the specified chain ID.
    /// @param _chainId The chain ID corresponding to the hyperchain allowed to send ether.
    function receiveEth(uint256 _chainId) external payable {
        if (BRIDGE_HUB.getHyperchain(_chainId) != msg.sender) {
            revert Unauthorized(msg.sender);
        }
    }

    /// @dev Initializes the l2Bridge address by governance for a specific chain.
    function initializeChainGovernance(uint256 _chainId, address _l2BridgeAddress) external onlyOwner {
        l2BridgeAddress[_chainId] = _l2BridgeAddress;
    }

    /// @notice Allows bridgehub to acquire mintValue for L1->L2 transactions.
    /// @dev If the corresponding L2 transaction fails, refunds are issued to a refund recipient on L2.
    /// @param _chainId The chain ID of the hyperchain to which deposit.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _l1Token The L1 token address which is deposited.
    /// @param _amount The total amount of tokens to be bridged.
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        address _prevMsgSender,
        address _l1Token,
        uint256 _amount
    ) external payable virtual onlyBridgehubOrEra(_chainId) whenNotPaused {
        if (_l1Token == ETH_TOKEN_ADDRESS) {
            if (msg.value != _amount) {
                revert ValueMismatch(_amount, msg.value);
            }
        } else {
            // The Bridgehub also checks this, but we want to be sure
            if (msg.value != 0) {
                revert NonEmptyMsgValue();
            }

            uint256 amount = _depositFunds(_prevMsgSender, IERC20(_l1Token), _amount); // note if _prevMsgSender is this contract, this will return 0. This does not happen.
            // The token has non-standard transfer logic
            if (amount != _amount) {
                revert TokensWithFeesNotSupported();
            }
        }

        if (!hyperbridgingEnabled[_chainId]) {
            chainBalance[_chainId][_l1Token] += _amount;
        }
        // Note that we don't save the deposited amount, as this is for the base token, which gets sent to the refundRecipient if the tx fails
        emit BridgehubDepositBaseTokenInitiated(_chainId, _prevMsgSender, _l1Token, _amount);
    }

    /// @dev Transfers tokens from the depositor address to the smart contract address.
    /// @return The difference between the contract balance before and after the transferring of funds.
    function _depositFunds(address _from, IERC20 _token, uint256 _amount) internal returns (uint256) {
        uint256 balanceBefore = _token.balanceOf(address(this));
        // slither-disable-next-line arbitrary-send-erc20
        _token.safeTransferFrom(_from, address(this), _amount);
        uint256 balanceAfter = _token.balanceOf(address(this));

        return balanceAfter - balanceBefore;
    }

    /// @notice Initiates a deposit transaction within Bridgehub, used by `requestL2TransactionTwoBridges`.
    /// @param _chainId The chain ID of the hyperchain to which deposit.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _l2Value The L2 `msg.value` from the L1 -> L2 deposit transaction.
    /// @param _data The calldata for the second bridge deposit.
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        // solhint-disable-next-line no-unused-vars
        uint256 _l2Value,
        bytes calldata _data
    )
        external
        payable
        override
        onlyBridgehub
        whenNotPaused
        returns (L2TransactionRequestTwoBridgesInner memory request)
    {
        if (l2BridgeAddress[_chainId] == address(0)) {
            revert L2BridgeNotSet(_chainId);
        }

        (address _l1Token, uint256 _depositAmount, address _l2Receiver) = abi.decode(
            _data,
            (address, uint256, address)
        );
        if (_l1Token == L1_WETH_TOKEN) {
            revert TokenNotSupported(L1_WETH_TOKEN);
        }
        if (BRIDGE_HUB.baseToken(_chainId) == _l1Token) {
            revert TokenNotSupported(_l1Token);
        }

        uint256 amount;
        if (_l1Token == ETH_TOKEN_ADDRESS) {
            amount = msg.value;
            if (_depositAmount != 0) {
                revert DepositIncorrectAmount(0, _depositAmount);
            }
        } else {
            if (msg.value != 0) {
                revert NonEmptyMsgValue();
            }
            amount = _depositAmount;

            uint256 depAmount = _depositFunds(_prevMsgSender, IERC20(_l1Token), _depositAmount);
            // The token has non-standard transfer logic
            if (depAmount != _depositAmount) {
                revert DepositIncorrectAmount(depAmount, _depositAmount);
            }
        }
        // empty deposit amount
        if (amount == 0) {
            revert EmptyDeposit();
        }

        bytes32 txDataHash = keccak256(abi.encode(_prevMsgSender, _l1Token, amount));
        if (!hyperbridgingEnabled[_chainId]) {
            chainBalance[_chainId][_l1Token] += amount;
        }

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
        emit BridgehubDepositInitiated({
            chainId: _chainId,
            txDataHash: txDataHash,
            from: _prevMsgSender,
            to: _l2Receiver,
            l1Token: _l1Token,
            amount: amount
        });
    }

    /// @notice Confirms the acceptance of a transaction by the Mailbox, as part of the L2 transaction process within Bridgehub.
    /// This function is utilized by `requestL2TransactionTwoBridges` to validate the execution of a transaction.
    /// @param _chainId The chain ID of the hyperchain to which confirm the deposit.
    /// @param _txDataHash The keccak256 hash of abi.encode(msgSender, l1Token, amount)
    /// @param _txHash The hash of the L1->L2 transaction to confirm the deposit.
    function bridgehubConfirmL2Transaction(
        uint256 _chainId,
        bytes32 _txDataHash,
        bytes32 _txHash
    ) external override onlyBridgehub whenNotPaused {
        if (depositHappened[_chainId][_txHash] != 0x00) {
            revert DepositExists();
        }
        depositHappened[_chainId][_txHash] = _txDataHash;
        emit BridgehubDepositFinalized(_chainId, _txDataHash, _txHash);
    }

    /// @dev Sets the L1ERC20Bridge contract address. Should be called only once.
    function setL1Erc20Bridge(address _legacyBridge) external onlyOwner {
        if (address(legacyBridge) != address(0)) {
            revert AddressAlreadyUsed(address(legacyBridge));
        }
        if (_legacyBridge == address(0)) {
            revert ZeroAddress();
        }
        legacyBridge = IL1ERC20Bridge(_legacyBridge);
    }

    /// @dev Generate a calldata for calling the deposit finalization on the L2 bridge contract
    function _getDepositL2Calldata(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount
    ) internal view returns (bytes memory) {
        bytes memory gettersData = _getERC20Getters(_l1Token);
        return abi.encodeCall(IL2Bridge.finalizeDeposit, (_l1Sender, _l2Receiver, _l1Token, _amount, gettersData));
    }

    /// @dev Receives and parses (name, symbol, decimals) from the token contract
    function _getERC20Getters(address _token) internal view returns (bytes memory) {
        if (_token == ETH_TOKEN_ADDRESS) {
            bytes memory name = bytes("Ether");
            bytes memory symbol = bytes("ETH");
            bytes memory decimals = abi.encode(uint8(18));
            return abi.encode(name, symbol, decimals); // when depositing eth to a non-eth based chain it is an ERC20
        }

        (, bytes memory data1) = _token.staticcall(abi.encodeCall(IERC20Metadata.name, ()));
        (, bytes memory data2) = _token.staticcall(abi.encodeCall(IERC20Metadata.symbol, ()));
        (, bytes memory data3) = _token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        return abi.encode(data1, data2, data3);
    }

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2
    /// @param _depositSender The address of the deposit initiator
    /// @param _l1Token The address of the deposited L1 ERC20 token
    /// @param _amount The amount of the deposit that failed.
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
    ) external override {
        _claimFailedDeposit({
            _checkedInLegacyBridge: false,
            _chainId: _chainId,
            _depositSender: _depositSender,
            _l1Token: _l1Token,
            _amount: _amount,
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: _merkleProof
        });
    }

    /// @dev Processes claims of failed deposit, whether they originated from the legacy bridge or the current system.
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
    ) internal nonReentrant whenNotPaused {
        {
            bool proofValid = BRIDGE_HUB.proveL1ToL2TransactionStatus({
                _chainId: _chainId,
                _l2TxHash: _l2TxHash,
                _l2BatchNumber: _l2BatchNumber,
                _l2MessageIndex: _l2MessageIndex,
                _l2TxNumberInBatch: _l2TxNumberInBatch,
                _merkleProof: _merkleProof,
                _status: TxStatus.Failure
            });
            if (!proofValid) {
                revert InvalidProof();
            }
        }
        if (_amount == 0) {
            revert NoFundsTransferred();
        }

        {
            bool notCheckedInLegacyBridgeOrWeCanCheckDeposit;
            {
                // Deposits that happened before the upgrade cannot be checked here, they have to be claimed and checked in the legacyBridge
                bool weCanCheckDepositHere = !_isEraLegacyDeposit(_chainId, _l2BatchNumber, _l2TxNumberInBatch);
                // Double claims are not possible, as depositHappened is checked here for all except legacy deposits (which have to happen through the legacy bridge)
                // Funds claimed before the update will still be recorded in the legacy bridge
                // Note we double check NEW deposits if they are called from the legacy bridge
                notCheckedInLegacyBridgeOrWeCanCheckDeposit = (!_checkedInLegacyBridge) || weCanCheckDepositHere;
            }
            if (notCheckedInLegacyBridgeOrWeCanCheckDeposit) {
                bytes32 dataHash = depositHappened[_chainId][_l2TxHash];
                bytes32 txDataHash = keccak256(abi.encode(_depositSender, _l1Token, _amount));
                if (dataHash != txDataHash) {
                    revert DepositDoesNotExist();
                }
                delete depositHappened[_chainId][_l2TxHash];
            }
        }

        if (!hyperbridgingEnabled[_chainId]) {
            // check that the chain has sufficient balance
            if (chainBalance[_chainId][_l1Token] < _amount) {
                revert InsufficientChainBalance();
            }
            chainBalance[_chainId][_l1Token] -= _amount;
        }

        // Withdraw funds
        if (_l1Token == ETH_TOKEN_ADDRESS) {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), _depositSender, _amount, 0, 0, 0, 0)
            }
            if (!callSuccess) {
                revert WithdrawFailed();
            }
        } else {
            IERC20(_l1Token).safeTransfer(_depositSender, _amount);
            // Note we don't allow weth deposits anymore, but there might be legacy weth deposits.
            // until we add Weth bridging capabilities, we don't wrap/unwrap weth to ether.
        }

        emit ClaimedFailedDepositSharedBridge(_chainId, _depositSender, _l1Token, _amount);
    }

    /// @dev Determines if an eth withdrawal was initiated on zkSync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the withdrawal.
    /// @return Whether withdrawal was initiated on zkSync Era before diamond proxy upgrade.
    function _isEraLegacyEthWithdrawal(uint256 _chainId, uint256 _l2BatchNumber) internal view returns (bool) {
        if ((_chainId == ERA_CHAIN_ID) && eraPostDiamondUpgradeFirstBatch == 0) {
            revert SharedBridgeValueNotSet(SharedBridgeKey.PostUpgradeFirstBatch);
        }
        return (_chainId == ERA_CHAIN_ID) && (_l2BatchNumber < eraPostDiamondUpgradeFirstBatch);
    }

    /// @dev Determines if a token withdrawal was initiated on zkSync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the withdrawal.
    /// @return Whether withdrawal was initiated on zkSync Era before Legacy Bridge upgrade.
    function _isEraLegacyTokenWithdrawal(uint256 _chainId, uint256 _l2BatchNumber) internal view returns (bool) {
        if ((_chainId == ERA_CHAIN_ID) && eraPostLegacyBridgeUpgradeFirstBatch == 0) {
            revert SharedBridgeValueNotSet(SharedBridgeKey.LegacyBridgeFirstBatch);
        }
        return (_chainId == ERA_CHAIN_ID) && (_l2BatchNumber < eraPostLegacyBridgeUpgradeFirstBatch);
    }

    /// @dev Determines if a deposit was initiated on zkSync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the deposit where it was processed.
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the deposit was processed.
    /// @return Whether deposit was initiated on zkSync Era before Shared Bridge upgrade.
    function _isEraLegacyDeposit(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2TxNumberInBatch
    ) internal view returns (bool) {
        if ((_chainId == ERA_CHAIN_ID) && (eraLegacyBridgeLastDepositBatch == 0)) {
            revert SharedBridgeValueNotSet(SharedBridgeKey.LegacyBridgeLastDepositBatch);
        }
        return
            (_chainId == ERA_CHAIN_ID) &&
            (_l2BatchNumber < eraLegacyBridgeLastDepositBatch ||
                (_l2TxNumberInBatch < eraLegacyBridgeLastDepositTxNumber &&
                    _l2BatchNumber == eraLegacyBridgeLastDepositBatch));
    }

    /// @notice Finalize the withdrawal and release funds
    /// @param _chainId The chain ID of the transaction to check
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
    ) external override {
        // To avoid rewithdrawing txs that have already happened on the legacy bridge.
        // Note: new withdraws are all recorded here, so double withdrawing them is not possible.
        if (_isEraLegacyTokenWithdrawal(_chainId, _l2BatchNumber)) {
            if (legacyBridge.isWithdrawalFinalized(_l2BatchNumber, _l2MessageIndex)) {
                revert WithdrawalAlreadyFinalized();
            }
        }
        _finalizeWithdrawal({
            _chainId: _chainId,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _message: _message,
            _merkleProof: _merkleProof
        });
    }

    struct MessageParams {
        uint256 l2BatchNumber;
        uint256 l2MessageIndex;
        uint16 l2TxNumberInBatch;
    }

    /// @dev Internal function that handles the logic for finalizing withdrawals,
    /// serving both the current bridge system and the legacy ERC20 bridge.
    function _finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) internal nonReentrant whenNotPaused returns (address l1Receiver, address l1Token, uint256 amount) {
        if (isWithdrawalFinalized[_chainId][_l2BatchNumber][_l2MessageIndex]) {
            revert WithdrawalAlreadyFinalized();
        }
        isWithdrawalFinalized[_chainId][_l2BatchNumber][_l2MessageIndex] = true;

        // Handling special case for withdrawal from zkSync Era initiated before Shared Bridge.
        if (_isEraLegacyEthWithdrawal(_chainId, _l2BatchNumber)) {
            // Checks that the withdrawal wasn't finalized already.
            bool alreadyFinalized = IGetters(ERA_DIAMOND_PROXY).isEthWithdrawalFinalized(
                _l2BatchNumber,
                _l2MessageIndex
            );
            if (alreadyFinalized) {
                revert WithdrawalAlreadyFinalized();
            }
        }

        MessageParams memory messageParams = MessageParams({
            l2BatchNumber: _l2BatchNumber,
            l2MessageIndex: _l2MessageIndex,
            l2TxNumberInBatch: _l2TxNumberInBatch
        });
        (l1Receiver, l1Token, amount) = _checkWithdrawal(_chainId, messageParams, _message, _merkleProof);

        if (!hyperbridgingEnabled[_chainId]) {
            // Check that the chain has sufficient balance
            if (chainBalance[_chainId][l1Token] < amount) {
                // not enough funds
                revert InsufficientChainBalance();
            }
            chainBalance[_chainId][l1Token] -= amount;
        }

        if (l1Token == ETH_TOKEN_ADDRESS) {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), l1Receiver, amount, 0, 0, 0, 0)
            }
            if (!callSuccess) {
                revert WithdrawFailed();
            }
        } else {
            // Withdraw funds
            IERC20(l1Token).safeTransfer(l1Receiver, amount);
        }
        emit WithdrawalFinalizedSharedBridge(_chainId, l1Receiver, l1Token, amount);
    }

    /// @dev Verifies the validity of a withdrawal message from L2 and returns details of the withdrawal.
    function _checkWithdrawal(
        uint256 _chainId,
        MessageParams memory _messageParams,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) internal view returns (address l1Receiver, address l1Token, uint256 amount) {
        (l1Receiver, l1Token, amount) = _parseL2WithdrawalMessage(_chainId, _message);
        L2Message memory l2ToL1Message;
        {
            bool baseTokenWithdrawal = (l1Token == BRIDGE_HUB.baseToken(_chainId));
            address l2Sender = baseTokenWithdrawal ? L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR : l2BridgeAddress[_chainId];

            l2ToL1Message = L2Message({
                txNumberInBatch: _messageParams.l2TxNumberInBatch,
                sender: l2Sender,
                data: _message
            });
        }

        bool success = BRIDGE_HUB.proveL2MessageInclusion({
            _chainId: _chainId,
            _batchNumber: _messageParams.l2BatchNumber,
            _index: _messageParams.l2MessageIndex,
            _message: l2ToL1Message,
            _proof: _merkleProof
        });
        // withdrawal wrong proof
        if (!success) {
            revert InvalidProof();
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
        // wrong message length
        if (_l2ToL1message.length < 56) {
            revert L2WithdrawalMessageWrongLength(_l2ToL1message.length);
        }

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        if (bytes4(functionSignature) == IMailbox.finalizeEthWithdrawal.selector) {
            // this message is a base token withdrawal
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);
            l1Token = BRIDGE_HUB.baseToken(_chainId);
        } else if (bytes4(functionSignature) == IL1ERC20Bridge.finalizeWithdrawal.selector) {
            // We use the IL1ERC20Bridge for backward compatibility with old withdrawals.

            // this message is a token withdrawal

            // Check that the message length is correct.
            // It should be equal to the length of the function signature + address + address + uint256 = 4 + 20 + 20 + 32 =
            // 76 (bytes).
            if (_l2ToL1message.length != 76) {
                revert L2WithdrawalMessageWrongLength(_l2ToL1message.length);
            }
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (l1Token, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);
        } else {
            revert InvalidSelector(bytes4(functionSignature));
        }
    }

    /*//////////////////////////////////////////////////////////////
                            ERA LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initiates a deposit by locking funds on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted.
    /// @dev If the token is bridged for the first time, the L2 token contract will be deployed. Note however, that the
    /// newly-deployed token does not support any custom logic, i.e. rebase tokens' functionality is not supported.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _l2Receiver The account address that should receive funds on L2
    /// @param _l1Token The L1 token address which is deposited
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
    /// @return l2TxHash The L2 transaction hash of deposit finalization.
    function depositLegacyErc20Bridge(
        address _prevMsgSender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable override onlyLegacyBridge nonReentrant whenNotPaused returns (bytes32 l2TxHash) {
        if (l2BridgeAddress[ERA_CHAIN_ID] == address(0)) {
            revert L2BridgeNotSet(ERA_CHAIN_ID);
        }
        if (_l1Token == L1_WETH_TOKEN) {
            revert TokenNotSupported(L1_WETH_TOKEN);
        }

        // Note that funds have been transferred to this contract in the legacy ERC20 bridge.
        if (!hyperbridgingEnabled[ERA_CHAIN_ID]) {
            chainBalance[ERA_CHAIN_ID][_l1Token] += _amount;
        }

        bytes memory l2TxCalldata = _getDepositL2Calldata(_prevMsgSender, _l2Receiver, _l1Token, _amount);

        {
            // If the refund recipient is not specified, the refund will be sent to the sender of the transaction.
            // Otherwise, the refund will be sent to the specified address.
            // If the recipient is a contract on L1, the address alias will be applied.
            address refundRecipient = AddressAliasHelper.actualRefundRecipient(_refundRecipient, _prevMsgSender);

            L2TransactionRequestDirect memory request = L2TransactionRequestDirect({
                chainId: ERA_CHAIN_ID,
                l2Contract: l2BridgeAddress[ERA_CHAIN_ID],
                mintValue: msg.value, // l2 gas + l2 msg.Value the bridgehub will withdraw the mintValue from the base token bridge for gas
                l2Value: 0, // L2 msg.value, this contract doesn't support base token deposits or wrapping functionality, for direct deposits use bridgehub
                l2Calldata: l2TxCalldata,
                l2GasLimit: _l2TxGasLimit,
                l2GasPerPubdataByteLimit: _l2TxGasPerPubdataByte,
                factoryDeps: new bytes[](0),
                refundRecipient: refundRecipient
            });
            l2TxHash = BRIDGE_HUB.requestL2TransactionDirect{value: msg.value}(request);
        }

        bytes32 txDataHash = keccak256(abi.encode(_prevMsgSender, _l1Token, _amount));
        // Save the deposited amount to claim funds on L1 if the deposit failed on L2
        depositHappened[ERA_CHAIN_ID][l2TxHash] = txDataHash;

        emit LegacyDepositInitiated({
            chainId: ERA_CHAIN_ID,
            l2DepositTxHash: l2TxHash,
            from: _prevMsgSender,
            to: _l2Receiver,
            l1Token: _l1Token,
            amount: _amount
        });
    }

    /// @notice Finalizes the withdrawal for transactions initiated via the legacy ERC20 bridge.
    /// @param _l2BatchNumber The L2 batch number where the withdrawal was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization
    ///
    /// @return l1Receiver The address on L1 that will receive the withdrawn funds
    /// @return l1Token The address of the L1 token being withdrawn
    /// @return amount The amount of the token being withdrawn
    function finalizeWithdrawalLegacyErc20Bridge(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external override onlyLegacyBridge returns (address l1Receiver, address l1Token, uint256 amount) {
        (l1Receiver, l1Token, amount) = _finalizeWithdrawal({
            _chainId: ERA_CHAIN_ID,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _message: _message,
            _merkleProof: _merkleProof
        });
    }

    /// @notice Withdraw funds from the initiated deposit, that failed when finalizing on zkSync Era chain.
    /// This function is specifically designed for maintaining backward-compatibility with legacy `claimFailedDeposit`
    /// method in `L1ERC20Bridge`.
    ///
    /// @param _depositSender The address of the deposit initiator
    /// @param _l1Token The address of the deposited L1 ERC20 token
    /// @param _amount The amount of the deposit that failed.
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization
    function claimFailedDepositLegacyErc20Bridge(
        address _depositSender,
        address _l1Token,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external override onlyLegacyBridge {
        _claimFailedDeposit({
            _checkedInLegacyBridge: true,
            _chainId: ERA_CHAIN_ID,
            _depositSender: _depositSender,
            _l1Token: _l1Token,
            _amount: _amount,
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: _merkleProof
        });
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    function unpause() external onlyOwner {
        _unpause();
    }
}
