// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MigrationTestBase} from "foundry-test/l1/integration/unit-migration/_SharedMigrationBase.t.sol";
import {L1ContractDeployer} from "foundry-test/l1/integration/_SharedL1ContractDeployer.t.sol";

import {Governance} from "contracts/governance/Governance.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {Call} from "contracts/governance/Common.sol";
import {EventOnFallback} from "contracts/dev-contracts/EventOnFallback.sol";
import {Forwarder} from "contracts/dev-contracts/Forwarder.sol";
import {RevertFallback} from "contracts/dev-contracts/RevertFallback.sol";
import {EventOnFallbackTargetExpected} from "../../../../L1TestsErrors.sol";

contract GovernanceTest is MigrationTestBase, EventOnFallback {
    address internal owner;
    address internal securityCouncil;
    address internal randomSigner;
    Governance internal governance;
    EventOnFallback internal eventOnFallback;
    Forwarder internal forwarder;
    RevertFallback internal revertFallback;

    function setUp() public virtual override {
        super.setUp();

        owner = makeAddr("owner");
        securityCouncil = makeAddr("securityCouncil");
        randomSigner = makeAddr("randomSigner");

        governance = new Governance(owner, securityCouncil, 0);
        eventOnFallback = new EventOnFallback();
        forwarder = new Forwarder();
        revertFallback = new RevertFallback();

        vm.warp(100000000);
    }

    function executeOpAndCheck(IGovernance.Operation memory op) internal {
        _checkEventBeforeExecution(op);
        governance.execute(op);
    }

    function executeInstantOpAndCheck(IGovernance.Operation memory op) internal {
        _checkEventBeforeExecution(op);
        governance.executeInstant(op);
    }

    function _checkEventBeforeExecution(IGovernance.Operation memory op) private {
        for (uint256 i = 0; i < op.calls.length; i++) {
            if (op.calls[i].target != address(eventOnFallback)) {
                revert EventOnFallbackTargetExpected();
            }
            // Check event
            vm.expectEmit(false, false, false, true);
            emit Called(address(governance), op.calls[i].value, op.calls[i].data);
        }
    }

    function operationWithOneCallZeroSaltAndPredecessor(
        address _target,
        uint256 _value,
        bytes memory _data
    ) internal pure returns (IGovernance.Operation memory) {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: _target, value: _value, data: _data});
        return IGovernance.Operation({calls: calls, salt: bytes32(0), predecessor: bytes32(0)});
    }

    // Resolve test() from multiple base classes (EventOnFallback and L1ContractDeployer)
    function test() internal virtual override(EventOnFallback, L1ContractDeployer) {}

    // add this to be excluded from coverage report
    function testGovernanceShared() internal {}
}
