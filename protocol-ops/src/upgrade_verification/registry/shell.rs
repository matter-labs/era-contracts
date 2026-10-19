//! Whether chains that cross a transition keep running the L2 system-proxy logic that chains
//! created after it get. An upgrade never replaces proxy code that is already deployed, and the
//! shell's bytes change with every build's compiler metadata, so the chain cannot tell a rebuild
//! from a logic change (`docs/registry-driven-upgrades.md#what-the-derivation-guarantees`). This
//! compares the two releases' shells with the metadata stripped.

use alloy::primitives::{keccak256, Address, Bytes};
use alloy::providers::Provider;
use alloy::rpc::types::Filter;
use alloy::sol_types::SolEvent;

use crate::upgrade_verification::constants::{L2_BRIDGEHUB_ADDR, L2_DEFAULT_UPGRADE_CONTRACT};
use crate::upgrade_verification::report::VerificationResult;

use super::genesis::{decode_bytecode_info, GenesisImage};
use super::provenance::{tolerate, CodeIdentity};
use super::views::BytecodesSupplierView::EVMBytecodePublished;
use super::views::{BytecodesSupplierView, CTMReleaseView, CtmView, TransitionManifest};

/// solc ends the runtime code with its CBOR metadata and the metadata's length as a big-endian
/// `uint16`.
const SOLC_METADATA_LENGTH_BYTES: usize = 2;
/// The CBOR major type 5 (map) headers of up to 23 entries; solc's metadata is such a map.
const CBOR_SMALL_MAP_HEADERS: std::ops::RangeInclusive<u8> = 0xa0..=0xb7;
/// The `solc` key of that map, as a CBOR text string; every build that appends metadata has it.
const SOLC_METADATA_KEY: &[u8] = b"\x64solc";

/// What the edge's authored L2 delegate means for a shell whose logic changes.
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
/// crossing the edge keep, the departing release's. The bootstrap edge has no departing release.
pub(super) async fn verify_shell_kept<P: Provider>(
    provider: &P,
    identity: &CodeIdentity,
    image: Option<&GenesisImage>,
    result: &mut VerificationResult,
    ctm: &CtmView::CtmViewInstance<&P>,
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
    let (departing, arriving) = (&shells[0], &shells[1]);
    if departing == arriving {
        result.report_ok("the arriving release keeps the departing release's system-proxy shell");
        return;
    }

    let Some(supplier) = tolerate(
        ctm.L1_BYTECODES_SUPPLIER().call().await,
        result,
        "the CTM's L1_BYTECODES_SUPPLIER",
    ) else {
        return;
    };
    let mut codes = Vec::with_capacity(2);
    for (which, info) in [("departing", departing), ("arriving", arriving)] {
        match shell_code(provider, image, result, supplier, info).await {
            Some(Ok(code)) => codes.push(code),
            Some(Err(why)) => result.report_error(&format!(
                "the two shells' logic cannot be compared, since the {which} release's \
                 system-proxy shell {why}"
            )),
            // The failed read is reported.
            None => {}
        }
    }
    if let [departing_code, arriving_code] = codes.as_slice() {
        judge_shell_change(
            result,
            departing_code,
            arriving_code,
            &classify_delegate(identity, &transition.l2Plan.delegateBytecodeInfo),
        );
    }
}

