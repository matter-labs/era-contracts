// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (proxy/Proxy.sol)

pragma solidity ^0.8.13;

import "./BridgeheadBase.sol";
// import "../../common/Config.sol";
import "../bridgehead-interfaces/IRegistry.sol";
import "../../common/libraries/UncheckedMath.sol";
// import "../bridgehead-interfaces/IBridgeheadMailbox.sol";
// import "../../common/interfaces/IAllowList.sol";
import "../../common/libraries/Diamond.sol";
// import "../../common/libraries/L2ContractHelper.sol";
// import "../../common/L2ContractAddresses.sol";
import "../chain-interfaces/IBridgeheadChain.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract Registry is IRegistry, BridgeheadBase {
    using UncheckedMath for uint256;

    /// @notice Proof system can be any contract with the appropriate interface, functionality
    function newProofSystem(address _proofSystem) external onlyGovernor {
        // KL todo add checks here
        require(!bridgeheadStorage.proofSystemIsRegistered[_proofSystem], "r35");
        bridgeheadStorage.proofSystemIsRegistered[_proofSystem] = true;
    }

    /// @notice
    // KL todo make _chainId
    function newChain(
        uint256 _chainId,
        address _proofSystem,
        address _chainGovernor,
        IAllowList _allowList,
        Diamond.DiamondCutData calldata _diamondCut
    ) external onlyGovernor returns (uint256 chainId) {
        // KL TODO: clear up this formula for chainId generation
        // KL Todo: uint16 until the server can take bigger numbers.
        if (_chainId == 0) {
            chainId = uint16(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            "CHAIN_ID",
                            block.chainid,
                            address(this),
                            _proofSystem,
                            msg.sender
                        )
                    )
                )
            );
        } else {
            chainId = _chainId;
        }
        // KL todo add checks here

        require(bridgeheadStorage.proofSystemIsRegistered[_proofSystem], "r19");
        // require(bridgeheadStorage.chainContract[chainId] == address(0), "r20");

        // bridgeheadStorage.totalChains += 1;
        bridgeheadStorage.proofSystem[chainId] = _proofSystem;

        // bytes memory data = abi.encodeWithSelector(
        //     IBridgeheadChain.initialize.selector,
        //     chainId,
        //     _proofSystem,
        //     _chainGovernor,
        //     _allowList,
        //     bridgeheadStorage.priorityTxMaxGasLimit
        // );
        // TransparentUpgradeableProxy chainContract = new TransparentUpgradeableProxy(
        //     bridgeheadStorage.chainImplementation,
        //     bridgeheadStorage.chainProxyAdmin,
        //     data
        // );
        // bridgeheadStorage.chainContract[chainId] = address(chainContract);

        IProofSystem(_proofSystem).newChain(chainId, _chainGovernor, _diamondCut);

        emit NewChain(uint16(chainId), _proofSystem, msg.sender);
    }
}
