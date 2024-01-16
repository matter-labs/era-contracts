// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import "./IBridgehub.sol";
import "../bridge/interfaces/IL1Bridge.sol";
import "../state-transition/IStateTransitionManager.sol";
import "../common/ReentrancyGuard.sol";
import "../state-transition/chain-interfaces/IZkSyncStateTransition.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";

contract Bridgehub is IBridgehub, ReentrancyGuard, Ownable2Step {
    /// @notice we store registered stateTransitionManagers
    mapping(address => bool) public stateTransitionManagerIsRegistered;
    /// @notice we store registered tokens (for arbitrary base token)
    mapping(address => bool) public tokenIsRegistered;
    /// @notice we store registered bridges
    mapping(address => bool) public tokenBridgeIsRegistered;

    /// @notice chainID => stateTransitionManager contract address
    mapping(uint256 => address) public stateTransitionManager;
    /// @notice chainID => base token address
    mapping(uint256 => address) public baseToken;
    /// @notice chainID => bridge holding the base token
    /// @notice a bridge can have multiple tokens
    mapping(uint256 => address) public baseTokenBridge;

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
    function getZkSyncStateTransition(uint256 _chainId) public view returns (address) {
        return IStateTransitionManager(stateTransitionManager[_chainId]).stateTransition(_chainId);
    }

    //// Registry

    /// @notice State Transition can be any contract with the appropriate interface/functionality
    function newStateTransitionManager(address _stateTransitionManager) external onlyOwner {
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
    function newToken(address _token) external onlyOwner {
        require(!tokenIsRegistered[_token], "Bridgehub: token already registered");
        tokenIsRegistered[_token] = true;
    }

    /// @notice Bridge can be any contract with the appropriate interface/functionality
    function newTokenBridge(address _tokenBridge) external onlyOwner {
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
    function newChain(
        uint256 _chainId,
        address _stateTransitionManager,
        address _baseToken,
        address _baseTokenBridge,
        uint256 _salt,
        address _l2Governor,
        bytes calldata _initData
    ) external onlyOwner nonReentrant returns (uint256 chainId) {
        // KL TODO: clear up this formula for chainId generation
        // if (_chainId == 0) {
        //     chainId = uint48(
        //         uint256(
        //             keccak256(
        //                 abi.encode(
        //                     "CHAIN_ID",
        //                     block.chainid,
        //                     address(this),
        //                     _stateTransitionManager,
        //                     msg.sender,
        //                     _salt
        //                 )
        //             )
        //         )
        //     );
        // } else { }
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
        }
        require(tokenBridgeIsRegistered[_baseTokenBridge], "Bridgehub: token bridge not registered");

        require(stateTransitionManager[chainId] == address(0), "Bridgehub: chainId already registered");

        stateTransitionManager[chainId] = _stateTransitionManager;
        baseToken[chainId] = _baseToken;
        baseTokenBridge[chainId] = _baseTokenBridge;

        IStateTransitionManager(_stateTransitionManager).newChain(
            chainId,
            _baseToken,
            _baseTokenBridge,
            _l2Governor,
            _initData
        );

        emit NewChain(chainId, _stateTransitionManager, msg.sender);
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
        address stateTransition = getZkSyncStateTransition(_chainId);
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
        address stateTransition = getZkSyncStateTransition(_chainId);
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
        address stateTransition = getZkSyncStateTransition(_chainId);
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
        address stateTransition = getZkSyncStateTransition(_chainId);
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
            address token = baseToken[_request.chainId];

            if (token == ETH_TOKEN_ADDRESS) {
                require(msg.value == _request.mintValue, "Bridgehub: msg.value mismatch");
                // kl todo it would be nice here to be able to deposit weth instead of eth
                IL1Bridge(baseTokenBridge[_request.chainId]).bridgehubDepositBaseToken{value: _request.mintValue}(
                    _request.chainId,
                    msg.sender,
                    token,
                    _request.mintValue
                );
            } else {
                require(msg.value == 0, "Bridgehub: non-eth bridge with msg.value");
                // note we have to pass token, as a bridge might have multiple tokens.
                IL1Bridge(baseTokenBridge[_request.chainId]).bridgehubDepositBaseToken(
                    _request.chainId,
                    msg.sender,
                    token,
                    _request.mintValue
                );
            }
        }

        address stateTransition = getZkSyncStateTransition(_request.chainId);
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
            address token = baseToken[_request.chainId];

            if (token == ETH_TOKEN_ADDRESS) {
                require(msg.value == _request.mintValue + _request.secondBridgeValue, "Bridgehub: msg.value mismatch");
                // kl todo it would be nice here to be able to deposit weth instead of eth
                IL1Bridge(baseTokenBridge[_request.chainId]).bridgehubDepositBaseToken{value: _request.mintValue}(
                    _request.chainId,
                    msg.sender,
                    token,
                    _request.mintValue
                );
            } else {
                require(msg.value == _request.secondBridgeValue, "Bridgehub: msg.value mismatch 2");
                // note we have to pass token, as a bridge might have multiple tokens.
                IL1Bridge(baseTokenBridge[_request.chainId]).bridgehubDepositBaseToken(
                    _request.chainId,
                    msg.sender,
                    token,
                    _request.mintValue
                );
            }
        }

        address stateTransition = getZkSyncStateTransition(_request.chainId);
        bytes memory data;
        {
            bool success;
            (success, data) = _request.secondBridgeAddress.call{value: _request.secondBridgeValue}(
                abi.encodeWithSelector(
                    _request.secondBridgeSelector,
                    _request.chainId,
                    msg.sender,
                    _request.secondBridgeCalldata
                )
            );
            require(success, "Bridgehub: second bridge call failed");
        }
        L2TransactionRequestTwoBridgesInner memory outputRequest = abi.decode(
            data,
            (L2TransactionRequestTwoBridgesInner)
        );

        canonicalTxHash = IZkSyncStateTransition(stateTransition).bridgehubRequestL2Transaction(
            msg.sender,
            outputRequest.l2Contract,
            _request.mintValue,
            _request.l2Value,
            outputRequest.l2Calldata,
            _request.l2GasLimit,
            _request.l2GasPerPubdataByteLimit,
            outputRequest.factoryDeps,
            _request.refundRecipient
        );

        IL1Bridge(_request.secondBridgeAddress).bridgehubConfirmL2Transaction(
            _request.chainId,
            outputRequest.txDataHash,
            canonicalTxHash
        );
    }
}
