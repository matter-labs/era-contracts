// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./EvmConstants.sol";

// blake2f at address 0x9 is currently the last precompile
uint160 constant PRECOMPILES_END = 0x0a;

contract EvmGasManager {
    mapping(address => bool) private warmAccounts;
    mapping(address => mapping(uint256 => bool)) private warmSlots;

    bytes latestReturndata;

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
}
