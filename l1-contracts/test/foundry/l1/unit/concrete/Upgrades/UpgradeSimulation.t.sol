// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {UpgradeSimulation} from "dev/simulation/UpgradeSimulation.s.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

/// @notice The simulator probes need a chain at the CTM's protocol version; without one the
///         package is left without probes instead of failing the prepare.
/// @dev The CTM, the bridgehub and the chains are mocked: the script only reads their views, and
///      a CTM without an up-to-date chain would otherwise need a whole ecosystem deployment.
contract UpgradeSimulationTest is Test {
    string internal constant PACKAGE = "/script-out/upgrade-simulation-unit.toml";
    string internal constant PACKAGE_CONTENTS = "[governance_calls]\ncalls = []\n";
    address internal ctm = makeAddr("ctm");
    address internal bridgehub = makeAddr("bridgehub");
    uint256 internal ctmProtocolVersion = SemVer.packSemVer(0, 35, 0);
    string internal packagePath;

    function setUp() public {
        packagePath = string.concat(vm.projectRoot(), PACKAGE);
        vm.writeFile(packagePath, PACKAGE_CONTENTS);
        vm.setEnv("UPGRADE_SIMULATION_CTM", vm.toString(ctm));
        vm.setEnv("UPGRADE_SIMULATION_OUTPUT", packagePath);
        vm.mockCall(ctm, abi.encodeCall(IChainTypeManager.BRIDGE_HUB, ()), abi.encode(bridgehub));
        vm.mockCall(ctm, abi.encodeCall(IChainTypeManager.protocolVersion, ()), abi.encode(ctmProtocolVersion));
    }

    function test_writesNoProbesWhenTheCTMHasNoChains() public {
        _mockChains(new address[](0));

        new UpgradeSimulation().run();

        assertEq(vm.readFile(packagePath), PACKAGE_CONTENTS, "package changed");
    }

    /// @dev One chain of the CTM lags its version; the other is at the version but on another CTM.
    function test_writesNoProbesWhenNoChainOfTheCTMIsAtItsVersion() public {
        address[] memory chains = new address[](2);
        chains[0] = _mockChain("laggingChain", ctm, SemVer.packSemVer(0, 34, 0));
        chains[1] = _mockChain("foreignChain", makeAddr("otherCtm"), ctmProtocolVersion);
        _mockChains(chains);

        new UpgradeSimulation().run();

        assertEq(vm.readFile(packagePath), PACKAGE_CONTENTS, "package changed");
    }

    function _mockChains(address[] memory _chains) internal {
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.getAllZKChains, ()), abi.encode(_chains));
    }

    function _mockChain(string memory _name, address _ctm, uint256 _protocolVersion) internal returns (address chain) {
        chain = makeAddr(_name);
        vm.mockCall(chain, abi.encodeCall(IGetters.getChainTypeManager, ()), abi.encode(_ctm));
        vm.mockCall(chain, abi.encodeCall(IGetters.getProtocolVersion, ()), abi.encode(_protocolVersion));
    }
}
