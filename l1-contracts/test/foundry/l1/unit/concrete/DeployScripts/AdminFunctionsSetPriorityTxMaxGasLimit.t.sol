// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {AdminFunctions} from "deploy-scripts/AdminFunctions.s.sol";
import {IAdminFunctions} from "contracts/script-interfaces/IAdminFunctions.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Call} from "contracts/governance/Common.sol";
import {MAX_GAS_PER_TRANSACTION} from "contracts/common/Config.sol";

/// @notice Exposes the internal call builder so the emitted calldata can be asserted on directly.
contract AdminFunctionsHarness is AdminFunctions {
    function buildSetPriorityTxMaxGasLimitCalls(
        address _bridgehub,
        uint256[] calldata _chainIds,
        uint256 _newPriorityTxMaxGasLimit
    ) external view returns (address, Call[] memory) {
        return _buildSetPriorityTxMaxGasLimitCalls(_bridgehub, _chainIds, _newPriorityTxMaxGasLimit);
    }
}

/// @notice Shared mocks. The Admin facet setter and the CTM forwarder are already covered by
/// `Admin/SetPriorityTxMaxGasLimit.t.sol` and `ChainTypeManagerSetters.t.sol`; what is pinned here is
/// the script's own resolution and batching.
abstract contract SetPriorityTxMaxGasLimitBase is Test {
    uint256 internal constant NEW_LIMIT = 15_000_000;

    AdminFunctionsHarness internal adminFunctions;

    address internal bridgehub = makeAddr("bridgehub");
    address internal governance = makeAddr("governance");
    address internal otherGovernance = makeAddr("otherGovernance");
    address internal ctmA = makeAddr("ctmA");
    address internal ctmB = makeAddr("ctmB");

    function setUp() public virtual {
        adminFunctions = new AdminFunctionsHarness();
    }

    /// Register `_chainId` on the mocked bridgehub as belonging to `_ctm`, owned by `_owner`.
    function _mockChain(uint256 _chainId, address _ctm, address _owner) internal {
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.chainTypeManager, (_chainId)), abi.encode(_ctm));
        vm.mockCall(_ctm, abi.encodeWithSignature("owner()"), abi.encode(_owner));
    }

    function _chainIds(uint256 _a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = _a;
    }

    function _chainIds(uint256 _a, uint256 _b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = _a;
        ids[1] = _b;
    }
}

contract AdminFunctionsSetPriorityTxMaxGasLimitTest is SetPriorityTxMaxGasLimitBase {
    /// Chains on different CTMs share a batch when the owner matches; each call keeps its own CTM.
    function test_emitsOneCallPerChainTargetingItsCtm() public {
        _mockChain(271, ctmA, governance);
        _mockChain(324, ctmB, governance);

        (address executor, Call[] memory calls) = adminFunctions.buildSetPriorityTxMaxGasLimitCalls(
            bridgehub,
            _chainIds(271, 324),
            NEW_LIMIT
        );

        assertEq(executor, governance, "batch must be executable by the CTM owner");
        assertEq(calls.length, 2, "one call per chain");
        assertEq(calls[0].target, ctmA, "first call must go to the first chain's CTM");
        assertEq(calls[1].target, ctmB, "second call must go to the second chain's CTM");
        assertEq(calls[0].value, 0, "calls are zero-value");
        assertEq(calls[0].data, abi.encodeCall(IChainTypeManager.setPriorityTxMaxGasLimit, (271, NEW_LIMIT)));
        assertEq(calls[1].data, abi.encodeCall(IChainTypeManager.setPriorityTxMaxGasLimit, (324, NEW_LIMIT)));
    }

    /// A single executor is recorded, so mixed owners would leave half the batch reverting.
    function test_revertsWhenChainsSpanDifferentCtmOwners() public {
        _mockChain(271, ctmA, governance);
        _mockChain(324, ctmB, otherGovernance);

        vm.expectRevert(bytes("Chains span multiple CTM owners"));
        adminFunctions.buildSetPriorityTxMaxGasLimitCalls(bridgehub, _chainIds(271, 324), NEW_LIMIT);
    }

    /// An unregistered chain resolves to address(0), where a call would silently do nothing.
    function test_revertsWhenChainIsNotRegistered() public {
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.chainTypeManager, (999)), abi.encode(address(0)));

        vm.expectRevert(bytes("Chain is not registered: 999"));
        adminFunctions.buildSetPriorityTxMaxGasLimitCalls(bridgehub, _chainIds(999), NEW_LIMIT);
    }

    /// The Admin facet only rejects these at execution time, after governance has signed.
    function test_revertsOnLimitOutOfRange() public {
        _mockChain(271, ctmA, governance);

        vm.expectRevert(bytes("Priority tx max gas limit out of range"));
        adminFunctions.buildSetPriorityTxMaxGasLimitCalls(bridgehub, _chainIds(271), MAX_GAS_PER_TRANSACTION + 1);

        vm.expectRevert(bytes("Priority tx max gas limit out of range"));
        adminFunctions.buildSetPriorityTxMaxGasLimitCalls(bridgehub, _chainIds(271), 0);
    }

    function test_revertsOnEmptyChainList() public {
        vm.expectRevert(bytes("No chains provided"));
        adminFunctions.buildSetPriorityTxMaxGasLimitCalls(bridgehub, new uint256[](0), NEW_LIMIT);
    }

    /// A function missing from `IAdminFunctions` is unreachable from the zkstack CLI.
    function test_interfaceExposesTheSameSelector() public pure {
        assertEq(
            IAdminFunctions.setPriorityTxMaxGasLimit.selector,
            AdminFunctions.setPriorityTxMaxGasLimit.selector,
            "IAdminFunctions is out of sync with AdminFunctions"
        );
    }
}

