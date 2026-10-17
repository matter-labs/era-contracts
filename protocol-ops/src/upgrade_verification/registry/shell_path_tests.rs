//! Shared RPC fixture for the two shell-check call-site regressions. The transport is mocked to
//! isolate wiring in the real upgrade/replacement verifiers, not to simulate a valid ecosystem:
//! unrelated construction/genesis reads deliberately remain unverifiable in BOTH controls. Only
//! the arriving shell's logic differs, so it must contribute exactly one additional error.

use alloy::primitives::{keccak256, Address, Bytes, B256, U256};
use alloy::sol_types::SolValue;
use alloy::transports::mock::Asserter;

use super::construction::ReviewedBuild;
use super::genesis::{reviewed_genesis_image, ExpectedForceDeployments, ReviewedGenesis};
use super::views::{AuthoredL2Plan, ReleaseGenesisData, ReleaseManifest, TransitionManifest};
use crate::upgrade_verification::constants::L2_BRIDGEHUB_ADDR;

pub(super) const TRANSITION: Address = Address::repeat_byte(0xA1);
pub(super) const FROM_RELEASE: Address = Address::repeat_byte(0xF0);
pub(super) const NEW_RELEASE: Address = Address::repeat_byte(0xF1);
const CTM: Address = Address::repeat_byte(0xC7);
pub(super) const CTM_EXECUTOR: Address = Address::repeat_byte(0xE7);
const CTM_ADMIN: Address = Address::repeat_byte(0xA7);
const SUPPLIER: Address = Address::repeat_byte(0x5B);
pub(super) const GOVERNANCE: Address = Address::repeat_byte(0x60);
const OLD_VERSION: u64 = 35 << 32;
const NEW_VERSION: u64 = 36 << 32;

pub(super) struct ShellPathFixture {
    pub(super) asserter: Asserter,
    pub(super) build: ReviewedBuild,
    pub(super) genesis: ReviewedGenesis,
    departing: Bytes,
    arriving: Bytes,
}

impl ShellPathFixture {
    pub(super) fn new(change_logic: bool) -> Self {
        let mut image = reviewed_genesis_image().expect("the reviewed genesis image must load");
        let departing = image.code[&L2_BRIDGEHUB_ADDR].clone();
        let mut arriving = departing.to_vec();
        // The real SystemContractProxy's CBOR tail ends in an ipfs digest, solc version and
        // length. Change a digest byte in BOTH controls: metadata alone must still pass.
        let metadata_len =
            u16::from_be_bytes(arriving[arriving.len() - 2..].try_into().unwrap()) as usize;
        assert!(metadata_len > 20 && metadata_len + 2 < arriving.len());
        let metadata_hash_byte = arriving.len() - 20;
        arriving[metadata_hash_byte] ^= 1;
        if change_logic {
            arriving[0] ^= 1;
        }
        let arriving = Bytes::from(arriving);
        image.code.insert(NEW_RELEASE, arriving.clone());
        Self {
            asserter: Asserter::new(),
            build: ReviewedBuild::from_parts(&[]),
            genesis: ReviewedGenesis {
                genesis_root: Ok(B256::ZERO),
                image: Ok(image),
                force_deployments_data: None,
                force_deployments: ExpectedForceDeployments::unread(B256::ZERO),
            },
            departing,
            arriving,
        }
    }

    fn address(&self, address: Address) {
        self.asserter
            .push_success(&Bytes::from(address.abi_encode()));
    }

    fn code(&self, present: bool) {
        self.asserter.push_success(&if present {
            Bytes::from_static(b"\x60")
        } else {
            Bytes::new()
        });
    }

    fn unrelated_read(&self) {
        self.asserter
            .push_failure_msg("outside the shell call-site regression");
    }

    fn transition_reads(&self, existing_releases: bool) {
        self.code(true);
        self.asserter.push_success(&Bytes::from(
            TransitionManifest {
                fromRelease: FROM_RELEASE,
                newRelease: NEW_RELEASE,
                upgradeEngine: Address::ZERO,
                oldProtocolVersionDeadline: U256::MAX,
                upgradeTimestamp: U256::ZERO,
                l2Plan: AuthoredL2Plan {
                    delegateBytecodeInfo: Bytes::new(),
                    extraBytecodeInfos: Vec::new(),
                    delegateComposer: Address::ZERO,
                },
            }
            .abi_encode(),
        ));
        if existing_releases {
            self.code(true);
            self.code(true);
        } else {
            self.unrelated_read(); // Departing verifier's manifest.
            self.code(true); // Arriving release's runtime.
            self.unrelated_read(); // Arriving genesis/member verification is isolated out.
            self.code(true); // Departing release's runtime.
        }
        self.unrelated_read(); // Derived facet cuts.
        self.unrelated_read(); // Derived L2 plan.
        for version in [OLD_VERSION, NEW_VERSION] {
            self.asserter
                .push_success(&Bytes::from(U256::from(version).abi_encode()));
        }
    }

    fn readiness_and_shell_reads(&self) {
        self.address(SUPPLIER);
        self.unrelated_read(); // Factory-dependency publication is tested separately.
        for code in [&self.departing, &self.arriving] {
            self.asserter.push_success(&Bytes::from(
                ReleaseManifest {
                    protocolVersion: U256::ZERO,
                    diamondInit: Address::ZERO,
                    verifier: Address::ZERO,
                    genesisUpgrade: Address::ZERO,
                    genesisFacets: Vec::new(),
                    genesis: ReleaseGenesisData {
                        fixedForceDeploymentsData: Bytes::new(),
                        genesisBatchHash: B256::ZERO,
                        genesisIndexRepeatedStorageChanges: 0,
                    },
                    l2BytecodeInfos: Vec::new(),
                    l2SystemProxyBytecodeInfo: Bytes::from(
                        (B256::ZERO, U256::from(code.len()), keccak256(code)).abi_encode(),
                    ),
                }
                .abi_encode(),
            ));
        }
        self.address(SUPPLIER); // Both bytecodes are available in the reviewed image.
    }

    /// The reads of a transition-only upgrade, in the order `upgrade::verify` makes them.
    pub(super) fn upgrade_reads(&self) {
        self.unrelated_read(); // eth_chainId for genesis expectations (package names no CTM).
        self.transition_reads(false);
        self.code(true); // The CTM executor, whose bound CTM the departing state is read through.
        self.address(CTM);
        self.address(CTM_ADMIN);
        self.address(GOVERNANCE); // The CTM executor's owner.
        self.address(Address::ZERO); // Its pending owner.
        self.address(CTM_EXECUTOR); // CTM owner.
        self.address(CTM_EXECUTOR); // CTM-domain ProxyAdmin owner.
        self.address(Address::ZERO); // CTM pending owner.
        self.asserter
            .push_success(&Bytes::from(U256::from(OLD_VERSION).abi_encode()));
        self.address(FROM_RELEASE);
        self.readiness_and_shell_reads();
    }

    pub(super) fn replacement_reads(&self) {
        self.transition_reads(true);
        self.code(false); // Replaced transition's unrelated state checks are isolated out.
        self.address(CTM_EXECUTOR);
        self.address(Address::ZERO); // CTM pending owner.
        self.code(false); // CTM executor construction is outside this regression.
        self.address(GOVERNANCE); // The CTM executor's owner.
        self.address(Address::ZERO); // Its pending owner.
        self.readiness_and_shell_reads();
    }
}
