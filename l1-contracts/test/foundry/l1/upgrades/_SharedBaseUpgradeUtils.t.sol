// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ZKChainBase} from "contracts/state-transition/chain-deps/facets/ZKChainBase.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {FeeParams} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";

/// @notice Test-only surface over an upgrade engine: diamond-storage setters/getters and routing
///         installation. Dummies that drive the shared storage part (`_upgrade`) directly add their
///         own `upgrade(...)` wrapper, so hand-built inputs the registry objects would never compose
///         can reach its checks.
abstract contract BaseUpgradeUtils is ZKChainBase {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    /// @notice Installs routing into this contract's diamond storage, standing in for the live
    ///         facets of the chain an engine is delegatecalled into.
    function applyFacetCuts(Diamond.FacetCut[] memory _facetCuts) external {
        Diamond.diamondCut(Diamond.DiamondCutData({facetCuts: _facetCuts, initAddress: address(0), initCalldata: ""}));
    }

    function facetAddress(bytes4 _selector) external view returns (address) {
        return Diamond.getDiamondStorage().selectorToFacet[_selector].facetAddress;
    }

    function setChainTypeManager(address _chainTypeManager) public virtual {
        s.chainTypeManager = _chainTypeManager;
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

    function setVerifier(address _verifier) public {
        s.verifier = IVerifier(_verifier);
    }

    function setBridgehub(address _bridgehub) public {
        s.bridgehub = _bridgehub;
    }

    function setChainId(uint256 _chainId) public {
        s.chainId = _chainId;
    }

    function setZKsyncOS(bool _zksyncOS) public {
        s.zksyncOS = _zksyncOS;
    }

    function setBatchCounters(uint256 _committed, uint256 _executed) public {
        s.totalBatchesCommitted = _committed;
        s.totalBatchesExecuted = _executed;
    }

    function getProtocolVersion() public view returns (uint256) {
        return s.protocolVersion;
    }

    function getVerifier() public view returns (address) {
        return address(s.verifier);
    }

    function getL2SystemContractsUpgradeTxHash() public view returns (bytes32) {
        return s.l2SystemContractsUpgradeTxHash;
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

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
