// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import "./IBridgehub.sol";
import "../bridge/interfaces/IL1Bridge.sol";
import "../state-transition/IStateTransitionManager.sol";
import "../common/ReentrancyGuard.sol";
import "../state-transition/chain-interfaces/IZkSyncStateTransition.sol";
import {ETH_TOKEN_ADDRESS, TWO_BRIDGES_MAGIC_VALUE} from "../common/Config.sol";
import "../vendor/AddressAliasHelper.sol";

contract Bridgehub is IBridgehub, ReentrancyGuard, Ownable2Step {
    /// @notice we store registered stateTransitionManagers
    mapping(address => bool) public stateTransitionManagerIsRegistered;
    /// @notice we store registered tokens (for arbitrary base token)
    mapping(address => bool) public tokenIsRegistered;
    /// @notice we store registered bridges
    mapping(address => bool) public tokenBridgeIsRegistered;

    /// @notice chainID => ChainData contract address, storing StateTransitionManager, baseToken, baseTokenBridge
    mapping(uint256 => ChainData) public chainData;

    /// @notice all the ether is held by the weth bridge
    IL1Bridge public wethBridge;

    /// @notice to avoid parity hack
    constructor() reentrancyGuardInitializer {}

    /// @notice used to initialize the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    ///// Getters

    /// @notice return the state transition chain contract for a chainId
    function getStateTransition(uint256 _chainId) public view returns (address) {
        return IStateTransitionManager(chainData[_chainId].stateTransitionManager).stateTransition(_chainId);
    }

    function baseToken(uint256 _chainId) external view override returns (address) {
        return chainData[_chainId].baseToken;
    }

    function baseTokenBridge(uint256 _chainId) external view override returns (address) {
        return chainData[_chainId].baseTokenBridge;
    }

    function stateTransitionManager(uint256 _chainId) external view override returns (address) {
        return chainData[_chainId].stateTransitionManager;
    }

    //// Registry

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

    /// @notice Bridge can be any contract with the appropriate interface/functionality
    function addTokenBridge(address _tokenBridge) external onlyOwner {
        require(!tokenBridgeIsRegistered[_tokenBridge], "Bridgehub: token bridge already registered");
        tokenBridgeIsRegistered[_tokenBridge] = true;
    }

    /// @notice To set main Weth bridge, only Owner. Not done in initialize, as
    /// the order of deployment is Bridgehub, L1WethBridge, and then we call this
    function setWethBridge(address _wethBridge) external onlyOwner {
        wethBridge = IL1Bridge(_wethBridge);
    }

    /// @notice register new chain
    /// @notice for Eth the baseToken address is 1, and the baseTokenBridge is the wethBridge is required
    function createNewChain(
        uint256 _chainId,
        address _stateTransitionManager,
        address _baseToken,
        address _baseTokenBridge,
        uint256 _salt,
        address _l2Governor,
        bytes calldata _initData
    ) external onlyOwner nonReentrant returns (uint256 chainId) {
        require(_chainId != 0, "Bridgehub: chainId cannot be 0");
        require(_chainId <= type(uint48).max, "Bridgehub: chainId too large");

        require(
            stateTransitionManagerIsRegistered[_stateTransitionManager],
            "Bridgehub: state transition not registered"
        );
        require(tokenIsRegistered[_baseToken], "Bridgehub: token not registered");
        if (_baseToken == ETH_TOKEN_ADDRESS) {
            require(address(wethBridge) == _baseTokenBridge, "Bridgehub: baseTokenBridge has to be weth bridge");
            require(address(_baseTokenBridge) != address(0), "Bridgehub: weth bridge not set");
        } else {
            require(address(wethBridge) != _baseTokenBridge, "Bridgehub: baseTokenBridge cannot be weth bridge");
        }
        require(tokenBridgeIsRegistered[_baseTokenBridge], "Bridgehub: token bridge not registered");

        require(chainData[_chainId].stateTransitionManager == address(0), "Bridgehub: chainId already registered");

        chainData[_chainId].stateTransitionManager = _stateTransitionManager;
        chainData[_chainId].baseToken = _baseToken;
        chainData[_chainId].baseTokenBridge = _baseTokenBridge;

        IStateTransitionManager(_stateTransitionManager).createNewChain(
            _chainId,
            _baseToken,
            _baseTokenBridge,
            _l2Governor,
            _initData
        );

        emit NewChain(_chainId, _stateTransitionManager, _l2Governor);
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

    /// @notice the mailbox is called directly after the baseTokenBridge received the deposit
    /// this assumes that either ether is the base token or
    /// the msg.sender has approved mintValue allowance for the baseTokenBridge.
    /// This means this is not ideal for contract calls, as the contract would have to handle token allowance of the base Token
    function requestL2Transaction(
        L2TransactionRequestDirect calldata _request
    ) public payable override nonReentrant returns (bytes32 canonicalTxHash) {
        {
            address token = chainData[_request.chainId].baseToken;

            if (token == ETH_TOKEN_ADDRESS) {
                require(msg.value == _request.mintValue, "Bridgehub: msg.value mismatch");
                // kl todo it would be nice here to be able to deposit weth instead of eth
                IL1Bridge(chainData[_request.chainId].baseTokenBridge).bridgehubDepositBaseToken{
                    value: _request.mintValue
                }(_request.chainId, msg.sender, token, _request.mintValue);
            } else {
                require(msg.value == 0, "Bridgehub: non-eth bridge with msg.value");
                // note we have to pass token, as a bridge might have multiple tokens.
                IL1Bridge(chainData[_request.chainId].baseTokenBridge).bridgehubDepositBaseToken(
                    _request.chainId,
                    msg.sender,
                    token,
                    _request.mintValue
                );
            }
        }

        address stateTransition = getStateTransition(_request.chainId);
        canonicalTxHash = IZkSyncStateTransition(stateTransition).bridgehubRequestL2Transaction(
            msg.sender,
            _request.l2Contract,
            _request.mintValue,
            _request.l2Value,
            _request.l2Calldata,
            _request.l2GasLimit,
            _request.l2GasPerPubdataByteLimit,
            _request.factoryDeps,
            _request.refundRecipient
        );
    }

    /// @notice After depositing funds to the baseTokenBridge, the secondBridge is called
    ///  to return the actual L2 message which is sent to the Mailbox.
    ///  This assumes that either ether is the base token or
    ///  the msg.sender has approved the baseTokenBridge with the mintValue,
    ///  and also the necessary approvals are given for the second bridge.
    /// @notice The logic of this bridge is to allow easy depositing for bridges.
    /// Each contract that handles the users ERC20 tokens needs approvals from the user, this contract allows
    /// the user to approve for each token only its respective bridge
    /// @notice This function is great for contract calls to L2, the secondBridge can be any contract.
    function requestL2TransactionTwoBridges(
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) public payable override nonReentrant returns (bytes32 canonicalTxHash) {
        {
            address token = chainData[_request.chainId].baseToken;

            if (token == ETH_TOKEN_ADDRESS) {
                require(msg.value == _request.mintValue + _request.secondBridgeValue, "Bridgehub: msg.value mismatch");
                // kl todo it would be nice here to be able to deposit weth instead of eth
                IL1Bridge(chainData[_request.chainId].baseTokenBridge).bridgehubDepositBaseToken{
                    value: _request.mintValue
                }(_request.chainId, msg.sender, token, _request.mintValue);
            } else {
                require(msg.value == _request.secondBridgeValue, "Bridgehub: msg.value mismatch 2");
                // note we have to pass token, as a bridge might have multiple tokens.
                IL1Bridge(chainData[_request.chainId].baseTokenBridge).bridgehubDepositBaseToken(
                    _request.chainId,
                    msg.sender,
                    token,
                    _request.mintValue
                );
            }
        }

        address stateTransition = getStateTransition(_request.chainId);

        L2TransactionRequestTwoBridgesInner memory outputRequest = IL1Bridge(_request.secondBridgeAddress)
            .bridgehubDeposit{value: _request.secondBridgeValue}(
            _request.chainId,
            msg.sender,
            _request.secondBridgeCalldata
        );

        require(outputRequest.magicValue == TWO_BRIDGES_MAGIC_VALUE, "Bridgehub: magic value mismatch");

        address refundRecipient = _request.refundRecipient;
        if (refundRecipient == address(0)) {
            // // If the `_refundRecipient` is not provided, we use the `msg.sender` as the recipient.
            refundRecipient = msg.sender == tx.origin ? msg.sender : AddressAliasHelper.applyL1ToL2Alias(msg.sender);
        } else if (refundRecipient.code.length > 0) {
            // If the `_refundRecipient` is a smart contract, we apply the L1 to L2 alias to prevent foot guns.
            refundRecipient = AddressAliasHelper.applyL1ToL2Alias(_request.refundRecipient);
        }
        require(_request.secondBridgeAddress > address(1000), "Bridgehub: second bridge address too low"); // to avoid calls to precompiles
        canonicalTxHash = IZkSyncStateTransition(stateTransition).bridgehubRequestL2Transaction(
            _request.secondBridgeAddress,
            outputRequest.l2Contract,
            _request.mintValue,
            _request.l2Value,
            outputRequest.l2Calldata,
            _request.l2GasLimit,
            _request.l2GasPerPubdataByteLimit,
            outputRequest.factoryDeps,
            refundRecipient
        );

        IL1Bridge(_request.secondBridgeAddress).bridgehubConfirmL2Transaction(
            _request.chainId,
            outputRequest.txDataHash,
            canonicalTxHash
        );
    }
}
