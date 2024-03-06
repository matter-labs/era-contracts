// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import "./IBridgehub.sol";
import "../bridge/interfaces/IL1SharedBridge.sol";
import "../state-transition/IStateTransitionManager.sol";
import "../common/ReentrancyGuard.sol";
import "../state-transition/chain-interfaces/IZkSyncStateTransition.sol";
import {ETH_TOKEN_ADDRESS, TWO_BRIDGES_MAGIC_VALUE, BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS} from "../common/Config.sol";
import {BridgehubL2TransactionRequest} from "../common/Messaging.sol";
import "../vendor/AddressAliasHelper.sol";

contract Bridgehub is IBridgehub, ReentrancyGuard, Ownable2Step {
    /// @notice all the ether is held by the weth bridge
    IL1SharedBridge public sharedBridge;

    /// @notice we store registered stateTransitionManagers
    mapping(address _stateTransitionManager => bool) public stateTransitionManagerIsRegistered;
    /// @notice we store registered tokens (for arbitrary base token)
    mapping(address _token => bool) public tokenIsRegistered;

    /// @notice chainID => StateTransitionManager contract address, storing StateTransitionManager
    mapping(uint256 _chainId => address) public stateTransitionManager;

    /// @notice chainID => baseToken contract address, storing baseToken
    mapping(uint256 _chainId => address) public baseToken;

    /// @notice used as an alternative to deployChains
    address public deployer;

    /// @notice to avoid parity hack
    constructor() reentrancyGuardInitializer {}

    /// @notice used to initialize the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    modifier onlyOwnerOrDeployer() {
        require(msg.sender == deployer || msg.sender == owner(), "Bridgehub: not owner or deployer");
        _;
    }

    ///// Getters

    /// @notice return the state transition chain contract for a chainId
    function getStateTransition(uint256 _chainId) public view returns (address) {
        return IStateTransitionManager(stateTransitionManager[_chainId]).stateTransition(_chainId);
    }

    //// Registry

    /// @notice used to change deployer
    function setDeployer(address _newDeployer) external onlyOwner {
        deployer = _newDeployer;
    }

    /// @notice State Transition can be any contract with the appropriate interface/functionality
    function addStateTransitionManager(address _stateTransitionManager) external onlyOwner {
        require(
            !stateTransitionManagerIsRegistered[_stateTransitionManager],
            "Bridgehub: state transition already registered"
        );
        stateTransitionManagerIsRegistered[_stateTransitionManager] = true;
    }

    /// @notice State Transition can be any contract with the appropriate interface/functionality
    /// @notice this stops new Chains from using the STF, old chains are not affected
    function removeStateTransitionManager(address _stateTransitionManager) external onlyOwner {
        require(
            stateTransitionManagerIsRegistered[_stateTransitionManager],
            "Bridgehub: state transition not registered yet"
        );
        stateTransitionManagerIsRegistered[_stateTransitionManager] = false;
    }

    /// @notice token can be any contract with the appropriate interface/functionality
    function addToken(address _token) external onlyOwner {
        require(!tokenIsRegistered[_token], "Bridgehub: token already registered");
        tokenIsRegistered[_token] = true;
    }

    /// @notice To set shared bridge, only Owner. Not done in initialize, as
    /// the order of deployment is Bridgehub, Shared bridge, and then we call this
    function setSharedBridge(address _sharedBridge) external onlyOwner {
        sharedBridge = IL1SharedBridge(_sharedBridge);
    }

    /// @notice register new chain
    /// @notice for Eth the baseToken address is 1
    function createNewChain(
        uint256 _chainId,
        address _stateTransitionManager,
        address _baseToken,
        uint256, //_salt
        address _admin,
        bytes calldata _initData
    ) external onlyOwnerOrDeployer nonReentrant returns (uint256 chainId) {
        require(_chainId != 0, "Bridgehub: chainId cannot be 0");
        require(_chainId <= type(uint48).max, "Bridgehub: chainId too large");

        require(
            stateTransitionManagerIsRegistered[_stateTransitionManager],
            "Bridgehub: state transition not registered"
        );
        require(tokenIsRegistered[_baseToken], "Bridgehub: token not registered");
        require(address(sharedBridge) != address(0), "Bridgehub: weth bridge not set");

        require(stateTransitionManager[_chainId] == address(0), "Bridgehub: chainId already registered");

        stateTransitionManager[_chainId] = _stateTransitionManager;
        baseToken[_chainId] = _baseToken;

        IStateTransitionManager(_stateTransitionManager).createNewChain(
            _chainId,
            _baseToken,
            address(sharedBridge),
            _admin,
            _initData
        );

        emit NewChain(_chainId, _stateTransitionManager, _admin);
        return _chainId;
    }

    //// Mailbox forwarder

    /// @notice forwards function call to Mailbox based on ChainId
    function proveL2MessageInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        address stateTransition = getStateTransition(_chainId);
        return IZkSyncStateTransition(stateTransition).proveL2MessageInclusion(_batchNumber, _index, _message, _proof);
    }

    /// @notice forwards function call to Mailbox based on ChainId
    function proveL2LogInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        address stateTransition = getStateTransition(_chainId);
        return IZkSyncStateTransition(stateTransition).proveL2LogInclusion(_batchNumber, _index, _log, _proof);
    }

    /// @notice forwards function call to Mailbox based on ChainId
    function proveL1ToL2TransactionStatus(
        uint256 _chainId,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) external view override returns (bool) {
        address stateTransition = getStateTransition(_chainId);
        return
            IZkSyncStateTransition(stateTransition).proveL1ToL2TransactionStatus(
                _l2TxHash,
                _l2BatchNumber,
                _l2MessageIndex,
                _l2TxNumberInBatch,
                _merkleProof,
                _status
            );
    }

    /// @notice forwards function call to Mailbox based on ChainId
    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256) {
        address stateTransition = getStateTransition(_chainId);
        return
            IZkSyncStateTransition(stateTransition).l2TransactionBaseCost(
                _gasPrice,
                _l2GasLimit,
                _l2GasPerPubdataByteLimit
            );
    }

    /// @notice the mailbox is called directly after the sharedBridge received the deposit
    /// this assumes that either ether is the base token or
    /// the msg.sender has approved mintValue allowance for the sharedBridge.
    /// This means this is not ideal for contract calls, as the contract would have to handle token allowance of the base Token
    function requestL2TransactionDirect(
        L2TransactionRequestDirect calldata _request
    ) external payable override nonReentrant returns (bytes32 canonicalTxHash) {
        {
            address token = baseToken[_request.chainId];
            if (token == ETH_TOKEN_ADDRESS) {
                require(msg.value == _request.mintValue, "Bridgehub: msg.value mismatch 1");
            } else {
                require(msg.value == 0, "Bridgehub: non-eth bridge with msg.value");
            }

            sharedBridge.bridgehubDepositBaseToken{value: msg.value}(
                _request.chainId,
                msg.sender,
                token,
                _request.mintValue
            );
        }

        address stateTransition = getStateTransition(_request.chainId);
        address refundRecipient = _actualRefundRecipient(_request.refundRecipient);
        canonicalTxHash = IZkSyncStateTransition(stateTransition).bridgehubRequestL2Transaction(
            BridgehubL2TransactionRequest({
                sender: msg.sender,
                contractL2: _request.l2Contract,
                mintValue: _request.mintValue,
                l2Value: _request.l2Value,
                l2Calldata: _request.l2Calldata,
                l2GasLimit: _request.l2GasLimit,
                l2GasPerPubdataByteLimit: _request.l2GasPerPubdataByteLimit,
                factoryDeps: _request.factoryDeps,
                refundRecipient: refundRecipient
            })
        );
    }

    /// @notice After depositing funds to the sharedBridge, the secondBridge is called
    ///  to return the actual L2 message which is sent to the Mailbox.
    ///  This assumes that either ether is the base token or
    ///  the msg.sender has approved the sharedBridge with the mintValue,
    ///  and also the necessary approvals are given for the second bridge.
    /// @notice The logic of this bridge is to allow easy depositing for bridges.
    /// Each contract that handles the users ERC20 tokens needs approvals from the user, this contract allows
    /// the user to approve for each token only its respective bridge
    /// @notice This function is great for contract calls to L2, the secondBridge can be any contract.
    function requestL2TransactionTwoBridges(
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) external payable override nonReentrant returns (bytes32 canonicalTxHash) {
        {
            address token = baseToken[_request.chainId];
            uint256 baseTokenMsgValue;
            if (token == ETH_TOKEN_ADDRESS) {
                require(
                    msg.value == _request.mintValue + _request.secondBridgeValue,
                    "Bridgehub: msg.value mismatch 2"
                );
                baseTokenMsgValue = _request.mintValue;
            } else {
                require(msg.value == _request.secondBridgeValue, "Bridgehub: msg.value mismatch 3");
                baseTokenMsgValue = 0;
            }
            sharedBridge.bridgehubDepositBaseToken{value: baseTokenMsgValue}(
                _request.chainId,
                msg.sender,
                token,
                _request.mintValue
            );
        }

        address stateTransition = getStateTransition(_request.chainId);

        L2TransactionRequestTwoBridgesInner memory outputRequest = IL1SharedBridge(_request.secondBridgeAddress)
            .bridgehubDeposit{value: _request.secondBridgeValue}(
            _request.chainId,
            msg.sender,
            _request.l2Value,
            _request.secondBridgeCalldata
        );

        require(outputRequest.magicValue == TWO_BRIDGES_MAGIC_VALUE, "Bridgehub: magic value mismatch");

        address refundRecipient = _actualRefundRecipient(_request.refundRecipient);

        require(
            _request.secondBridgeAddress > BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS,
            "Bridgehub: second bridge address too low"
        ); // to avoid calls to precompiles
        canonicalTxHash = IZkSyncStateTransition(stateTransition).bridgehubRequestL2Transaction(
            BridgehubL2TransactionRequest({
                sender: _request.secondBridgeAddress,
                contractL2: outputRequest.l2Contract,
                mintValue: _request.mintValue,
                l2Value: _request.l2Value,
                l2Calldata: outputRequest.l2Calldata,
                l2GasLimit: _request.l2GasLimit,
                l2GasPerPubdataByteLimit: _request.l2GasPerPubdataByteLimit,
                factoryDeps: outputRequest.factoryDeps,
                refundRecipient: refundRecipient
            })
        );

        IL1SharedBridge(_request.secondBridgeAddress).bridgehubConfirmL2Transaction(
            _request.chainId,
            outputRequest.txDataHash,
            canonicalTxHash
        );
    }

    function _actualRefundRecipient(address _refundRecipient) internal view returns (address _recipient) {
        if (_refundRecipient == address(0)) {
            // If the `_refundRecipient` is not provided, we use the `msg.sender` as the recipient.
            _recipient = msg.sender == tx.origin ? msg.sender : AddressAliasHelper.applyL1ToL2Alias(msg.sender);
        } else if (_refundRecipient.code.length > 0) {
            // If the `_refundRecipient` is a smart contract, we apply the L1 to L2 alias to prevent foot guns.
            _recipient = AddressAliasHelper.applyL1ToL2Alias(_refundRecipient);
        } else {
            _recipient = _refundRecipient;
        }
    }
}
