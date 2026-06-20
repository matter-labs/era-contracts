// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {stdToml} from "forge-std/StdToml.sol";

contract ConfigSemaphore is Script {
    using stdToml for string;

    string lockPath = "/test/foundry/l1/integration/deploy-scripts/script-config/.lock";

    /// @dev Acquire lock to prevent race condition
    /// Note that this implementation is not ideal, but should be good enough for the most cases
    /// TODO: replace with proper scripts/tests refactoring
    function takeConfigLock() public {
        string memory path = string.concat(vm.projectRoot(), lockPath);

        uint256 attempts;
        while (vm.exists(path)) {
            vm.sleep(1000);
            attempts++;

            if (attempts >= 60) {
                revert("Can't acquire config lock");
            }
        }

        vm.writeFile(path, "lock");
    }

    function releaseConfigLock() public {
        string memory path = string.concat(vm.projectRoot(), lockPath);
        if (vm.exists(path)) {
            try vm.removeFile(path) {
                // Successfully removed
            } catch {
                // Do nothing, hopefully it is removed already
            }
        }
    }
}
