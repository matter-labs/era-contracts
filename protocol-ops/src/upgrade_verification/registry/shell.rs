//! Whether chains that cross a transition keep running the L2 system-proxy logic that chains
//! created after it get. An upgrade never replaces proxy code that is already deployed. The build
//! carries no compiler metadata, so a shell whose bytecode info differs from the departing
//! release's has different code (`docs/registry-driven-upgrades.md#what-the-derivation-guarantees`).

use alloy::primitives::Bytes;
use alloy::providers::Provider;

use crate::upgrade_verification::constants::L2_DEFAULT_UPGRADE_CONTRACT;
use crate::upgrade_verification::report::VerificationResult;

use super::genesis::decode_bytecode_info;
use super::provenance::{tolerate, CodeIdentity};
use super::views::{CTMReleaseView, TransitionManifest};

/// What the edge's authored L2 delegate means for a shell whose code changes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum EdgeDelegate {
    /// No delegate, or the reviewed commit's `L2DefaultUpgrade`: nothing replaces the proxies.
    NoMigration,
    /// Another contract the reviewed commit builds, by name: it may replace them.
    Custom(String),
    /// Code the reviewed commit does not produce, described for the reviewer.
    Unidentified(String),
}

/// Holds the shell new chains get from the transition's arriving release against the one chains
/// crossing the edge keep, the departing release's.
pub(super) async fn verify_shell_kept<P: Provider>(
    provider: &P,
    identity: &CodeIdentity,
    result: &mut VerificationResult,
    transition: &TransitionManifest,
) {
    let mut shells = Vec::with_capacity(2);
    for release in [transition.fromRelease, transition.newRelease] {
        let Some(manifest) = tolerate(
            CTMReleaseView::new(release, provider)
                .getManifest()
                .call()
                .await,
            result,
            &format!("the manifest of release {release}"),
        ) else {
            return;
        };
        shells.push(manifest.l2SystemProxyBytecodeInfo);
    }
    if shells[0] == shells[1] {
        result.report_ok("the arriving release keeps the departing release's system-proxy shell");
        return;
    }
    judge_shell_change(
        result,
        &classify_delegate(identity, &transition.l2Plan.delegateBytecodeInfo),
    );
}

/// The verdict on a shell whose code changes on the edge.
pub(super) fn judge_shell_change(result: &mut VerificationResult, delegate: &EdgeDelegate) {
    match delegate {
        EdgeDelegate::NoMigration => result.report_error(
            "the system-proxy shell's code changes on this edge and no L2 delegate beyond the \
             stock `L2DefaultUpgrade` migrates the proxies: chains crossing the edge would keep \
             the departing shell while new chains get the arriving one. Ship the change with a \
             delegate that replaces the shell at every existing system proxy",
        ),
        EdgeDelegate::Custom(delegate) => result.report_warn(&format!(
            "the system-proxy shell's code changes on this edge and its L2 delegate is \
             {delegate}, not the stock `L2DefaultUpgrade`: confirm that the delegate replaces \
             the shell at every existing system proxy, since no transition does"
        )),
        EdgeDelegate::Unidentified(delegate) => result.report_error(&format!(
            "the system-proxy shell's code changes on this edge and its L2 delegate is \
             {delegate}: whether it migrates the existing proxies cannot be established"
        )),
    }
}

/// The edge's delegate, by the reviewed-commit name of its code.
pub(super) fn classify_delegate(identity: &CodeIdentity, delegate_info: &Bytes) -> EdgeDelegate {
    if delegate_info.is_empty() {
        return EdgeDelegate::NoMigration;
    }
    let Some((_, hash)) = decode_bytecode_info(delegate_info) else {
        return EdgeDelegate::Unidentified(format!(
            "a {}-byte bytecode info, not a ZKsync OS one",
            delegate_info.len()
        ));
    };
    match identity.name_of(&hash) {
        Some(L2_DEFAULT_UPGRADE_CONTRACT) => EdgeDelegate::NoMigration,
        Some(name) => EdgeDelegate::Custom(format!("{name} (code {hash})")),
        None => EdgeDelegate::Unidentified(format!(
            "code {hash}, which the reviewed commit does not produce"
        )),
    }
}

#[cfg(test)]
mod tests {
    use alloy::primitives::{keccak256, Address, B256, U256};
    use alloy::providers::ProviderBuilder;
    use alloy::sol_types::SolValue;
    use alloy::transports::mock::Asserter;

    use super::super::views::{AuthoredL2Plan, ReleaseGenesisData, ReleaseManifest};
    use super::*;
    use crate::upgrade_verification::contract_hashes::ContractHashes;

