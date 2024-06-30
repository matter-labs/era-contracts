// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";

library Utils {
    // Cheatcodes address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    function executeUpgrade(
        address _governor,
        bytes32 _salt,
        address _target,
        bytes memory _data,
        uint256 _value,
        uint256 _delay
    ) internal {
        IGovernance governance = IGovernance(_governor);

        IGovernance.Call[] memory calls = new IGovernance.Call[](1);
        calls[0] = IGovernance.Call({target: _target, value: _value, data: _data});

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: _salt
        });

        vm.startBroadcast(Ownable(_governor).owner());
        governance.scheduleTransparent(operation, _delay);
        if (_delay == 0) {
            governance.execute{value: _value}(operation);
        }
        vm.stopBroadcast();
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
