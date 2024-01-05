// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./bridgehub-interfaces/IBridgehub.sol";
import "../bridge/interfaces/IL1Bridge.sol";
import "../state-transition/state-transition-interfaces/IZkSyncStateTransition.sol";
import "../common/ReentrancyGuard.sol";
import "../state-transition/chain-interfaces/IStateTransitionChain.sol";

contract Bridgehub is IBridgehub, ReentrancyGuard {
    string public constant override getName = "Bridgehub";
    address public constant ethTokenAddress = address(1);

    /// @notice Address which will exercise critical changes
    address public governor;
    /// new fields
    /// @notice we store registered stateTransitions
    mapping(address => bool) public stateTransitionIsRegistered;
    /// @notice we store registered tokens (for arbitrary base token)
    mapping(address => bool) public tokenIsRegistered;
    /// @notice we store registered bridges
    mapping(address => bool) public tokenBridgeIsRegistered;

    /// @notice chainID => stateTransition contract address
    mapping(uint256 => address) public stateTransition;
    /// @notice chainID => base token address
    mapping(uint256 => address) public baseToken;
    /// @notice chainID => bridge holding the base token
    /// @notice a bridge can have multiple tokens
    mapping(uint256 => address) public baseTokenBridge;

    IL1Bridge public wethBridge;

    /// @notice Checks that the message sender is an active governor
    modifier onlyGovernor() {
        require(msg.sender == governor, "Bridgehub: not governor");
        _;
    }

    modifier onlyStateTransition(uint256 _chainId) {
        require(msg.sender == stateTransition[_chainId], "Bridgehub: not state transition");
        _;
    }

    modifier onlyStateTransitionChain(uint256 _chainId) {
        require(
            msg.sender == IZkSyncStateTransition(stateTransition[_chainId]).stateTransitionChain(_chainId),
            "Bridgehub: not state transition chain"
        );
        _;
    }

    modifier onlyBaseTokenBridge(uint256 _chainId) {
        require(msg.sender == baseTokenBridge[_chainId], "Bridgehub: not base token bridge");
        _;
    }

    function initialize(address _governor) external reentrancyGuardInitializer returns (bytes32) {
        require(governor == address(0), "Bridgehub: governor zero");
        governor = _governor;
    }

    ///// Getters

    function getStateTransitionChain(uint256 _chainId) public view returns (address) {
        return IZkSyncStateTransition(stateTransition[_chainId]).stateTransitionChain(_chainId);
    }

    //// Registry

    /// @notice State Transition can be any contract with the appropriate interface/functionality
    function newStateTransition(address _stateTransition) external onlyGovernor {
        require(!stateTransitionIsRegistered[_stateTransition], "Bridgehub: state transition already registered");
        stateTransitionIsRegistered[_stateTransition] = true;
    }

    /// @notice token can be any contract with the appropriate interface/functionality
    function newToken(address _token) external onlyGovernor {
        require(!tokenIsRegistered[_token], "Bridgehub: token already registered");
        tokenIsRegistered[_token] = true;
    }

    /// @notice Bridge can be any contract with the appropriate interface/functionality
    function newTokenBridge(address _tokenBridge) external onlyGovernor {
        require(!tokenBridgeIsRegistered[_tokenBridge], "Bridgehub: token bridge already registered");
        tokenBridgeIsRegistered[_tokenBridge] = true;
    }

    function setWethBridge(address _wethBridge) external onlyGovernor {
        wethBridge = IL1Bridge(_wethBridge);
    }

    /// @notice for Eth the baseToken address is 0.
    function newChain(
        uint256 _chainId,
        address _stateTransition,
        address _baseToken,
        address _baseTokenBridge,
        uint256 _salt,
        address _l2Governor,
        bytes calldata _initData
    ) external onlyGovernor returns (uint256 chainId) {
        // KL TODO: clear up this formula for chainId generation
        if (_chainId == 0) {
            chainId = uint48(
                uint256(
                    keccak256(
                        abi.encodePacked("CHAIN_ID", block.chainid, address(this), _stateTransition, msg.sender, _salt)
                    )
                )
            );
        } else {
            chainId = _chainId;
        }

        require(stateTransitionIsRegistered[_stateTransition], "Bridgehub: state transition not registered");
        require(tokenIsRegistered[_baseToken], "Bridgehub: token not registered");
        require(tokenBridgeIsRegistered[_baseTokenBridge], "Bridgehub: token bridge not registered");

        require(stateTransition[_chainId] == address(0), "Bridgehub: chainId already not registered");

        stateTransition[chainId] = _stateTransition;
        baseToken[chainId] = _baseToken;
        baseTokenBridge[chainId] = _baseTokenBridge;

        IZkSyncStateTransition(_stateTransition).newChain(
            chainId,
            _baseToken,
            _baseTokenBridge,
            _l2Governor,
            _initData
        );

        emit NewChain(uint48(chainId), _stateTransition, msg.sender);
    }

    //// Mailbox forwarder

    function proveL2MessageInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        address stateTransitionChain = getStateTransitionChain(_chainId);
        return
            IStateTransitionChain(stateTransitionChain).proveL2MessageInclusion(_batchNumber, _index, _message, _proof);
    }

    function proveL2LogInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        address stateTransitionChain = getStateTransitionChain(_chainId);
        return IStateTransitionChain(stateTransitionChain).proveL2LogInclusion(_batchNumber, _index, _log, _proof);
    }

    function proveL1ToL2TransactionStatus(
        uint256 _chainId,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) external view override returns (bool) {
        address stateTransitionChain = getStateTransitionChain(_chainId);
        return
            IStateTransitionChain(stateTransitionChain).proveL1ToL2TransactionStatus(
                _l2TxHash,
                _l2BatchNumber,
                _l2MessageIndex,
                _l2TxNumberInBatch,
                _merkleProof,
                _status
            );
    }

    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256) {
        address stateTransitionChain = getStateTransitionChain(_chainId);
        return
            IStateTransitionChain(stateTransitionChain).l2TransactionBaseCost(
                _gasPrice,
                _l2GasLimit,
                _l2GasPerPubdataByteLimit
            );
    }

    function requestL2Transaction(
        L2TransactionRequest memory _request
    ) public payable override returns (bytes32 canonicalTxHash) {
        {
            address token = baseToken[_request.chainId];
            // address tokenBridge = baseTokenBridge[_request.chainId];

            if (token == ethTokenAddress) {
                // kl todo it would be nice here to be able to deposit weth instead of eth
                IL1Bridge(baseTokenBridge[_request.chainId]).bridgehubDeposit{value: msg.value}(
                    _request.chainId,
                    token,
                    msg.value,
                    _request.payer
                );
            } else {
                require(msg.value == 0, "Bridgehub: non-eth bridge with msg.value");
                // note we have to pass token, as a bridge might have multiple tokens.
                IL1Bridge(baseTokenBridge[_request.chainId]).bridgehubDeposit(
                    _request.chainId,
                    token,
                    _request.mintValue,
                    _request.payer
                );
            }
        }

        // to avoid stack too deep error we check the same condition twice for different varialbes
        uint256 mintValue = _request.mintValue;
        {
            address token = baseToken[_request.chainId];
            // address tokenBridge = baseTokenBridge[_request.chainId];

            if (token == ethTokenAddress) {
                // kl todo it would be nice here to be able to deposit weth instead of eth
                mintValue = msg.value;
            }
        }

        address stateTransitionChain = getStateTransitionChain(_request.chainId);
        canonicalTxHash = IStateTransitionChain(stateTransitionChain).bridgehubRequestL2Transaction(
            msg.sender,
            _request.l2Contract,
            mintValue,
            _request.l2Value,
            _request.l2Calldata,
            _request.l2GasLimit,
            _request.l2GasPerPubdataByteLimit,
            _request.factoryDeps,
            _request.refundRecipient
        );
    }
}
