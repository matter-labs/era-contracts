// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

// import {L2Log, L2Message} from "../chain-deps/ChainStorage.sol";
import "./bridgehub-deps/BridgehubBase.sol";
import "./bridgehub-interfaces/IBridgehub.sol";
import "../state-transition/chain-interfaces/IStateTransitionChain.sol";

contract Bridgehub is BridgehubBase, IBridgehub{

    string public constant override getName = "Bridgehub";

    function initialize(
        address _governor
    ) external reentrancyGuardInitializer returns (bytes32) {
        require(bridgehubStorage.governor == address(0), "Bridgehub: governor zero");
        bridgehubStorage.governor = _governor;
    }
    
    ///// Getters

    /// @return The address of the current governor
    function getGovernor() external view returns (address) {
        return bridgehubStorage.governor;
    }

    /// @return The total number of batches that were committed & verified & executed
    function getIsStateTransition(address _stateTransition) external view returns (bool) {
        return bridgehubStorage.stateTransitionIsRegistered[_stateTransition];
    }

    function getStateTransition(uint256 _chainId) external view returns (address) {
        return bridgehubStorage.stateTransition[_chainId];
    }

    function getStateTransitionChain(uint256 _chainId) public view returns (address) {
        return IStateTransition(bridgehubStorage.stateTransition[_chainId]).getStateTransitionChain(_chainId);
    }
    
    //// Registry 

        /// @notice Proof system can be any contract with the appropriate interface, functionality
        function newStateTransition(address _stateTransition) external onlyGovernor {
            // KL todo add checks here
            require(!bridgehubStorage.stateTransitionIsRegistered[_stateTransition], "Bridgehub: state transition already registered");
            bridgehubStorage.stateTransitionIsRegistered[_stateTransition] = true;
        }
    
        /// @notice
        function newChain(
            uint256 _chainId,
            address _stateTransition,
            uint256 _salt
        ) external onlyGovernor returns (uint256 chainId) {
            // KL TODO: clear up this formula for chainId generation
            // KL Todo: uint16 until the server can take bigger numbers.
            if (_chainId == 0) {
                chainId = uint16(
                    uint256(
                        keccak256(
                            abi.encodePacked("CHAIN_ID", block.chainid, address(this), _stateTransition, msg.sender, _salt)
                        )
                    )
                );
            } else {
                chainId = _chainId;
            }
    
            require(bridgehubStorage.stateTransitionIsRegistered[_stateTransition], "Bridgehub: state transition not registered");
    
            bridgehubStorage.stateTransition[chainId] = _stateTransition;
    
            emit NewChain(uint16(chainId), _stateTransition, msg.sender);
        }

    //// Mailbox forwarder
    function isEthWithdrawalFinalized(
        uint256 _chainId,
        uint256 _l2MessageIndex,
        uint256 _l2TxNumberInBlock
    ) external view override returns (bool) {
        address stateTransitionChain = getStateTransitionChain(_chainId);
        return
            IStateTransitionChain(stateTransitionChain).isEthWithdrawalFinalized(_l2MessageIndex, _l2TxNumberInBlock);
    }

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
        uint256 _l2BlockNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBlock,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) external view override returns (bool) {
        address stateTransitionChain = getStateTransitionChain(_chainId);
        return
            IStateTransitionChain(stateTransitionChain).proveL1ToL2TransactionStatus(
                _l2TxHash,
                _l2BlockNumber,
                _l2MessageIndex,
                _l2TxNumberInBlock,
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
        uint256 _chainId,
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        address _refundRecipient
    ) public payable override returns (bytes32 canonicalTxHash) {
        address stateTransitionChain = getStateTransitionChain(_chainId);
        canonicalTxHash = IStateTransitionChain(stateTransitionChain).requestL2TransactionBridgehub(
            msg.value,
            msg.sender,
            _contractL2,
            _l2Value,
            _calldata,
            _l2GasLimit,
            _l2GasPerPubdataByteLimit,
            _factoryDeps,
            _refundRecipient
        );
    }

    function finalizeEthWithdrawal(
        uint256 _chainId,
        uint256 _l2BlockNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBlock,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external override {
        address stateTransitionChain = getStateTransitionChain(_chainId);
        return
            IStateTransitionChain(stateTransitionChain).finalizeEthWithdrawalBridgehub(
                msg.sender,
                _l2BlockNumber,
                _l2MessageIndex,
                _l2TxNumberInBlock,
                _message,
                _merkleProof
            );
    }

    function deposit(uint256 _chainId) external payable onlyStateTransitionChain(_chainId) {
        // just accept eth
        return;
    }

    /// @notice Transfer ether from the contract to the receiver
    /// @dev Reverts only if the transfer call failed
    function withdrawFunds(uint256 _chainId, address _to, uint256 _amount) external onlyStateTransitionChain(_chainId) {
        bool callSuccess;
        // Low-level assembly call, to avoid any memory copying (save gas)
        assembly {
            callSuccess := call(gas(), _to, _amount, 0, 0, 0, 0)
        }
        require(callSuccess, "Bridgehub: withdraw failed");
    }
}