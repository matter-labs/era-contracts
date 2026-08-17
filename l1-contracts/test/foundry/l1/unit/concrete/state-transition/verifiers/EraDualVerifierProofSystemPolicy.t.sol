// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {EraDualVerifier} from "contracts/state-transition/verifiers/EraDualVerifier.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {InvalidProofSystemsMask, ProofSystemDisabled, Unauthorized} from "contracts/common/L1ContractErrors.sol";

import {
    AIRBENDER_PROOF_SYSTEM,
    ALL_PROOF_SYSTEMS,
    BOOJUM_PROOF_SYSTEM,
    DEFAULT_PROOF_SYSTEMS,
    IEraDualVerifier
} from "contracts/state-transition/chain-interfaces/IEraDualVerifier.sol";
import {MockAirbenderPlonkVerifier, MockFflonkVerifier, MockPlonkVerifier} from "./EraDualVerifier.t.sol";

/// @notice Stand-in for a ZK chain diamond. The dual verifier keys its policy on `msg.sender` of
/// `verify`, which in production is the chain's diamond proxy, and authorizes changes against the
/// chain's `getAdmin()`.
contract MockZKChain {
    address public admin;

    constructor(address _admin) {
        admin = _admin;
    }

    function getAdmin() external view returns (address) {
        return admin;
    }

    /// Call `verify` as the chain would, so the verifier sees this contract as `msg.sender`.
    function callVerify(
        EraDualVerifier _verifier,
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) external view returns (bool) {
        return _verifier.verify(_publicInputs, _proof);
    }

    /// Same, but through the testnet wrapper — the chain's `s.verifier` on a testnet deployment.
    function callVerifyOnTestnetVerifier(
        EraTestnetVerifier _verifier,
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) external view returns (bool) {
        return _verifier.verify(_publicInputs, _proof);
    }
}

