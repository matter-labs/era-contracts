// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/console.sol";
import {Vm} from "forge-std/Test.sol";
import {Utils} from "../Utils/Utils.sol";
import {ExecutorTest} from "./_Executor_Shared.t.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {DummyChainTypeManagerForValidatorTimelock as DummyCTM} from "contracts/dev-contracts/test/DummyChainTypeManagerForValidatorTimelock.sol";

contract PrecommittingTest is ExecutorTest {
    ValidatorTimelock validatorTimelock;

    function setUp() public {
        DummyCTM chainTypeManager = new DummyCTM(owner, address(executor));
        validatorTimelock = ValidatorTimelock(_deployValidatorTimelock(owner, 0));

        vm.prank(owner);
        validatorTimelock.setChainTypeManager(IChainTypeManager(address(chainTypeManager)));

        vm.prank(owner);
        validatorTimelock.addValidator(eraChainId, validator);

        vm.prank(getters.getChainTypeManager());
        admin.setValidator(address(validatorTimelock), true);
    }

    function _deployValidatorTimelock(address _initialOwner, uint32 _initialExecutionDelay) internal returns (address) {
        ProxyAdmin admin = new ProxyAdmin();
        ValidatorTimelock timelockImplementation = new ValidatorTimelock();
        return
            address(
                new TransparentUpgradeableProxy(
                    address(timelockImplementation),
                    address(admin),
                    abi.encodeCall(ValidatorTimelock.initialize, (_initialOwner, _initialExecutionDelay))
                )
            );
    }

    function test_SuccessfullyPrecommit() public {
        uint256 totalTransactions = 1;
        uint256 batchNumber = 1;
        uint256 miniblockNumber = 18;

        IExecutor.TransactionStatusCommitment[] memory txs = new IExecutor.TransactionStatusCommitment[](totalTransactions);
        for (uint i = 0; i < totalTransactions; ++i) {
            txs[i] = IExecutor.TransactionStatusCommitment({
                txHash: keccak256(abi.encode(i)),
                status: i % 3 != 0
            });
        }

        IExecutor.PrecommitInfo memory precommitInfo = IExecutor.PrecommitInfo({
            txs: txs,
            untrustedLastMiniblockNumberHint: miniblockNumber
        });

        bytes memory precommitData = abi.encodePacked(
            BatchDecoder.SUPPORTED_ENCODING_VERSION,
            abi.encode(precommitInfo)
        );

        vm.prank(validator);
        vm.recordLogs();

        // executor.precommitSharedBridge(eraChainId, batchNumber, precommitData);
        validatorTimelock.precommitSharedBridge(eraChainId, batchNumber, precommitData);
        vm.lastCallGas();

        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(entries.length, 1);
        assertEq(entries[0].topics[0], keccak256("BatchPrecommitmentSet(uint256,uint256,bytes32)"));
        assertEq(entries[0].topics[1], bytes32(batchNumber));
        assertEq(entries[0].topics[2], bytes32(miniblockNumber));
    }
}
