// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PermissionlessValidator} from "contracts/state-transition/validators/PermissionlessValidator.sol";
import {Reentrancy} from "contracts/common/L1ContractErrors.sol";
import {ExecutorMock} from "./ExecutorMock.sol";
import {ReentrantExecutorMock} from "./ReentrantExecutorMock.sol";

contract PermissionlessValidatorTest is Test {
    PermissionlessValidator internal validator;
    ExecutorMock internal executor;
    address internal proxyAdmin = makeAddr("proxyAdmin");

    function setUp() public {
        PermissionlessValidator implementation = new PermissionlessValidator();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdmin,
            abi.encodeCall(PermissionlessValidator.initialize, ())
        );
        validator = PermissionlessValidator(address(proxy));
        executor = new ExecutorMock();
    }

    function test_settleBatchesSharedBridge_commitsProvesAndExecutes() public {
        uint256 processFrom = 3;
        uint256 processTo = 7;
        bytes memory commitData = abi.encode("commit", uint256(11));
        bytes memory proveData = abi.encode("prove", uint256(12));
        bytes memory executeData = abi.encode("execute", uint256(13));

        validator.settleBatchesSharedBridge(
            address(executor),
            processFrom,
            processTo,
            commitData,
            proveData,
            executeData
        );

        assertEq(executor.callIndex(), 3);

        assertEq(executor.commitChainAddress(), address(executor));
        assertEq(executor.commitProcessFrom(), processFrom);
        assertEq(executor.commitProcessTo(), processTo);
        assertEq(executor.commitData(), commitData);

        assertEq(executor.proveChainAddress(), address(executor));
        assertEq(executor.proveProcessFrom(), processFrom);
        assertEq(executor.proveProcessTo(), processTo);
        assertEq(executor.proveData(), proveData);

        assertEq(executor.executeChainAddress(), address(executor));
        assertEq(executor.executeProcessFrom(), processFrom);
        assertEq(executor.executeProcessTo(), processTo);
        assertEq(executor.executeData(), executeData);
    }

    function test_settleBatchesSharedBridge_revertsOnReentrancy() public {
        ReentrantExecutorMock reentrantExecutor = new ReentrantExecutorMock(validator);

        uint256 processFrom = 1;
        uint256 processTo = 2;
        bytes memory commitData = hex"aa";
        bytes memory proveData = hex"bb";
        bytes memory executeData = hex"cc";

        reentrantExecutor.setReenterPayload(proveData, executeData);

        vm.expectRevert(Reentrancy.selector);
        validator.settleBatchesSharedBridge(
            address(reentrantExecutor),
            processFrom,
            processTo,
            commitData,
            proveData,
            executeData
        );
    }
}