/// @notice Tests for the per-chain proof-system policy on `EraDualVerifier`.
/// @dev The policy lets a chain admin turn Boojum or Airbender proofs off for their own chain
/// without redeploying the (shared, immutable) verifier. Airbender is off by default and at least
/// one proof system must always remain enabled.
contract EraDualVerifierProofSystemPolicyTest is Test {
    uint256 internal constant FFLONK_VERIFICATION_TYPE = 0;
    uint256 internal constant PLONK_VERIFICATION_TYPE = 1;
    uint256 internal constant AIRBENDER_PLONK_VERIFICATION_TYPE = 2;

    EraDualVerifier internal verifier;
    MockZKChain internal chain;
    MockZKChain internal otherChain;

    address internal chainAdmin = makeAddr("chainAdmin");
    address internal otherChainAdmin = makeAddr("otherChainAdmin");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        verifier = new EraDualVerifier(
            IVerifierV2(address(new MockFflonkVerifier())),
            IVerifier(address(new MockPlonkVerifier())),
            IVerifier(address(new MockAirbenderPlonkVerifier()))
        );
        chain = new MockZKChain(chainAdmin);
        otherChain = new MockZKChain(otherChainAdmin);
    }

    function _proof(uint256 _verifierType) internal pure returns (uint256[] memory proof) {
        proof = new uint256[](3);
        proof[0] = _verifierType;
        proof[1] = 789;
        proof[2] = 101112;
    }

    function _publicInputs() internal pure returns (uint256[] memory publicInputs) {
        publicInputs = new uint256[](1);
        publicInputs[0] = 123;
    }

    function _verifyAs(MockZKChain _chain, uint256 _verifierType) internal view returns (bool) {
        return _chain.callVerify(verifier, _publicInputs(), _proof(_verifierType));
    }

    // ============ The mask encoding itself ============

    /// The rest of this suite consumes the shared constants, so it would silently follow a change to
    /// them. Pin the wire values here: they are part of the ChainAdmin-facing API (an operator passes
    /// `3` on the command line) and must line up with the proof-type differentiators.
    function test_maskEncodingIsPinned() public pure {
        assertEq(BOOJUM_PROOF_SYSTEM, 1, "Boojum is bit 0");
        assertEq(AIRBENDER_PROOF_SYSTEM, 2, "Airbender is bit 1");
        assertEq(ALL_PROOF_SYSTEMS, 3, "mask covers exactly the two known systems");
        assertEq(DEFAULT_PROOF_SYSTEMS, BOOJUM_PROOF_SYSTEM, "default must be Boojum-only");
    }

    // ============ Defaults ============

    /// A chain that never set a policy must read as Boojum-only: Airbender off by default.
    function test_default_isBoojumOnly() public view {
        assertEq(verifier.enabledProofSystems(address(chain)), BOOJUM_PROOF_SYSTEM, "default must be Boojum-only");
    }

    function test_default_acceptsBoojumFflonkProof() public view {
        assertTrue(_verifyAs(chain, FFLONK_VERIFICATION_TYPE));
    }

    function test_default_acceptsBoojumPlonkProof() public view {
        assertTrue(_verifyAs(chain, PLONK_VERIFICATION_TYPE));
    }

    /// The whole point of the default: an Airbender-tagged proof must not verify until the chain
    /// admin opts in, even though the verifier has an Airbender slot wired up.
    function test_default_rejectsAirbenderProof() public {
        vm.expectRevert(
            abi.encodeWithSelector(ProofSystemDisabled.selector, address(chain), AIRBENDER_PLONK_VERIFICATION_TYPE)
        );
        _verifyAs(chain, AIRBENDER_PLONK_VERIFICATION_TYPE);
    }

    // ============ Enabling / disabling ============

    function test_admin_canEnableAirbenderAlongsideBoojum() public {
        vm.prank(chainAdmin);
        verifier.setEnabledProofSystems(address(chain), ALL_PROOF_SYSTEMS);

        assertEq(verifier.enabledProofSystems(address(chain)), ALL_PROOF_SYSTEMS);
        assertTrue(_verifyAs(chain, AIRBENDER_PLONK_VERIFICATION_TYPE), "airbender must verify once enabled");
        assertTrue(_verifyAs(chain, PLONK_VERIFICATION_TYPE), "boojum must keep working");
    }

    /// Disabling Boojum is how a chain commits to Airbender-only settlement.
    function test_admin_canDisableBoojum() public {
        vm.prank(chainAdmin);
        verifier.setEnabledProofSystems(address(chain), AIRBENDER_PROOF_SYSTEM);

        assertTrue(_verifyAs(chain, AIRBENDER_PLONK_VERIFICATION_TYPE));

        vm.expectRevert(abi.encodeWithSelector(ProofSystemDisabled.selector, address(chain), FFLONK_VERIFICATION_TYPE));
        _verifyAs(chain, FFLONK_VERIFICATION_TYPE);
    }

    /// Boojum is a single switch covering both of its wrappers (FFLONK and PLONK).
    function test_disablingBoojum_rejectsBothBoojumWrappers() public {
        vm.prank(chainAdmin);
        verifier.setEnabledProofSystems(address(chain), AIRBENDER_PROOF_SYSTEM);

        vm.expectRevert(abi.encodeWithSelector(ProofSystemDisabled.selector, address(chain), PLONK_VERIFICATION_TYPE));
        _verifyAs(chain, PLONK_VERIFICATION_TYPE);
    }

    function test_admin_canGoBackToBoojumOnly() public {
        vm.startPrank(chainAdmin);
        verifier.setEnabledProofSystems(address(chain), ALL_PROOF_SYSTEMS);
        verifier.setEnabledProofSystems(address(chain), BOOJUM_PROOF_SYSTEM);
        vm.stopPrank();

        assertTrue(_verifyAs(chain, PLONK_VERIFICATION_TYPE));
        vm.expectRevert(
            abi.encodeWithSelector(ProofSystemDisabled.selector, address(chain), AIRBENDER_PLONK_VERIFICATION_TYPE)
        );
        _verifyAs(chain, AIRBENDER_PLONK_VERIFICATION_TYPE);
    }

    function test_setEnabledProofSystems_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(verifier));
        emit IEraDualVerifier.EnabledProofSystemsUpdated(address(chain), BOOJUM_PROOF_SYSTEM, ALL_PROOF_SYSTEMS);

        vm.prank(chainAdmin);
        verifier.setEnabledProofSystems(address(chain), ALL_PROOF_SYSTEMS);
    }

    // ============ Invariants ============

    /// Both proof systems off would brick settlement for the chain, so it must be impossible.
    function test_setEnabledProofSystems_revertsWhenBothDisabled() public {
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidProofSystemsMask.selector, uint8(0)));
        verifier.setEnabledProofSystems(address(chain), 0);
    }

    /// Unknown bits would silently enable nothing while looking like a valid policy.
    function test_setEnabledProofSystems_revertsOnUnknownBits() public {
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidProofSystemsMask.selector, uint8(4)));
        verifier.setEnabledProofSystems(address(chain), 4);
    }

    function testFuzz_setEnabledProofSystems_rejectsInvalidMasks(uint8 _mask) public {
        vm.assume(_mask == 0 || _mask > ALL_PROOF_SYSTEMS);

        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(InvalidProofSystemsMask.selector, _mask));
        verifier.setEnabledProofSystems(address(chain), _mask);
    }

    // ============ Authorization ============

    function test_setEnabledProofSystems_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        verifier.setEnabledProofSystems(address(chain), ALL_PROOF_SYSTEMS);
    }

    /// One chain's admin must not be able to change another chain's policy.
    function test_setEnabledProofSystems_revertsForForeignChainAdmin() public {
        vm.prank(otherChainAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, otherChainAdmin));
        verifier.setEnabledProofSystems(address(chain), ALL_PROOF_SYSTEMS);
    }

    // ============ Per-chain isolation ============

    /// The policy is keyed by chain, so enabling Airbender for one chain must leave every other
    /// chain on the default.
    function test_policyIsPerChain() public {
        vm.prank(chainAdmin);
        verifier.setEnabledProofSystems(address(chain), ALL_PROOF_SYSTEMS);

        assertTrue(_verifyAs(chain, AIRBENDER_PLONK_VERIFICATION_TYPE), "opted-in chain accepts airbender");
        assertEq(
            verifier.enabledProofSystems(address(otherChain)),
            BOOJUM_PROOF_SYSTEM,
            "other chain stays on default"
        );

        vm.expectRevert(
            abi.encodeWithSelector(ProofSystemDisabled.selector, address(otherChain), AIRBENDER_PLONK_VERIFICATION_TYPE)
        );
        _verifyAs(otherChain, AIRBENDER_PLONK_VERIFICATION_TYPE);
    }

    /// `verify` must key on `msg.sender` and not on some ambient value: the same proof accepted for
    /// an opted-in chain must be rejected when the caller is a different chain.
    function test_verify_keysPolicyOnCaller() public {
        vm.prank(chainAdmin);
        verifier.setEnabledProofSystems(address(chain), AIRBENDER_PROOF_SYSTEM);

        assertTrue(_verifyAs(chain, AIRBENDER_PLONK_VERIFICATION_TYPE));

        vm.expectRevert(
            abi.encodeWithSelector(ProofSystemDisabled.selector, address(otherChain), AIRBENDER_PLONK_VERIFICATION_TYPE)
        );
        _verifyAs(otherChain, AIRBENDER_PLONK_VERIFICATION_TYPE);
    }

    // ============ verifyForChain ============

    /// `verifyForChain` exists so a wrapper (the testnet verifier) can forward the real chain
    /// identity instead of shadowing it with its own address.
    function test_verifyForChain_appliesTheNamedChainsPolicy() public {
        vm.prank(chainAdmin);
        verifier.setEnabledProofSystems(address(chain), ALL_PROOF_SYSTEMS);

        assertTrue(
            verifier.verifyForChain(address(chain), _publicInputs(), _proof(AIRBENDER_PLONK_VERIFICATION_TYPE)),
            "named chain has airbender enabled"
        );

        vm.expectRevert(
            abi.encodeWithSelector(ProofSystemDisabled.selector, address(otherChain), AIRBENDER_PLONK_VERIFICATION_TYPE)
        );
        verifier.verifyForChain(address(otherChain), _publicInputs(), _proof(AIRBENDER_PLONK_VERIFICATION_TYPE));
    }

    // ============ Through the testnet wrapper ============
    //
    // `EraTestnetVerifier` is what a testnet chain's `s.verifier` points at. It must forward the
    // calling chain's address to the inner dual verifier; if it called `verify` instead, every
    // testnet chain would share one policy keyed to the wrapper — which has no `getAdmin()`, so
    // Airbender could never be enabled there while the admin's setter call silently configured a key
    // nobody reads. These tests fail if that forwarding is lost.

    function _deployTestnetVerifier() internal returns (EraTestnetVerifier wrapper, EraDualVerifier inner) {
        wrapper = new EraTestnetVerifier(
            IVerifierV2(address(new MockFflonkVerifier())),
            IVerifier(address(new MockPlonkVerifier())),
            IVerifier(address(new MockAirbenderPlonkVerifier()))
        );
        inner = wrapper.DUAL_VERIFIER();
    }

    /// The revert must name the *chain*, not the wrapper — that is the observable proof that the
    /// chain identity survived the hop.
    function test_testnetVerifier_rejectsAirbenderForChainOnDefaultPolicy() public {
        (EraTestnetVerifier wrapper, ) = _deployTestnetVerifier();

        vm.expectRevert(
            abi.encodeWithSelector(ProofSystemDisabled.selector, address(chain), AIRBENDER_PLONK_VERIFICATION_TYPE)
        );
        chain.callVerifyOnTestnetVerifier(wrapper, _publicInputs(), _proof(AIRBENDER_PLONK_VERIFICATION_TYPE));
    }

    /// Opting in on the wrapper's inner verifier must make the wrapper accept the proof.
    function test_testnetVerifier_acceptsAirbenderOnceChainOptsIn() public {
        (EraTestnetVerifier wrapper, EraDualVerifier inner) = _deployTestnetVerifier();

        vm.prank(chainAdmin);
        inner.setEnabledProofSystems(address(chain), ALL_PROOF_SYSTEMS);

        assertTrue(
            chain.callVerifyOnTestnetVerifier(wrapper, _publicInputs(), _proof(AIRBENDER_PLONK_VERIFICATION_TYPE)),
            "wrapper must honour the chain's own policy"
        );
        assertEq(
            wrapper.enabledProofSystems(address(chain)),
            ALL_PROOF_SYSTEMS,
            "wrapper must surface the chain's policy"
        );
    }

    /// Two chains behind the same wrapper must not share a policy.
    function test_testnetVerifier_policyIsStillPerChain() public {
        (EraTestnetVerifier wrapper, EraDualVerifier inner) = _deployTestnetVerifier();

        vm.prank(chainAdmin);
        inner.setEnabledProofSystems(address(chain), ALL_PROOF_SYSTEMS);

        vm.expectRevert(
            abi.encodeWithSelector(ProofSystemDisabled.selector, address(otherChain), AIRBENDER_PLONK_VERIFICATION_TYPE)
        );
        otherChain.callVerifyOnTestnetVerifier(wrapper, _publicInputs(), _proof(AIRBENDER_PLONK_VERIFICATION_TYPE));
    }

    /// The empty-proof skip must survive the policy: a testnet chain with no proof at all keeps
    /// verifying, whatever its mask says.
    function test_testnetVerifier_emptyProofStillSkipsVerification() public {
        (EraTestnetVerifier wrapper, EraDualVerifier inner) = _deployTestnetVerifier();

        vm.prank(chainAdmin);
        inner.setEnabledProofSystems(address(chain), AIRBENDER_PROOF_SYSTEM);

        uint256[] memory emptyProof = new uint256[](0);
        assertTrue(chain.callVerifyOnTestnetVerifier(wrapper, _publicInputs(), emptyProof), "empty proof skips");
        assertTrue(wrapper.verifyForChain(address(chain), _publicInputs(), emptyProof), "and via verifyForChain");
    }

    /// Invalid masks are rejected before the chain lookup, so the error is reachable without a live
    /// chain at the target address.
    function test_setEnabledProofSystems_validatesMaskBeforeChainLookup() public {
        address notAChain = makeAddr("notAChain");

        vm.expectRevert(abi.encodeWithSelector(InvalidProofSystemsMask.selector, uint8(0)));
        verifier.setEnabledProofSystems(notAChain, 0);
    }

    // ============ Ungated surfaces ============

    /// The policy gates proof verification only. `verificationKeyHash` is a pure lookup used by
    /// off-chain tooling and upgrade checks, and must keep answering for disabled systems.
    function test_verificationKeyHash_isNotGatedByPolicy() public {
        vm.prank(chainAdmin);
        verifier.setEnabledProofSystems(address(chain), AIRBENDER_PROOF_SYSTEM);

        assertTrue(verifier.verificationKeyHash(FFLONK_VERIFICATION_TYPE) != bytes32(0));
        assertTrue(verifier.verificationKeyHash(PLONK_VERIFICATION_TYPE) != bytes32(0));
    }
}
