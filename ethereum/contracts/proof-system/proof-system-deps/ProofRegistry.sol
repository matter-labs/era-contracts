// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./ProofBase.sol";
import "../proof-system-interfaces/IProofRegistry.sol";
import "../l2-deps/ISystemContext.sol";
import "../../common/libraries/UncheckedMath.sol";

import "../../common/Messaging.sol";
import "../../common/Config.sol";
import "../../common/libraries/Diamond.sol";
import "../../common/libraries/L2ContractHelper.sol";
import "../../common/L2ContractAddresses.sol";

import "../../bridgehead/chain-interfaces/IBridgeheadChain.sol";

import "../chain-interfaces/IProofChain.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title Registry contract capable of handling new Hyperchains.
/// @author Matter Labs
contract ProofRegistry is ProofBase, IProofRegistry {
    using UncheckedMath for uint256;

    // we have to set the chainId, as blockhashzero is the same for all chains, and specifies the genesis chainId
    function _specialSetChainIdInVMTx(uint256 _chainId, address _chainContract) internal {
        WritePriorityOpParams memory params;

        params.sender = L2_FORCE_DEPLOYER_ADDR;
        params.l2Value = 0;
        params.contractAddressL2 = L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR;
        params.l2GasLimit = $(PRIORITY_TX_MAX_GAS_LIMIT);
        params.l2GasPricePerPubdata = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        params.refundRecipient = address(0);

        bytes memory setChainIdCalldata = abi.encodeCall(ISystemContext.setChainId, (_chainId));
        bytes[] memory emptyA;

        IBridgeheadChain(_chainContract).requestL2TransactionProof(params, setChainIdCalldata, emptyA, true);
    }

    /// @notice
    function newChain(
        uint256 _chainId,
        address _bridgeheadChainContract,
        address _governor
    ) external onlyBridgehead {
        bytes memory data = abi.encodeWithSelector(
            IProofChain.initialize.selector,
            _chainId,
            _bridgeheadChainContract,
            _governor,
            proofStorage.allowList,
            proofStorage.verifier,
            proofStorage.verifierParams,
            proofStorage.l2BootloaderBytecodeHash,
            proofStorage.l2DefaultAccountBytecodeHash,
            proofStorage.blockHashZero,
            proofStorage.priorityTxMaxGasLimit
        );
        TransparentUpgradeableProxy proofChainContract = new TransparentUpgradeableProxy(
            proofStorage.proofChainImplementation,
            proofStorage.proofChainProxyAdmin,
            data
        );

        IBridgeheadChain(_bridgeheadChainContract).setProofChainContract(address(proofChainContract));
        _specialSetChainIdInVMTx(_chainId, _bridgeheadChainContract);

        emit NewProofChain(_chainId, address(proofChainContract));
    }

    function leaveChain(uint256 chainID) external onlyBridgehead {}
}
