// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {ProofSystem, ZKSYNC_OS_PLONK_VERIFICATION_TYPE} from "contracts/common/Config.sol";
import {NotMultiProofMode, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {L1SloadRequiredByInterop} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {
    InteropAlreadyEnabled,
    L1SloadNotEnabled,
    SecondProofSystemNotRequired,
    ZKChainNotRegistered
} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

import {InteropGatingDeployer} from "../_SharedInteropGatingDeployer.t.sol";

/// @notice `L1MessageRoot.enableInterop` and its preconditions. See
/// {protocol-docs/interop-gating.md#enabling-interop}.
contract EnableInteropTest is InteropGatingDeployer {
    uint256 internal constant UNREGISTERED_CHAIN_ID = 123456;

    uint256 internal chainId;
    address internal chain;
    address internal governance;

    function setUp() public {
        _deployInteropGatingEcosystem();
        chainId = zkChainIds[0];
        chain = getZKChainAddress(chainId);
        governance = addresses.bridgehubOwnerAddress;
        _enableL1Sload(chainId);
    }

    /// @notice A chain must read L1 with L1SLOAD before it can be enabled: interop gating depends on it.
    /// See {protocol-docs/l1sload.md#chain-config-flag}.
    function test_enableInterop_revertWhen_l1SloadNotEnabled() public {
        uint256 otherChainId = zkChainIds[1];
        _permanentlyRequireSecondProofSystem(otherChainId);
        assertFalse(IGetters(getZKChainAddress(otherChainId)).isZKsyncOSL1SloadEnabled());

        _expectEnableInteropRevert(
            governance,
            otherChainId,
            abi.encodeWithSelector(L1SloadNotEnabled.selector, otherChainId)
        );
    }

    /// @notice Once interop is enabled, the chain can't turn L1SLOAD off: its gating reads would stop.
    function test_l1SloadCantBeDisabledWhileInteropEnabled() public {
        _enableInterop(chainId);

        vm.prank(_chainAdmin(chainId));
        vm.expectRevert(abi.encodeWithSelector(L1SloadRequiredByInterop.selector, chainId));
        IAdmin(chain).setZKsyncOSL1SloadEnabled(false);

        assertTrue(IGetters(chain).isZKsyncOSL1SloadEnabled());
        assertTrue(messageRoot.isInteropEnabled(chainId));
    }

    /// @dev A diamond whose facets predate L1SLOAD has no `isZKsyncOSL1SloadEnabled`, so the proxy reverts with "F" and
    /// such a chain can't be enabled until it upgrades. The getter is mocked to revert that way.
    function test_enableInterop_revertWhen_diamondPredatesL1Sload() public {
        _permanentlyRequireSecondProofSystem(chainId);
        vm.mockCallRevert(chain, abi.encodeCall(IGetters.isZKsyncOSL1SloadEnabled, ()), bytes("F"));

        _expectEnableInteropRevert(governance, chainId, bytes("F"));
    }

    function test_enableInterop() public {
        _permanentlyRequireSecondProofSystem(chainId);

        vm.expectEmit(true, true, true, true, address(messageRoot));
        emit IL1MessageRoot.InteropEnabled(chainId);
        vm.prank(governance);
        messageRoot.enableInterop(chainId, true);

        assertTrue(messageRoot.isInteropEnabled(chainId));
        assertFalse(messageRoot.isInteropEnabled(zkChainIds[1]), "other chains stay disabled");
    }

    /// @notice Governance may enable a chain it trusts for reasons checked offchain: without the flag, a chain
    /// that neither required its second proof system nor runs in multi-proof mode is enabled.
    function test_enableInterop_withoutSecondProofSystem() public {
        vm.prank(_chainAdmin(chainId));
        IAdmin(chain).setProofSystemStatus(ProofSystem.Zisk, false);

        vm.expectEmit(true, true, true, true, address(messageRoot));
        emit IL1MessageRoot.InteropEnabled(chainId);
        vm.prank(governance);
        messageRoot.enableInterop(chainId, false);

        assertTrue(messageRoot.isInteropEnabled(chainId));
        assertFalse(IGetters(chain).isSecondProofSystemRequired(), "the chain stays without the requirement");
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
        _permanentlyRequireSecondProofSystem(chainId);
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

    function test_enableInterop_revertWhen_secondProofSystemNotRequired() public {
        _expectEnableInteropRevert(
            governance,
            chainId,
            abi.encodeWithSelector(SecondProofSystemNotRequired.selector, chainId)
        );
    }

    /// @notice A chain under the requirement that runs on a single prover after an emergency ZiSK-off can't be enabled.
    function test_enableInterop_revertWhen_notMultiProofMode() public {
        _permanentlyRequireSecondProofSystem(chainId);
        vm.prank(governance);
        IAdmin(chain).setProofSystemStatus(ProofSystem.Zisk, false);

        _expectEnableInteropRevert(
            governance,
            chainId,
            abi.encodeWithSelector(NotMultiProofMode.selector, ZKSYNC_OS_PLONK_VERIFICATION_TYPE)
        );
    }

    /// @dev A diamond whose facets predate the requirement has no `isSecondProofSystemRequired`, so the proxy reverts
    /// with "F". The getter is mocked to revert that way, isolating the old facet set.
    function test_enableInterop_revertWhen_oldDiamond() public {
        vm.mockCallRevert(chain, abi.encodeCall(IGetters.isSecondProofSystemRequired, ()), bytes("F"));

        _expectEnableInteropRevert(governance, chainId, bytes("F"));
    }

    /// @dev Without the flag the getter missing on an old diamond is never read, so such a chain can be enabled.
    function test_enableInterop_withoutSecondProofSystem_oldDiamond() public {
        vm.mockCallRevert(chain, abi.encodeCall(IGetters.isSecondProofSystemRequired, ()), bytes("F"));

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
