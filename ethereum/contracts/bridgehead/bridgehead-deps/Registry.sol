// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (proxy/Proxy.sol)

pragma solidity ^0.8.13;

import "./BridgeheadBase.sol";
// import "../Config.sol";
import "../bridgehead-interfaces/IRegistry.sol";
import "../../common/libraries/UncheckedMath.sol";
// import "../chain-interfaces/IMailbox.sol";
// import "../../common/interfaces/IAllowList.sol";
// import "../../common/libraries/Diamond.sol";
// import "../../common/libraries/L2ContractHelper.sol";
// import "../../common/L2ContractAddresses.sol";
import "../chain-interfaces/IBridgeheadChain.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract Registry is IRegistry, BridgeheadBase {
    using UncheckedMath for uint256;

    /// @notice Proof system can be any contract with the appropriate interface, functionality
    function newProofSystem(address _proofSystem) external onlyGovernor {
        // KL todo add checks here
        require(!bridgeheadStorage.proofSystem[_proofSystem], "r35");
        bridgeheadStorage.proofSystem[_proofSystem] = true;
        bridgeheadStorage.totalProofSystems += 1;
    }

    /// @notice
    // KL todo make _chainId
    function newChain(
        uint256 _chainId,
        address _proofSystem,
        address _chainGovernor,
        IAllowList _allowList
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
                            block.timestamp,
                            msg.sender
                        )
                    )
                )
            );
        } else {
            chainId = _chainId;
        }
        // KL todo add checks here

        require(bridgeheadStorage.proofSystem[_proofSystem], "r19");
        require(bridgeheadStorage.chainContract[chainId] == address(0), "r20");

        bridgeheadStorage.totalChains += 1;
        bridgeheadStorage.chainProofSystem[chainId] = _proofSystem;

        bytes memory data = abi.encodeWithSelector(
            IBridgeheadChain.initialize.selector,
            chainId,
            _proofSystem,
            _chainGovernor,
            _allowList,
            bridgeheadStorage.priorityTxMaxGasLimit
        );
        TransparentUpgradeableProxy chainContract = new TransparentUpgradeableProxy(
            bridgeheadStorage.chainImplementation,
            bridgeheadStorage.chainProxyAdmin,
            data
        );
        bridgeheadStorage.chainContract[chainId] = address(chainContract);

        IProofForBridgehead(_proofSystem).newChain(chainId, address(chainContract), _chainGovernor);

        emit NewChain(uint16(chainId), address(chainContract), _proofSystem, msg.sender);
    }
}
