// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";

import {UpgradeIntegrationReleaseFixture} from "../UpgradeTest_Local.t.sol";
import {ProtocolUpgradeHandlerFreezeDouble} from "./_EmergencyGovernanceDoubles.sol";

/// @notice The Security Council's chain freeze against the ecosystem the release edge leaves
///         behind: the CTM is owned by its `CTMUpgradeExecutor`, and the `ProtocolUpgradeHandler`
///         reaches its chains as the Bridgehub's owner
///         ({protocol-docs/ecosystem-upgrade-coordination.md#freezing-a-chain}).
/// @dev The handler is a double because zk-governance is not vendored here: it restates the
///      handler's per-chain freeze and unfreeze calls. The upgrade, the Bridgehub, the CTM and the
///      chains are real. As in production, the handler owns the CTM executor; whether it owns the
///      Bridgehub is what each test sets.
contract SecurityCouncilFreezeTest is UpgradeIntegrationReleaseFixture {
    address internal bridgehub;
    address internal ctm;
    address internal ctmExecutor;
    ProtocolUpgradeHandlerFreezeDouble internal handler;

    function setUp() public override {
        super.setUp();
        bridgehub = coreUpgrade.getDiscoveredBridgehub().proxies.bridgehub;
        ctm = ctmUpgrade.getCTMAddress();
        ctmExecutor = IOwnable(ctm).owner();
        handler = new ProtocolUpgradeHandlerFreezeDouble(IBridgehubBase(bridgehub), ctm);
        _handToTheHandler(ctmExecutor);

        assertEq(IOwnable(ctmExecutor).owner(), address(handler), "the handler governs the CTM executor");
        assertTrue(IOwnable(ctm).owner() != address(handler), "the upgrade left the CTM with its executor");
        assertGt(_chainsOnTheCTM().length, 0, "fixture: the CTM has chains");
    }

    /// @dev A two-step ownership transfer from `_target`'s current owner; the handler's acceptance
    ///      is a proposal call in production, pranked here.
    function _handToTheHandler(address _target) internal {
        vm.prank(IOwnable(_target).owner());
        IOwnable(_target).transferOwnership(address(handler));
        vm.prank(address(handler));
        IOwnable(_target).acceptOwnership();
    }

    function _chainsOnTheCTM() internal view returns (address[] memory diamonds) {
        uint256[] memory ids = IBridgehubBase(bridgehub).getAllZKChainChainIDs();
        uint256 count = 0;
        for (uint256 i = 0; i < ids.length; ++i) {
            if (IBridgehubBase(bridgehub).chainTypeManager(ids[i]) == ctm) {
                ++count;
            }
        }
        diamonds = new address[](count);
        count = 0;
        for (uint256 i = 0; i < ids.length; ++i) {
            if (IBridgehubBase(bridgehub).chainTypeManager(ids[i]) == ctm) {
                diamonds[count] = IBridgehubBase(bridgehub).getZKChain(ids[i]);
                ++count;
            }
        }
    }

    function _assertFrozen(address[] memory _diamonds, bool _frozen, string memory _what) internal view {
        for (uint256 i = 0; i < _diamonds.length; ++i) {
            assertEq(IGetters(_diamonds[i]).isDiamondStorageFrozen(), _frozen, _what);
        }
    }

    /// @notice The soft/hard freeze and the unfreeze (and the unfreeze that opens an emergency
    ///         upgrade) reach every chain of the executor-owned CTM.
    function test_theHandlerFreezesAndUnfreezesEveryChainOfTheExecutorOwnedCTM() public {
        _handToTheHandler(bridgehub);
        address[] memory diamonds = _chainsOnTheCTM();
        _assertFrozen(diamonds, false, "nothing is frozen before");

        for (uint256 i = 0; i < diamonds.length; ++i) {
            vm.expectEmit(true, true, true, true, diamonds[i]);
            emit IAdmin.Freeze();
        }
        handler.freezeChains();
        _assertFrozen(diamonds, true, "the freeze reached every chain");

        for (uint256 i = 0; i < diamonds.length; ++i) {
            vm.expectEmit(true, true, true, true, diamonds[i]);
            emit IAdmin.Unfreeze();
        }
        handler.unfreezeChains();
        _assertFrozen(diamonds, false, "the unfreeze reached every chain");
        assertEq(IOwnable(ctm).owner(), ctmExecutor, "the CTM stays with its executor");
    }

    /// @notice The single-chain reinforcements, which revert visibly in the handler too.
    function test_theHandlerReinforcesOneChain() public {
        _handToTheHandler(bridgehub);
        address diamond = IBridgehubBase(bridgehub).getZKChain(chainId);
        assertEq(IBridgehubBase(bridgehub).chainTypeManager(chainId), ctm);

        handler.reinforceFreezeOneChain(chainId);
        assertTrue(IGetters(diamond).isDiamondStorageFrozen());
        handler.reinforceUnfreezeOneChain(chainId);
        assertFalse(IGetters(diamond).isDiamondStorageFrozen());
    }

    /// @notice Owning the CTM executor is not what lets the handler freeze: without the Bridgehub
    ///         the CTM refuses it, which the real handler's `try/catch` would swallow.
    function test_revertWhen_theHandlerDoesNotOwnTheBridgehub() public {
        assertTrue(IOwnable(bridgehub).owner() != address(handler));
        address[] memory diamonds = _chainsOnTheCTM();

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(handler)));
        handler.freezeChains();
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(handler)));
        handler.reinforceFreezeOneChain(chainId);
        _assertFrozen(diamonds, false, "no chain was frozen");
    }
}
