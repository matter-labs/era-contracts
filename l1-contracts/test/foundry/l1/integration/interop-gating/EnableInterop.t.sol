// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {ProofSystem, ZKSYNC_OS_PLONK_VERIFICATION_TYPE} from "contracts/common/Config.sol";
import {NotMultiProofMode, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {
    ChainNotSettlingOnL1,
    InteropAlreadyEnabled,
    SecondProofSystemNotLocked,
    ZKChainNotRegistered
} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

import {InteropGatingDeployer} from "../_SharedInteropGatingDeployer.t.sol";

/// @notice `L1MessageRoot.enableInterop` and its preconditions. See
/// {protocol-docs/interop-gating.md#enabling-interop}.
contract EnableInteropTest is InteropGatingDeployer {
    uint256 internal constant UNREGISTERED_CHAIN_ID = 123456;
    uint256 internal constant GATEWAY_CHAIN_ID = 506;

    uint256 internal chainId;
    address internal chain;
    address internal governance;

    function setUp() public {
        _deployInteropGatingEcosystem();
        chainId = zkChainIds[0];
        chain = getZKChainAddress(chainId);
        governance = addresses.bridgehubOwnerAddress;
    }

    function test_enableInterop() public {
        _lockSecondProofSystem(chainId);

        vm.expectEmit(true, true, true, true, address(messageRoot));
        emit IL1MessageRoot.InteropEnabled(chainId);
        vm.prank(governance);
        messageRoot.enableInterop(chainId, true);

        assertTrue(messageRoot.isInteropEnabled(chainId));
        assertFalse(messageRoot.isInteropEnabled(zkChainIds[1]), "other chains stay disabled");
    }

    /// @notice Governance may enable a chain it trusts for reasons checked offchain: without the flag, a chain
    /// that neither locked its second proof system nor runs in multi-proof mode is enabled.
    function test_enableInterop_withoutSecondProofSystem() public {
        vm.prank(_chainAdmin(chainId));
        IAdmin(chain).setProofSystemStatus(ProofSystem.Zisk, false);

        vm.expectEmit(true, true, true, true, address(messageRoot));
        emit IL1MessageRoot.InteropEnabled(chainId);
        vm.prank(governance);
        messageRoot.enableInterop(chainId, false);

        assertTrue(messageRoot.isInteropEnabled(chainId));
        assertFalse(IGetters(chain).isSecondProofSystemLocked(), "the chain stays unlocked");
        assertEq(IGetters(chain).getProofMode(), ZKSYNC_OS_PLONK_VERIFICATION_TYPE, "the chain stays single-proof");
    }

    /// @notice Enabling is one-way: a later emergency ZiSK-off leaves the chain enabled, and it can't be
    /// enabled again.
    function test_enableInterop_isOneWay() public {
        _enableInterop(chainId);
        vm.prank(governance);
        IAdmin(chain).setProofSystemStatus(ProofSystem.Zisk, false);
        assertTrue(messageRoot.isInteropEnabled(chainId));

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(InteropAlreadyEnabled.selector, chainId));
        messageRoot.enableInterop(chainId, false);
    }

    function test_enableInterop_revertWhen_notGovernance() public {
        _lockSecondProofSystem(chainId);
        address chainAdmin = makeAddr("chainAdmin");
        vm.prank(_chainAdmin(chainId));
        IAdmin(chain).setPendingAdmin(chainAdmin);
        vm.prank(chainAdmin);
        IAdmin(chain).acceptAdmin();

        _expectEnableInteropRevert(chainAdmin, chainId, abi.encodeWithSelector(Unauthorized.selector, chainAdmin));
    }

    function test_enableInterop_revertWhen_chainNotRegistered() public {
        _expectEnableInteropRevert(
            governance,
            UNREGISTERED_CHAIN_ID,
            abi.encodeWithSelector(ZKChainNotRegistered.selector)
        );
    }

    /// @dev The Bridgehub's settlement layer is mocked: moving the chain off L1 needs a Gateway, which this
    /// suite stays clear of.
    function test_enableInterop_revertWhen_notSettlingOnL1() public {
        _lockSecondProofSystem(chainId);
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeCall(IBridgehubBase.settlementLayer, (chainId)),
            abi.encode(GATEWAY_CHAIN_ID)
        );

        _expectEnableInteropRevert(
            governance,
            chainId,
            abi.encodeWithSelector(ChainNotSettlingOnL1.selector, chainId, GATEWAY_CHAIN_ID)
        );
    }

    function test_enableInterop_revertWhen_secondProofSystemNotLocked() public {
        _expectEnableInteropRevert(
            governance,
            chainId,
            abi.encodeWithSelector(SecondProofSystemNotLocked.selector, chainId)
        );
    }

    /// @notice A locked chain that runs on a single prover after an emergency ZiSK-off can't be enabled.
    function test_enableInterop_revertWhen_notMultiProofMode() public {
        _lockSecondProofSystem(chainId);
        vm.prank(governance);
        IAdmin(chain).setProofSystemStatus(ProofSystem.Zisk, false);

        _expectEnableInteropRevert(
            governance,
            chainId,
            abi.encodeWithSelector(NotMultiProofMode.selector, ZKSYNC_OS_PLONK_VERIFICATION_TYPE)
        );
    }

    /// @dev A diamond whose facets predate the lock has no `isSecondProofSystemLocked`, so the proxy reverts
    /// with "F". The getter is mocked to revert that way, isolating the old facet set.
    function test_enableInterop_revertWhen_oldDiamond() public {
        vm.mockCallRevert(chain, abi.encodeCall(IGetters.isSecondProofSystemLocked, ()), bytes("F"));

        _expectEnableInteropRevert(governance, chainId, bytes("F"));
    }

    /// @dev Without the flag the getter missing on an old diamond is never read, so such a chain can be enabled.
    function test_enableInterop_withoutSecondProofSystem_oldDiamond() public {
        vm.mockCallRevert(chain, abi.encodeCall(IGetters.isSecondProofSystemLocked, ()), bytes("F"));

        vm.prank(governance);
        messageRoot.enableInterop(chainId, false);

        assertTrue(messageRoot.isInteropEnabled(chainId));
    }

    function testFuzz_isInteropEnabled_unknownChain(uint256 _chainId) public view {
        vm.assume(_chainId != chainId && _chainId != zkChainIds[1]);
        assertFalse(messageRoot.isInteropEnabled(_chainId));
    }

    function _expectEnableInteropRevert(address _caller, uint256 _chainId, bytes memory _revertData) internal {
        vm.prank(_caller);
        vm.expectRevert(_revertData);
        messageRoot.enableInterop(_chainId, true);
        assertFalse(messageRoot.isInteropEnabled(_chainId));
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
