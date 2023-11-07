// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (proxy/Proxy.sol)

pragma solidity ^0.8.13;

import "./BridgehubBase.sol";
import "../bridgehub-interfaces/IRegistry.sol";
import "../../common/libraries/UncheckedMath.sol";
import "../../common/libraries/Diamond.sol";

contract BridgehubRegistryFacet is IRegistry, BridgehubBase {
    using UncheckedMath for uint256;
    string public constant override getName = "BridgehubRegistryFacet";

    /// @notice Proof system can be any contract with the appropriate interface, functionality
    function newStateTransition(address _stateTransition) external onlyGovernor {
        // KL todo add checks here
        require(!bridgehubStorage.stateTransitionIsRegistered[_stateTransition], "r35");
        bridgehubStorage.stateTransitionIsRegistered[_stateTransition] = true;
    }

    /// @notice
    // KL todo make _chainId
    function newChain(uint256 _chainId, address _stateTransition, uint256 _salt) external onlyGovernor returns (uint256 chainId) {
        // KL TODO: clear up this formula for chainId generation
        // KL Todo: uint16 until the server can take bigger numbers.
        if (_chainId == 0) {
            chainId = uint16(
                uint256(
                    keccak256(abi.encodePacked("CHAIN_ID", block.chainid, address(this), _stateTransition, msg.sender, _salt))
                )
            );
        } else {
            chainId = _chainId;
        }

        require(bridgehubStorage.stateTransitionIsRegistered[_stateTransition], "r19");

        bridgehubStorage.stateTransition[chainId] = _stateTransition;

        emit NewChain(uint16(chainId), _stateTransition, msg.sender);
    }

    function setStateTransitionChainContract(uint256 _chainId, address _stateTransitionChainContract)
        external
        onlyStateTransition(_chainId)
    {
        bridgehubStorage.stateTransitionChain[_chainId] = _stateTransitionChainContract;
    }
}