/// The verdict on two different shells' code.
pub(super) fn judge_shell_change(
    result: &mut VerificationResult,
    departing: &[u8],
    arriving: &[u8],
    delegate: &EdgeDelegate,
) {
    if strip_solc_metadata(departing) == strip_solc_metadata(arriving) {
        result.report_ok(
            "the system-proxy shell differs from the departing release's only in its compiler \
             metadata: chains crossing the edge keep the proxy logic new chains get",
        );
        return;
    }
    match delegate {
        EdgeDelegate::NoMigration => result.report_error(
            "the system-proxy shell's logic changes on this edge and no L2 delegate beyond the \
             stock `L2DefaultUpgrade` migrates the proxies: chains crossing the edge would keep \
             the departing shell while new chains get the arriving one. Ship the change with a \
             delegate that replaces the shell at every existing system proxy",
        ),
        EdgeDelegate::Custom(delegate) => result.report_warn(&format!(
            "the system-proxy shell's logic changes on this edge and its L2 delegate is \
             {delegate}, not the stock `L2DefaultUpgrade`: confirm that the delegate replaces \
             the shell at every existing system proxy, since no transition does"
        )),
        EdgeDelegate::Unidentified(delegate) => result.report_error(&format!(
            "the system-proxy shell's logic changes on this edge and its L2 delegate is \
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

/// The code a shell's bytecode info describes: from the reviewed genesis image, else from the
/// CTM's supplier, where the edge that first shipped it published it. `Err` says why it was not
/// found; `None` means a read failed, which is reported here.
async fn shell_code<P: Provider>(
    provider: &P,
    image: Option<&GenesisImage>,
    result: &mut VerificationResult,
    supplier: Address,
    info: &Bytes,
) -> Option<Result<Bytes, String>> {
    let Some((_, hash)) = decode_bytecode_info(info) else {
        return Some(Err(format!(
            "has a {}-byte bytecode info, not a ZKsync OS one",
            info.len()
        )));
    };
    if let Some(code) = image.and_then(|image| {
        image
            .code
            .values()
            .find(|code| keccak256(code.as_ref()) == hash)
    }) {
        return Some(Ok(code.clone()));
    }
    let block = tolerate(
        BytecodesSupplierView::new(supplier, provider)
            .evmPublishingBlock(hash)
            .call()
            .await,
        result,
        &format!("the supplier's publication block for {hash}"),
    )?;
    let Some(block) = u64::try_from(block).ok().filter(|block| *block != 0) else {
        return Some(Err(format!(
            "(code {hash}) is neither in the reviewed genesis image nor published on supplier \
             {supplier}. Publish it with the permissionless \
             `BytecodesSupplier.publishEVMBytecode` and re-run: the bytes are the code at the L2 \
             Bridgehub's proxy, {L2_BRIDGEHUB_ADDR}, in the \
             `configs/genesis/zksync-os/latest.json` of the commit that built that release"
        )));
    };
    let filter = Filter::new()
        .address(supplier)
        .event_signature(EVMBytecodePublished::SIGNATURE_HASH)
        .topic1(hash)
        .from_block(block)
        .to_block(block);
    let logs = match provider.get_logs(&filter).await {
        Ok(logs) => logs,
        Err(e) => {
            result.report_error(&format!(
                "the supplier's EVMBytecodePublished logs of block {block} could not be read \
                 ({e}): re-run against an RPC that serves them"
            ));
            return None;
        }
    };
    Some(
        logs.iter()
            .filter_map(|log| log.log_decode::<EVMBytecodePublished>().ok())
            .map(|log| log.inner.data.bytecode)
            .find(|code| keccak256(code.as_ref()) == hash)
            .ok_or_else(|| {
                format!(
                    "(code {hash}) is recorded as published on supplier {supplier} at block \
                     {block}, but no EVMBytecodePublished log of that block carries it"
                )
            }),
    )
}

/// `code` without solc's trailing metadata; unchanged when it carries none.
pub(super) fn strip_solc_metadata(code: &[u8]) -> &[u8] {
    let Some(split) = code.len().checked_sub(SOLC_METADATA_LENGTH_BYTES) else {
        return code;
    };
    let (body, length) = code.split_at(split);
    let metadata_length = usize::from(u16::from_be_bytes([length[0], length[1]]));
    match body.len().checked_sub(metadata_length) {
        Some(start)
            if metadata_length != 0
                && CBOR_SMALL_MAP_HEADERS.contains(&body[start])
                && body[start..]
                    .windows(SOLC_METADATA_KEY.len())
                    .any(|window| window == SOLC_METADATA_KEY) =>
        {
            &body[..start]
        }
        _ => code,
    }
}

#[cfg(test)]
mod tests {
    use alloy::primitives::{LogData, B256, U256};
    use alloy::providers::ProviderBuilder;
    use alloy::sol_types::SolValue;
    use alloy::transports::mock::Asserter;

    use super::super::views::{AuthoredL2Plan, ReleaseGenesisData, ReleaseManifest};
    use super::*;
    use crate::upgrade_verification::contract_hashes::ContractHashes;

    const SUPPLIER: Address = Address::repeat_byte(0x5B);
    const PUBLISHED_AT: u64 = 7;

    /// `logic` followed by solc-shaped metadata: a two-entry CBOR map (`ipfs`, `solc`) whose
    /// hash bytes differ between builds.
    fn compiled(logic: &[u8], build: u8) -> Vec<u8> {
        let mut metadata = vec![0xa2, 0x64];
        metadata.extend_from_slice(b"ipfs");
        metadata.extend_from_slice(&[0x58, 0x22]);
        metadata.extend_from_slice(&[build; 34]);
        metadata.extend_from_slice(&[0x64]);
        metadata.extend_from_slice(b"solc");
        metadata.extend_from_slice(&[0x43, 0x00, 0x08, 0x1c]);
        let mut code = logic.to_vec();
        code.extend_from_slice(&metadata);
        code.extend_from_slice(&u16::try_from(metadata.len()).unwrap().to_be_bytes());
        code
    }

    /// The ZKsync OS bytecode info of `code`; the blake2s hash is not read here.
    fn info_of(code: &[u8]) -> Bytes {
        Bytes::from((B256::ZERO, U256::from(code.len()), keccak256(code)).abi_encode())
    }

    fn verdict(departing: &[u8], arriving: &[u8], delegate: &EdgeDelegate) -> VerificationResult {
        let mut result = VerificationResult::default();
        judge_shell_change(&mut result, departing, arriving, delegate);
        result
    }

    #[test]
    fn stripping_removes_exactly_the_metadata() {
        let logic = b"\x60\x80\x60\x40\x52\x00\xfe";
        assert_eq!(strip_solc_metadata(&compiled(logic, 1)), logic);
        // No metadata: the trailing bytes do not point at a CBOR map, so nothing is cut.
        assert_eq!(strip_solc_metadata(logic), logic);
        assert_eq!(strip_solc_metadata(&[0x00, 0x01]), &[0x00, 0x01]);
        assert_eq!(strip_solc_metadata(&[0x07]), &[0x07]);
        assert_eq!(strip_solc_metadata(&[]), &[] as &[u8]);
        // The trailing bytes point at a map header, but no `solc` key follows it.
        let lookalike = [0x60, 0xa0, 0x11, 0x22, 0x00, 0x03];
        assert_eq!(strip_solc_metadata(&lookalike), &lookalike);
    }

    #[test]
    fn a_rebuild_of_the_same_logic_passes_whatever_the_delegate() {
        let logic = b"\x60\x80\x60\x40\x52";
        let result = verdict(
            &compiled(logic, 1),
            &compiled(logic, 2),
            &EdgeDelegate::NoMigration,
        );
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    #[test]
    fn a_logic_change_without_a_migrating_delegate_is_an_error() {
        let result = verdict(
            &compiled(b"\x60\x80\x60\x40\x52", 1),
            &compiled(b"\x60\x80\x60\x40\x53", 1),
            &EdgeDelegate::NoMigration,
        );
        assert_eq!((result.errors, result.warnings), (1, 0));
    }

    #[test]
    fn a_logic_change_under_a_custom_delegate_is_left_to_the_reviewer() {
        let result = verdict(
            &compiled(b"\x60\x80\x60\x40\x52", 1),
            &compiled(b"\x60\x80\x60\x40\x53", 1),
            &EdgeDelegate::Custom("L2ShellMigration".to_string()),
        );
        assert_eq!((result.errors, result.warnings), (0, 1));
    }

    #[test]
    fn a_logic_change_under_an_unidentified_delegate_is_an_error() {
        let result = verdict(
            &compiled(b"\x60\x80\x60\x40\x52", 1),
            &compiled(b"\x60\x80\x60\x40\x53", 1),
            &EdgeDelegate::Unidentified("code 0x11".to_string()),
        );
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

    /// What the CTM's supplier holds for the departing shell.
    enum Publication {
        Unpublished,
        Logged,
        LogMissing,
        LogsUnreadable,
    }

    /// Runs the whole check against mocked L1 reads: the two release manifests and, when the
    /// shells differ, the CTM's supplier, then the departing shell's publication block and log.
    /// The arriving shell is in the reviewed image, so it is not read from the supplier. The
    /// mocked node answers `eth_getLogs` whatever its filter.
    async fn run(
        departing: &[u8],
        arriving: &[u8],
        publication: Publication,
    ) -> VerificationResult {
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
        if departing != arriving {
            asserter.push_success(&Bytes::from(SUPPLIER.abi_encode()));
            let block = match publication {
                Publication::Unpublished => 0,
                _ => PUBLISHED_AT,
            };
            asserter.push_success(&Bytes::from(U256::from(block).abi_encode()));
            let log = |bytecode: &[u8]| alloy::rpc::types::Log {
                inner: alloy::primitives::Log {
                    address: SUPPLIER,
                    data: LogData::from(&EVMBytecodePublished {
                        bytecodeHash: keccak256(bytecode),
                        bytecode: Bytes::copy_from_slice(bytecode),
                    }),
                },
                block_number: Some(PUBLISHED_AT),
                ..Default::default()
            };
            match publication {
                Publication::Unpublished => {}
                Publication::Logged => asserter.push_success(&vec![log(departing)]),
                Publication::LogMissing => asserter.push_success(&vec![log(b"\x00")]),
                Publication::LogsUnreadable => asserter.push_failure_msg("block range pruned"),
            }
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut image = GenesisImage::default();
        image
            .code
            .insert(Address::repeat_byte(0x01), Bytes::copy_from_slice(arriving));
        // The stock edge: no authored delegate.
        let transition = TransitionManifest {
            fromRelease: Address::repeat_byte(0xF0),
            newRelease: Address::repeat_byte(0xF1),
            upgradeEngine: Address::ZERO,
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
            Some(&image),
            &mut result,
            &CtmView::new(Address::repeat_byte(0xC7), &provider),
            &transition,
        )
        .await;
        assert!(asserter.read_q().is_empty(), "a mocked read was not made");
        result
    }

    #[tokio::test]
    async fn an_unchanged_shell_is_not_read() {
        let shell = compiled(b"\x60\x80\x60\x40\x52", 1);
        let result = run(&shell, &shell, Publication::Unpublished).await;
        assert_eq!((result.errors, result.warnings), (0, 0));
    }

    #[tokio::test]
    async fn the_departing_shell_is_read_from_its_publication_log() {
        let logic = b"\x60\x80\x60\x40\x52";
        let result = run(
            &compiled(logic, 1),
            &compiled(logic, 2),
            Publication::Logged,
        )
        .await;
        assert_eq!((result.errors, result.warnings), (0, 0));
        let result = run(
            &compiled(logic, 1),
            &compiled(b"\x60\x80\x60\x40\x53", 1),
            Publication::Logged,
        )
        .await;
        assert_eq!((result.errors, result.warnings), (1, 0));
    }

    /// Each way of not finding the departing shell is one error, not one per layer.
    #[tokio::test]
    async fn a_departing_shell_that_cannot_be_read_is_one_error() {
        let logic = b"\x60\x80\x60\x40\x52";
        for publication in [
            Publication::Unpublished,
            Publication::LogMissing,
            Publication::LogsUnreadable,
        ] {
            let result = run(&compiled(logic, 1), &compiled(logic, 2), publication).await;
            assert_eq!((result.errors, result.warnings), (1, 0));
        }
    }
}
