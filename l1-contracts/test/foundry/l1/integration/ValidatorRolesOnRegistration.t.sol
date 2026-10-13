// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IValidatorTimelock} from "contracts/state-transition/validators/interfaces/IValidatorTimelock.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";

/// Validator roles handed out by RegisterZKChain.s.sol. One chain is registered without a
/// dedicated reverter, one with `validator_sender_operator_reverter` set. Explicit chain ids keep
/// this suite off the config files the other suites write concurrently (ids 10 and up).
contract ValidatorRolesOnRegistrationTests is L1ContractDeployer, ZKChainDeployer, TokenDeployer {
    uint256 internal constant CHAIN_WITHOUT_REVERTER = 917100;
    uint256 internal constant CHAIN_WITH_REVERTER = 917101;
    address internal constant ETH_OPERATOR = address(0);
    address internal constant PROVE_OPERATOR = address(2);
    address internal constant DEDICATED_REVERTER = address(4);

    IValidatorTimelock internal timelock;

    function setUp() public {
        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);
        _deployEra();
        _deployZKChainWithPausedDeposits(ETH_TOKEN_ADDRESS, CHAIN_WITHOUT_REVERTER);
        _deployZKChainWithReverter(ETH_TOKEN_ADDRESS, CHAIN_WITH_REVERTER, DEDICATED_REVERTER);
        timelock = IValidatorTimelock(ctmAddresses.stateTransition.proxies.validatorTimelock);
    }

    function test_reverterStaysOnEthOperatorWithoutDedicatedReverter() public view {
        bytes32 reverterRole = timelock.REVERTER_ROLE();
        assertTrue(timelock.hasRoleForChainId(CHAIN_WITHOUT_REVERTER, reverterRole, ETH_OPERATOR));
        assertFalse(timelock.hasRoleForChainId(CHAIN_WITHOUT_REVERTER, reverterRole, DEDICATED_REVERTER));
    }

    function test_dedicatedReverterGetsReverterRoleOnly() public view {
        bytes32 reverterRole = timelock.REVERTER_ROLE();
        assertTrue(timelock.hasRoleForChainId(CHAIN_WITH_REVERTER, reverterRole, DEDICATED_REVERTER));
        assertFalse(timelock.hasRoleForChainId(CHAIN_WITH_REVERTER, reverterRole, ETH_OPERATOR));
        assertFalse(timelock.hasRoleForChainId(CHAIN_WITH_REVERTER, timelock.PROVER_ROLE(), DEDICATED_REVERTER));
        assertFalse(timelock.hasRoleForChainId(CHAIN_WITH_REVERTER, timelock.EXECUTOR_ROLE(), DEDICATED_REVERTER));
        assertFalse(timelock.hasRoleForChainId(CHAIN_WITH_REVERTER, timelock.COMMITTER_ROLE(), DEDICATED_REVERTER));
    }

    function test_proveOperatorKeepsProverRoleWithDedicatedReverter() public view {
        assertTrue(timelock.hasRoleForChainId(CHAIN_WITH_REVERTER, timelock.PROVER_ROLE(), PROVE_OPERATOR));
    }
}