/// @dev Own contract: `saveOutput`'s JSON is cached per forge process, so only the first payload
/// written reaches disk — at most one entrypoint-calling test per contract.
contract AdminFunctionsSetPriorityTxMaxGasLimitOutputTest is SetPriorityTxMaxGasLimitBase {
    using stdToml for string;

    /// Saved before the send is attempted, so an undrivable governance shape loses no calldata.
    function test_savesCalldataUnderCtmOwnerEvenWhenSendReverts() public {
        _mockChain(271, ctmA, governance);
        vm.mockCallRevert(governance, abi.encodeWithSignature("owner()"), "");

        try adminFunctions.setPriorityTxMaxGasLimit(bridgehub, _chainIds(271), NEW_LIMIT, true) {
            revert("expected the send to revert");
        } catch {}

        string memory toml = vm.readFile(string.concat(vm.projectRoot(), "/script-out/output-admin-functions.toml"));
        assertEq(toml.readAddress("$.admin_address"), governance, "saved executor must be the CTM owner");
        assertEq(
            abi.decode(toml.readBytes("$.encoded_data"), (Call[]))[0].data,
            abi.encodeCall(IChainTypeManager.setPriorityTxMaxGasLimit, (271, NEW_LIMIT)),
            "saved calldata must match the emitted calls"
        );
    }
}

/// @dev Separate contract for the same reason as above.
contract AdminFunctionsSetPriorityTxMaxGasLimitSendTest is SetPriorityTxMaxGasLimitBase {
    /// `_shouldSend` must drive `owner()` -> `scheduleTransparent` -> `execute`, not
    /// `ChainAdmin.multicall`, which governance does not expose.
    function test_shouldSend_executesThroughGovernanceRoute() public {
        _mockChain(271, ctmA, governance);

        bytes memory schedule = abi.encodeWithSignature(
            "scheduleTransparent(((address,uint256,bytes)[],bytes32,bytes32),uint256)"
        );
        bytes memory execute = abi.encodeWithSignature("execute(((address,uint256,bytes)[],bytes32,bytes32))");

        vm.mockCall(governance, abi.encodeWithSignature("owner()"), abi.encode(makeAddr("govOwner")));
        vm.mockCall(governance, schedule, "");
        vm.mockCall(governance, execute, "");

        vm.expectCall(governance, schedule);
        vm.expectCall(governance, execute);

        adminFunctions.setPriorityTxMaxGasLimit(bridgehub, _chainIds(271), NEW_LIMIT, true);
    }
}
