// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./EvmConstants.sol";

// import "hardhat/console.sol";

// blake2f at address 0x9 is currently the last precompile
uint160 constant PRECOMPILES_END = 0x0a;

contract EvmGasManager {
    // TODO: all storage here should be temporary storage once supported
    mapping(uint256 /*frameId*/ => uint256) private gasRecord;
    mapping(address => bool) private warmAccounts;
    mapping(address => mapping(uint256 => bool)) private warmSlots;

    uint256 private frameId;

    bytes private returnBuffer;

    modifier onlySystemEvm() {
        // TODO: uncomment
        //require(ContractDeployer.isEVM(msg.sender), "only system evm");
        _;
    }

    /*
        returns true if the account was already warm
    */
    function warmAccount(address account) external payable onlySystemEvm returns (bool wasWarm) {
        if (uint160(account) < PRECOMPILES_END) return true;

        wasWarm = warmAccounts[account];
        if (!wasWarm) warmAccounts[account] = true;
    }

    function warmSlot(uint256 slot) external payable onlySystemEvm returns (bool wasWarm) {
        wasWarm = warmSlots[msg.sender][slot];
        if (!wasWarm) warmSlots[msg.sender][slot] = true;
    }

    function pushGasLeft(uint256 gasLeft) external payable onlySystemEvm {
        // TODO: shift gasleft() too (ergs)
        gasRecord[++frameId] = gasLeft;
    }

    function reportGasLeft(uint256 gasLeft) external payable onlySystemEvm {
        gasRecord[frameId] = gasLeft;
    }

    function getGasLeft() external view returns (uint256 gasLeft) {
        uint256 id = frameId;
        if (id == 0) {
            return gasleft() / GAS_DIVISOR;
        }

        return gasRecord[id];
    }

    function popGasLeft() external payable onlySystemEvm returns (uint256 gasLeft) {
        uint256 id = frameId;
        if (id == 0) {
            return gasleft() / GAS_DIVISOR;
        }

        // TODO: should gasRecords be cleared? ideally use TSTORE instead...
        frameId--;
        gasLeft = gasRecord[id];
    }

    function setReturnBuffer(bytes calldata buffer) external onlySystemEvm {
        returnBuffer = buffer;
    }

    function returnDataCopy() external view returns (bytes memory) {
        return returnBuffer;
    }
}
