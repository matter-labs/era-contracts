// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ZKChainBase} from "contracts/state-transition/chain-deps/facets/ZKChainBase.sol";
import {FeeParams} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

contract BaseUpgradeUtils is ZKChainBase {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    function setChainTypeManager(address _chainTypeManager) public virtual {
        s.chainTypeManager = _chainTypeManager;
    }

    function mockProtocolVersionVerifier(uint256 _protocolVersion, address _verifier) public {
        vm.mockCall(
            s.chainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.protocolVersionVerifier.selector, _protocolVersion),
            abi.encode(_verifier)
        );
    }
    function setL2SystemContractsUpgradeTxHash(bytes32 _l2SystemContractsUpgradeTxHash) public {
        s.l2SystemContractsUpgradeTxHash = _l2SystemContractsUpgradeTxHash;
    }

    function setL2SystemContractsUpgradeBatchNumber(uint256 _l2SystemContractsUpgradeBatchNumber) public {
        s.l2SystemContractsUpgradeBatchNumber = _l2SystemContractsUpgradeBatchNumber;
    }

    function setPriorityTxMaxGasLimit(uint256 _priorityTxMaxGasLimit) public {
        s.priorityTxMaxGasLimit = _priorityTxMaxGasLimit;
    }

    function setPriorityTxMaxPubdata(uint32 _priorityTxMaxPubdata) public {
        s.feeParams.priorityTxMaxPubdata = _priorityTxMaxPubdata;
    }

    function setProtocolVersion(uint256 _protocolVersion) public {
        s.protocolVersion = _protocolVersion;
    }

    function getProtocolVersion() public view returns (uint256) {
        return s.protocolVersion;
    }

    function getVerifier() public view returns (address) {
        return address(s.verifier);
    }

    function getFeeParams() public view returns (FeeParams memory) {
        return s.feeParams;
    }

    function getChainId() public view returns (uint256) {
        return s.chainId;
    }

    function getBridgeHub() public view returns (address) {
        return s.bridgehub;
    }

    function getSharedBridge() public view returns (address) {
        return s.__DEPRECATED_baseTokenBridge;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
