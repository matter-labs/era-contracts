// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CTMUpgrade_v34} from "deploy-scripts/upgrade/v34/CTMUpgrade_v34.s.sol";
import {CoreOnGatewayHelper} from "deploy-scripts/ecosystem/CoreOnGatewayHelper.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @dev Isolates payload construction from ecosystem deployment and bytecode publication.
contract UpgradeVerificationFixture is CTMUpgrade_v34 {
    function payload() external returns (address target, bytes memory data, uint256[] memory factoryDeps) {
        coreAddresses.bridgehub.proxies.ctmDeploymentTracker = address(this);
        (target, data) = getL2UpgradeTargetAndData(getUniversalForceDeployments());
        bytes[] memory bytecodes = CoreOnGatewayHelper.getFullListOfFactoryDependencies(
            getFactoryDependencyContracts()
        );
        factoryDeps = new uint256[](bytecodes.length);
        for (uint256 i; i < bytecodes.length; ++i) {
            factoryDeps[i] = uint256(keccak256(bytecodes[i]));
        }
    }
}

/// @dev The ignored Rust integration test consumes this compiler-generated payload.
contract UpgradeVerificationFixtureTest is Test {
    struct Fixture {
        bytes data;
        uint256[] factoryDeps;
    }

    function test_exportV34Payload() public {
        (address target, bytes memory data, uint256[] memory factoryDeps) = new UpgradeVerificationFixture().payload();
        assertEq(target, L2_COMPLEX_UPGRADER_ADDR);
        assertEq(bytes4(data), IComplexUpgrader.forceDeployAndUpgradeUniversal.selector);
        emit log_bytes(abi.encode(Fixture({data: data, factoryDeps: factoryDeps})));
    }
}