    /// The ZKsync OS bytecode info of `code`; the blake2s hash is not read here.
    fn info_of(code: &[u8]) -> Bytes {
        Bytes::from((B256::ZERO, U256::from(code.len()), keccak256(code)).abi_encode())
    }

    fn verdict(delegate: &EdgeDelegate) -> VerificationResult {
        let mut result = VerificationResult::default();
        judge_shell_change(&mut result, delegate);
        result
    }

    #[test]
    fn a_change_without_a_migrating_delegate_is_an_error() {
        let result = verdict(&EdgeDelegate::NoMigration);
        assert_eq!((result.errors, result.warnings), (1, 0));
    }

    #[test]
    fn a_change_under_a_custom_delegate_is_left_to_the_reviewer() {
        let result = verdict(&EdgeDelegate::Custom("L2ShellMigration".to_string()));
        assert_eq!((result.errors, result.warnings), (0, 1));
    }

    #[test]
    fn a_change_under_an_unidentified_delegate_is_an_error() {
        let result = verdict(&EdgeDelegate::Unidentified("code 0x11".to_string()));
        assert_eq!((result.errors, result.warnings), (1, 0));
    }

    #[test]
    fn the_delegate_is_classified_by_its_reviewed_name() {
        let identity = CodeIdentity::from_hashes_file(
            &crate::upgrade_verification::contract_hashes::contract_hashes_path(None),
        )
        .unwrap();
        let reviewed = |name: &str| {
            let hash = ContractHashes::init_from_local()
                .unwrap()
                .hashes
                .into_iter()
                .find(|contract| contract.contract_name == name)
                .and_then(|contract| contract.evm_deployed_bytecode_hash)
                .unwrap()
                .parse::<B256>()
                .unwrap();
            Bytes::from((B256::ZERO, U256::ZERO, hash).abi_encode())
        };
        assert_eq!(
            classify_delegate(&identity, &Bytes::new()),
            EdgeDelegate::NoMigration
        );
        assert_eq!(
            classify_delegate(&identity, &reviewed(L2_DEFAULT_UPGRADE_CONTRACT)),
            EdgeDelegate::NoMigration
        );
        assert!(matches!(
            classify_delegate(&identity, &reviewed("l1-contracts/SystemContractProxy")),
            EdgeDelegate::Custom(_)
        ));
        assert!(matches!(
            classify_delegate(&identity, &info_of(b"\x60\x00")),
            EdgeDelegate::Unidentified(_)
        ));
        assert!(matches!(
            classify_delegate(&identity, &Bytes::from(vec![0u8; 32])),
            EdgeDelegate::Unidentified(_)
        ));
    }

    /// Runs the whole check against the two mocked release manifests of a stock edge (no
    /// authored delegate).
    async fn run(departing: &[u8], arriving: &[u8]) -> VerificationResult {
        let asserter = Asserter::new();
        for code in [departing, arriving] {
            let manifest = ReleaseManifest {
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
                l2SystemProxyBytecodeInfo: info_of(code),
            };
            asserter.push_success(&Bytes::from(manifest.abi_encode()));
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let transition = TransitionManifest {
            fromRelease: Address::repeat_byte(0xF0),
            newRelease: Address::repeat_byte(0xF1),
            chainUpgradeEngine: Address::ZERO,
            oldProtocolVersionDeadline: U256::ZERO,
            upgradeTimestamp: U256::ZERO,
            l2Plan: AuthoredL2Plan {
                delegateBytecodeInfo: Bytes::new(),
                extraBytecodeInfos: Vec::new(),
                delegateComposer: Address::ZERO,
            },
        };
        let mut result = VerificationResult::default();
        verify_shell_kept(
            &provider,
            &CodeIdentity::from_hashes_file(
                &crate::upgrade_verification::contract_hashes::contract_hashes_path(None),
            )
            .unwrap(),
            &mut result,
            &transition,
        )
        .await;
        assert!(asserter.read_q().is_empty(), "a mocked read was not made");
        result
    }

    #[tokio::test]
    async fn an_unchanged_shell_passes() {
        let shell = b"\x60\x80\x60\x40\x52";
        let result = run(shell, shell).await;
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    #[tokio::test]
    async fn a_changed_shell_on_a_stock_edge_is_an_error() {
        let result = run(b"\x60\x80\x60\x40\x52", b"\x60\x80\x60\x40\x53").await;
        assert_eq!((result.errors, result.warnings), (1, 0));
    }
}
