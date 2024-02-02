// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./EvmConstants.sol";

// blake2f at address 0x9 is currently the last precompile
uint160 constant PRECOMPILES_END = 0x0a;

// Denotes that passGas has been consumed
uint256 constant INF_PASS_GAS = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

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

    // We dont care about the size, since none of it will be stored/pub;ushed anywya
    struct EVMStackFrameInfo {
        uint256 passGas;
        // uint256 returnGas;
    }

    /*

    The flow is the following:

    When conducting call:
        1. caller calls to an EVM contract pushEVMFrame with the corresponding gas
        2. callee calls consumePassGas to get the gas & make sure that subsequent callee wont be able to read it.
        3. callee sets the return gas
        4. callee calls popEVMFrame to return the gas to the caller & remove the frame

    */

    EVMStackFrameInfo[] private evmStackFrames;

    function pushEVMFrame(uint256 _passGas) external {
        EVMStackFrameInfo memory frame = EVMStackFrameInfo({
            passGas: _passGas
            // returnGas: 0
        });

        evmStackFrames.push(frame);
    }

    function consumePassGas() external returns (uint256 passGas) {
        if (evmStackFrames.length == 0) return INF_PASS_GAS;

        passGas = evmStackFrames[evmStackFrames.length - 1].passGas;

        evmStackFrames[evmStackFrames.length - 1].passGas = INF_PASS_GAS;
    }

    // function setReturnGas(uint256 _returnGas) external {
    //     evmStackFrames[evmStackFrames.length - 1].returnGas = _returnGas;
    // }

    function popEVMFrame() external {
        // EVMStackFrameInfo memory frame = evmStackFrames[evmStackFrames.length - 1];
        evmStackFrames.pop();
        // return frame.returnGas;
    }
}
