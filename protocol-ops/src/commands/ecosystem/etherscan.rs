//! `ecosystem etherscan-verify` and `ecosystem etherscan-check`: the Etherscan side of a deploy.
//!
//! The build carries no CBOR metadata, so the bytecode does not bind the verified source: anyone
//! can verify our bytecode with altered comments, and Etherscan keeps the first verification it
//! accepts for an address (until then, it shows one of identical code at another address). Two
//! steps keep that window short and catch it when it is used:
//!
//! * `etherscan-verify` submits every contract the bundle's generation logged to Etherscan. With
//!   `--l1-rpc-url` it runs next to the broadcast and submits each contract as soon as its code is
//!   on L1, instead of after the whole broadcast.
//! * `etherscan-check` reads what Etherscan shows for each of those addresses and holds it to this
//!   checkout: the contract name, and every source file byte for byte, comments included. With
//!   `--also-commit`, a file may also be as it was at an earlier cut of the release.

use std::collections::BTreeMap;
use std::future::Future;
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use alloy::primitives::{Address, Bytes};
use alloy::providers::Provider;
use alloy::transports::http::reqwest;
use anyhow::Context;
use clap::Parser;
use serde::Deserialize;

use crate::commands::ecosystem::bundle::verify_bundle_integrity;
use crate::commands::ecosystem::deployer_plan::require_checkout_at;
use crate::common::ethereum::get_provider;
use crate::common::{logger, paths};

/// The `forge verify-contract` commands the generation logged, one per deployed contract
/// (`Create2FactoryUtils.notifyAboutDeployment`).
const VERIFICATION_LOG: &str = "extra-verification-logs.txt";
/// Etherscan's multichain API; the chain is a query parameter.
const ETHERSCAN_API_URL: &str = "https://api.etherscan.io/v2/api";
/// Whole submissions per contract that Etherscan refuses (`Submission::Rejected`), and, in a run
/// that does not follow a broadcast, per contract at all: forge exits at once on most refusals (a
/// rate limit among them), and its `--retries` only repeats a request that failed or found no code.
const SUBMIT_ATTEMPTS: u32 = 3;
const SUBMIT_RETRY_DELAY: Duration = Duration::from_secs(10);
/// How often a follow run looks for newly deployed code, and tries a failed submission again.
const CODE_POLL_INTERVAL: Duration = Duration::from_secs(6);
/// Etherscan's read API lags a fresh verification, and rate-limits bursts.
const CHECK_ATTEMPTS: u32 = 10;
const CHECK_RETRY_DELAY: Duration = Duration::from_secs(15);

/// One logged deployment to verify.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Verification {
    address: Address,
    contract: String,
    constructor_args: Option<Bytes>,
}

impl Verification {
    /// `forge verify-contract` arguments, never a shell string: the log is bundle text. Without
    /// `watch`, forge returns once Etherscan accepts the submission, not after its verdict, and
    /// gives up after a second try at once: a follow run tries again on its next pass. Every
    /// address is submitted, also one Etherscan already shows sources for: identical code
    /// verified elsewhere shows there too, until the address is verified itself.
    fn forge_args(&self, chain_id: u64, watch: bool) -> Vec<String> {
        let mut args = vec![
            "verify-contract".to_string(),
            format!("{:#x}", self.address),
            self.contract.clone(),
        ];
        if let Some(constructor_args) = &self.constructor_args {
            args.extend([
                "--constructor-args".to_string(),
                constructor_args.to_string(),
            ]);
        }
        args.extend([
            "--chain".to_string(),
            chain_id.to_string(),
            "--skip-is-verified-check".to_string(),
        ]);
        let retries: &[&str] = if watch {
            &["--watch", "--retries", "8", "--delay", "20"]
        } else {
            &["--retries", "1", "--delay", "0"]
        };
        args.extend(retries.iter().map(|arg| arg.to_string()));
        args
    }
}

/// The log's verification commands in first-seen order without repeats, and every line that
/// names `forge verify-contract` but is not exactly `forge verify-contract <address> <Contract>
/// [--constructor-args <hex>]`. Such a line is never run.
fn parse_verification_log(log: &str) -> (Vec<Verification>, Vec<String>) {
    let mut verifications: Vec<Verification> = Vec::new();
    let mut rejected = Vec::new();
    for line in log.lines() {
        let Some(start) = line.find("forge verify-contract") else {
            continue;
        };
        let command = line[start..].trim_end();
        match parse_verification(command) {
            Some(verification) if verifications.contains(&verification) => {}
            Some(verification) => verifications.push(verification),
            None => rejected.push(command.to_string()),
        }
    }
    (verifications, rejected)
}

fn parse_verification(command: &str) -> Option<Verification> {
    let tokens: Vec<&str> = command.split(' ').collect();
    let (address, contract, constructor_args) = match tokens.as_slice() {
        ["forge", "verify-contract", address, contract] => (address, contract, None),
        ["forge", "verify-contract", address, contract, "--constructor-args", args] => {
            (address, contract, Some(args))
        }
        _ => return None,
    };
    let is_hex = |digits: &str| digits.bytes().all(|byte| byte.is_ascii_hexdigit());
    let address_digits = address.strip_prefix("0x")?;
    if address_digits.len() != 40 || !is_hex(address_digits) {
        return None;
    }
    let mut name = contract.bytes();
    if !name
        .next()
        .is_some_and(|first| first.is_ascii_alphabetic() || first == b'_')
        || !name.all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
    {
        return None;
    }
    let constructor_args = match constructor_args {
        Some(args) => {
            let digits = args.strip_prefix("0x")?;
            if !is_hex(digits) {
                return None;
            }
            Some(args.parse::<Bytes>().ok()?)
        }
        None => None,
    };
    Some(Verification {
        address: address.parse().ok()?,
        contract: contract.to_string(),
        constructor_args,
    })
}

/// Etherscan's answer to one submission.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Submission {
    /// Accepted (watching: verified), or already verified at the address itself.
    Accepted,
    /// Etherscan has not indexed the code at the address yet.
    NotIndexedYet,
    RateLimited,
    /// The submission or its status request did not get an answer.
    Transport,
    /// forge stopped before it submitted (it fetches the solc release list first): its last line.
    NotSubmitted(String),
    /// Etherscan shows identical code verified elsewhere (a similar match) and lets only
    /// whitelisted accounts verify this address: `etherscan-check` holds what it shows to the
    /// reviewed sources.
    SimilarMatchLocked,
    /// Any other refusal: its last line.
    Rejected(String),
}

impl std::fmt::Display for Submission {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Accepted => write!(f, "accepted"),
            Self::NotIndexedYet => write!(f, "Etherscan has not indexed the code there yet"),
            Self::RateLimited => write!(f, "Etherscan rate-limited the submission"),
            Self::Transport => write!(f, "the submission got no answer from Etherscan"),
            Self::NotSubmitted(reason) => write!(f, "not submitted: {reason}"),
            Self::SimilarMatchLocked => write!(
                f,
                "Etherscan shows a similar match there and lets only whitelisted accounts verify it"
            ),
            Self::Rejected(reason) => write!(f, "not accepted: {reason}"),
        }
    }
}

/// Reads Etherscan's answer from what `forge verify-contract` printed (stdout and stderr, in the
/// order printed) and whether it succeeded.
fn classify(succeeded: bool, output: &str) -> Submission {
    if succeeded {
        return Submission::Accepted;
    }
    let last_line = |text: &str| {
        text.lines()
            .map(str::trim)
            .rfind(|line| !line.is_empty())
            .unwrap_or("forge printed nothing")
            .to_string()
    };
    // forge prints each attempt's answer before it retries: only what follows the last submission
    // or retry warning counts. Lines, since a submitted payload is one line of JSON.
    let lines: Vec<&str> = output.lines().collect();
    let Some(last_attempt) = lines.iter().rposition(|line| {
        line.starts_with("Submitting verification for [")
            || line.trim_end().ends_with("tries remaining)")
    }) else {
        return Submission::NotSubmitted(last_line(output));
    };
    let answer = &lines[last_attempt + 1..].join("\n");
    // First: forge prints the submitted sources along with a request that failed.
    if answer.contains("Failed to submit contract verification")
        || answer.contains("Failed to request verification status")
    {
        return Submission::Transport;
    }
    if answer.contains("Could not detect deployment") {
        return Submission::NotIndexedYet;
    }
    let lowercase = answer.to_lowercase();
    if lowercase.contains("rate limit") {
        Submission::RateLimited
    } else if lowercase.contains("similar match") {
        Submission::SimilarMatchLocked
    } else {
        Submission::Rejected(last_line(answer))
    }
}

/// In a follow run: whether to submit again next pass, with the `Rejected` answers counted so far,
/// or (`None`) to take `answer` as final. Only a refusal counts toward `SUBMIT_ATTEMPTS`: an
/// unindexed address, a rate limit or a lost request say nothing about the next pass, and neither
/// does a forge that stopped before submitting, most often on a network failure. One that stops
/// there every time (a missing artifact, say) is tried until the broadcast ends and reported then.
fn resubmit(answer: &Submission, rejected: u32) -> Option<u32> {
    match answer {
        Submission::Accepted | Submission::SimilarMatchLocked => None,
        Submission::NotIndexedYet
        | Submission::RateLimited
        | Submission::Transport
        | Submission::NotSubmitted(_) => Some(rejected),
        Submission::Rejected(_) => (rejected + 1 < SUBMIT_ATTEMPTS).then_some(rejected + 1),
    }
}

/// Submits one verification.
trait Submitter {
    fn submit(&mut self, verification: &Verification, chain_id: u64) -> Submission;
}

/// Runs `forge verify-contract` in `l1-contracts`, whose build it compiles against. The key comes
/// from `ETHERSCAN_API_KEY` in the environment.
struct ForgeSubmitter {
    l1_contracts: PathBuf,
    /// Wait for each verdict, and retry slowly. A follow run does neither, so a contract that
    /// lands mid-broadcast does not queue behind earlier ones; `etherscan-check` waits for them.
    watch: bool,
}

impl Submitter for ForgeSubmitter {
    fn submit(&mut self, verification: &Verification, chain_id: u64) -> Submission {
        match self.run(verification, chain_id) {
            Ok((succeeded, output)) => classify(succeeded, &output),
            Err(error) => Submission::NotSubmitted(format!("forge did not run: {error:#}")),
        }
    }
}

impl ForgeSubmitter {
    /// Whether forge succeeded, and its stdout and stderr through one pipe: forge prints a
    /// submission to stdout and its answer, retries included, to stderr.
    fn run(&self, verification: &Verification, chain_id: u64) -> anyhow::Result<(bool, String)> {
        let (mut reader, writer) = std::io::pipe()?;
        // The `Command`, and with it its ends of the pipe, is dropped once forge starts: the read
        // below ends when forge exits.
        let mut child = Command::new("forge")
            .args(verification.forge_args(chain_id, self.watch))
            .current_dir(&self.l1_contracts)
            .stdout(writer.try_clone()?)
            .stderr(writer)
            .spawn()?;
        let mut output = Vec::new();
        std::io::Read::read_to_end(&mut reader, &mut output)?;
        let succeeded = child.wait()?.success();
        Ok((succeeded, String::from_utf8_lossy(&output).into_owned()))
    }
}

/// Submits `verification` until Etherscan accepts it or shows a similar match, at most
/// `SUBMIT_ATTEMPTS` times; the last answer.
fn submit_with_retries(
    submitter: &mut impl Submitter,
    verification: &Verification,
    chain_id: u64,
    retry_delay: Duration,
) -> Submission {
    let mut attempt = 1;
    loop {
        let answer = submitter.submit(verification, chain_id);
        if matches!(
            answer,
            Submission::Accepted | Submission::SimilarMatchLocked
        ) || attempt == SUBMIT_ATTEMPTS
        {
            return answer;
        }
        logger::warn(format!(
            "{}: {answer}; retrying ({attempt}/{SUBMIT_ATTEMPTS})",
            verification.contract
        ));
        std::thread::sleep(retry_delay);
        attempt += 1;
    }
}

/// What a run of submissions came to.
#[derive(Debug, Default, PartialEq, Eq)]
struct SubmitOutcome {
    verified: usize,
    similar_matches: usize,
    failed: Vec<String>,
}

impl SubmitOutcome {
    /// Counts the final answer for the contract `label` names.
    fn record(&mut self, label: String, answer: Submission) {
        match answer {
            Submission::Accepted => self.verified += 1,
            Submission::SimilarMatchLocked => {
                logger::warn(format!(
                    "{label}: {answer}; etherscan-check holds what it shows to the reviewed \
                     sources"
                ));
                self.similar_matches += 1;
            }
            answer => self.failed.push(format!("{label}: {answer}")),
        }
    }

    fn into_result(self) -> anyhow::Result<()> {
        logger::info(format!(
            "Etherscan accepted {}, showed a similar match for {}, {} failed",
            self.verified,
            self.similar_matches,
            self.failed.len()
        ));
        for failure in &self.failed {
            logger::error(failure);
        }
        anyhow::ensure!(
            self.failed.is_empty() && self.verified + self.similar_matches > 0,
            "Etherscan verification incomplete"
        );
        Ok(())
    }
}

fn submit_all(
    submitter: &mut impl Submitter,
    verifications: &[Verification],
    chain_id: u64,
    retry_delay: Duration,
) -> SubmitOutcome {
    let mut outcome = SubmitOutcome::default();
    for verification in verifications {
        let label = format!("{} at {:#x}", verification.contract, verification.address);
        logger::step(format!("verifying {label}"));
        let answer = submit_with_retries(submitter, verification, chain_id, retry_delay);
        outcome.record(label, answer);
    }
    outcome
}

/// Why a follow run has not submitted a contract yet.
enum Pending {
    NoCode,
    ReadFailed(String),
    /// Submitted, and not accepted: Etherscan's last answer, and how many it rejected.
    NotAccepted {
        last: Submission,
        rejected: u32,
    },
}

/// Submits each verification as soon as its address has code, until all are submitted, the stop
/// file appears (a last pass then picks up what landed meanwhile) or `max_wait` passes. A failed
/// code read or submission is tried again on the next pass, never waited out in this one, so it
/// holds up no other contract; `resubmit` decides which answers are. Whatever is still pending
/// after the last pass is a failure.
async fn follow_and_submit<P: Provider>(
    provider: &P,
    submitter: &mut impl Submitter,
    verifications: &[Verification],
    chain_id: u64,
    stop_when: Option<&Path>,
    max_wait: Duration,
    poll_interval: Duration,
) -> SubmitOutcome {
    let started = Instant::now();
    let mut outcome = SubmitOutcome::default();
    let mut pending: Vec<(&Verification, Pending)> = verifications
        .iter()
        .map(|verification| (verification, Pending::NoCode))
        .collect();
    loop {
        let last_pass = stop_when.is_some_and(Path::exists) || started.elapsed() >= max_wait;
        let mut still_pending = Vec::new();
        for (verification, why) in pending {
            let label = format!("{} at {:#x}", verification.contract, verification.address);
            // Code once seen stays: a submission that was not accepted is tried again without
            // reading it.
            let rejected = match why {
                Pending::NotAccepted { rejected, .. } => rejected,
                Pending::NoCode | Pending::ReadFailed(_) => {
                    match provider.get_code_at(verification.address).await {
                        Ok(code) if code.is_empty() => {
                            still_pending.push((verification, Pending::NoCode));
                            continue;
                        }
                        Ok(_) => 0,
                        Err(error) => {
                            logger::warn(format!(
                                "read the code at {:#x}: {error:#}; trying again next pass",
                                verification.address
                            ));
                            still_pending
                                .push((verification, Pending::ReadFailed(format!("{error:#}"))));
                            continue;
                        }
                    }
                }
            };
            logger::step(format!("submitting {label}"));
            let answer = submitter.submit(verification, chain_id);
            match resubmit(&answer, rejected) {
                Some(rejected) => {
                    logger::warn(format!("{label}: {answer}; trying again next pass"));
                    still_pending.push((
                        verification,
                        Pending::NotAccepted {
                            last: answer,
                            rejected,
                        },
                    ));
                }
                None => outcome.record(label, answer),
            }
        }
        pending = still_pending;
        if pending.is_empty() || last_pass {
            break;
        }
        tokio::time::sleep(poll_interval).await;
    }
    outcome
        .failed
        .extend(pending.into_iter().map(|(verification, why)| {
            let label = format!("{} at {:#x}", verification.contract, verification.address);
            match why {
                Pending::NoCode => {
                    format!("{label}: no code was deployed there, so it was not verified")
                }
                Pending::ReadFailed(error) => {
                    format!("{label}: its code could not be read ({error}), so it was not verified")
                }
                Pending::NotAccepted { last, .. } => format!("{label}: {last}"),
            }
        }));
    outcome
}

/// The bundle's chain and logged verifications; `None` when the bundle has no verification log.
/// The checkout at `repository_root` must be the bundle's: its sources are what is verified.
fn load_bundle(
    bundle: &Path,
    repository_root: &Path,
) -> anyhow::Result<Option<(u64, Vec<Verification>)>> {
    let bundle_dir = std::fs::canonicalize(bundle)
        .with_context(|| format!("deploy bundle not found: {}", bundle.display()))?;
    let metadata = verify_bundle_integrity(&bundle_dir)?;
    require_checkout_at(repository_root, &metadata)?;
    let chain_id = metadata
        .l1
        .chain_id
        .context("bundle-metadata.json records no l1.chain_id")?;
    let log_path = bundle_dir.join(VERIFICATION_LOG);
    if !log_path.exists() {
        return Ok(None);
    }
    let log = std::fs::read_to_string(&log_path)
        .with_context(|| format!("read {}", log_path.display()))?;
    Ok(Some((chain_id, verifications_from_log(&log)?)))
}

/// The log's verifications, all or nothing: one line of another shape refuses the whole log.
fn verifications_from_log(log: &str) -> anyhow::Result<Vec<Verification>> {
    let (verifications, rejected) = parse_verification_log(log);
    anyhow::ensure!(
        rejected.is_empty(),
        "{VERIFICATION_LOG} has lines that are not `forge verify-contract <address> <Contract> \
         [--constructor-args <hex>]`, so nothing was run:\n{}",
        rejected.join("\n")
    );
    anyhow::ensure!(
        !verifications.is_empty(),
        "{VERIFICATION_LOG} names no contract to verify"
    );
    Ok(verifications)
}

/// A forge-script upgrade may deploy nothing; a prepare-all bundle always logs its deployments.
fn no_log(forge_script: bool) -> anyhow::Result<()> {
    anyhow::ensure!(forge_script, "{VERIFICATION_LOG} not found in the bundle");
    logger::info("The bundle logged no contract deployments to verify.");
    Ok(())
}

fn require_etherscan_key() -> anyhow::Result<String> {
    std::env::var("ETHERSCAN_API_KEY")
        .ok()
        .filter(|key| !key.is_empty())
        .context("ETHERSCAN_API_KEY is not set")
}

// ─── etherscan-check ─────────────────────────────────────────────────────────────────────

/// What Etherscan shows for an address.
#[derive(Debug, PartialEq, Eq)]
enum EtherscanSource {
    /// No source verified (yet).
    Unverified,
    Verified {
        contract_name: String,
        /// Source unit name → content; `Err` describes a source this check cannot map to files.
        sources: Result<BTreeMap<String, String>, String>,
        /// The other address whose verification Etherscan shows, for identical code, while this
        /// one is not verified itself (a "similar match").
        similar_match: Option<String>,
    },
}

#[derive(Deserialize)]
struct GetSourceCodeResponse {
    status: String,
    result: serde_json::Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct GetSourceCodeEntry {
    source_code: String,
    contract_name: String,
    #[serde(default)]
    similar_match: String,
}

/// Parses a `getsourcecode` response for `address`. `Err` is an API error (rate limit, bad key),
/// worth a retry.
fn parse_getsourcecode(body: &str, address: Address) -> anyhow::Result<EtherscanSource> {
    let response: GetSourceCodeResponse =
        serde_json::from_str(body).context("Etherscan returned a body that is not JSON")?;
    if response.status != "1" {
        anyhow::bail!("Etherscan API error: {}", response.result);
    }
    let entries: Vec<GetSourceCodeEntry> =
        serde_json::from_value(response.result).context("unexpected getsourcecode result")?;
    let entry = entries
        .into_iter()
        .next()
        .context("getsourcecode returned no entry")?;
    if entry.source_code.is_empty() {
        return Ok(EtherscanSource::Unverified);
    }
    let similar_match = Some(entry.similar_match)
        .filter(|other| !other.is_empty() && other.parse::<Address>().ok() != Some(address));
    Ok(EtherscanSource::Verified {
        contract_name: entry.contract_name,
        sources: parse_source_code(&entry.source_code),
        similar_match,
    })
}

/// Etherscan stores a standard-JSON verification (what forge submits) as the input wrapped in one
/// more pair of braces, and a single flattened file as plain text.
fn parse_source_code(source_code: &str) -> Result<BTreeMap<String, String>, String> {
    let json = source_code
        .strip_prefix("{{")
        .and_then(|inner| inner.strip_suffix("}}"))
        .map(|inner| format!("{{{inner}}}"));
    let Some(json) = json.or_else(|| {
        source_code
            .trim_start()
            .starts_with('{')
            .then(|| source_code.to_string())
    }) else {
        return Err("a single flattened source, not this checkout's files".to_string());
    };
    let value: serde_json::Value = serde_json::from_str(&json)
        .map_err(|error| format!("a source JSON that does not parse ({error})"))?;
    let sources = value.get("sources").unwrap_or(&value);
    let sources = sources
        .as_object()
        .ok_or_else(|| "a source JSON without a sources map".to_string())?;
    sources
        .iter()
        .map(|(path, source)| {
            source
                .get("content")
                .and_then(serde_json::Value::as_str)
                .map(|content| (path.clone(), content.to_string()))
                .ok_or_else(|| format!("a source entry {path} without content"))
        })
        .collect()
}

/// The sources Etherscan may show: this checkout's `l1-contracts`, or a file as it was at an
/// earlier cut of the release (`--also-commit`). A re-cut keeps a contract whose code and salt
/// did not change, and with it the sources verified from the cut that deployed it.
struct ReviewedSources {
    l1_contracts: PathBuf,
    earlier_commits: Vec<String>,
}

impl ReviewedSources {
    fn new(l1_contracts: PathBuf, earlier_commits: Vec<String>) -> anyhow::Result<Self> {
        // Only the release's own history: a commit fetched by hash may be anyone's.
        for commit in &earlier_commits {
            let status = Command::new("git")
                .arg("-C")
                .arg(&l1_contracts)
                .args(["merge-base", "--is-ancestor", commit, "HEAD"])
                .output()
                .context("run git merge-base")?
                .status;
            match status.code() {
                Some(0) => {}
                Some(1) => anyhow::bail!(
                    "commit {commit} is not an ancestor of this checkout, and --also-commit takes \
                     only this checkout's own history (a shallow clone needs it: `git fetch \
                     --unshallow`)"
                ),
                _ => anyhow::bail!(
                    "commit {commit} is not in this clone: fetch this checkout's history \
                     (`git fetch --unshallow`)"
                ),
            }
        }
        Ok(Self {
            l1_contracts,
            earlier_commits,
        })
    }

    /// `None` when `content` is the file at `relative`, in the checkout or at an earlier cut.
    fn mismatch(&self, relative: &Path, content: &str) -> Option<&'static str> {
        let local = std::fs::read_to_string(self.l1_contracts.join(relative));
        if local.as_deref().is_ok_and(|local| local == content)
            || self
                .earlier_commits
                .iter()
                .any(|commit| self.file_at(commit, relative).as_deref() == Some(content))
        {
            return None;
        }
        Some(match (local.is_ok(), self.earlier_commits.is_empty()) {
            (true, true) => "differs from this checkout",
            (true, false) => "differs from this checkout and the earlier cuts",
            (false, true) => "not in this checkout",
            (false, false) => "not in this checkout, and differs from the earlier cuts",
        })
    }

    fn file_at(&self, commit: &str, relative: &Path) -> Option<String> {
        let output = Command::new("git")
            .arg("-C")
            .arg(&self.l1_contracts)
            .arg("show")
            .arg(format!("{commit}:./{}", relative.display()))
            .output()
            .ok()?;
        output
            .status
            .success()
            .then(|| String::from_utf8(output.stdout).ok())
            .flatten()
    }
}

/// How what Etherscan shows for an address stands against the reviewed sources.
#[derive(Debug, PartialEq, Eq)]
enum CheckStatus {
    /// The address's own verification, of the reviewed sources.
    OwnOurs,
    /// A similar match, showing the reviewed sources verified at the other address.
    SimilarOurs(String),
    /// The address's own verification, of other sources: every way they differ.
    OwnForeign(Vec<String>),
    /// A similar match, showing other sources verified at the other address.
    SimilarForeign(String, Vec<String>),
    Unverified,
    /// Etherscan's answer could not be read.
    Unreadable(String),
}

impl CheckStatus {
    fn of(
        verification: &Verification,
        source: &EtherscanSource,
        reviewed: &ReviewedSources,
    ) -> Self {
        let (contract_name, sources, similar_match) = match source {
            EtherscanSource::Unverified => return Self::Unverified,
            EtherscanSource::Verified {
                contract_name,
                sources,
                similar_match,
            } => (contract_name, sources, similar_match),
        };
        let mut problems = Vec::new();
        if contract_name != &verification.contract {
            problems.push(format!(
                "Etherscan names the contract {contract_name}, not {}",
                verification.contract
            ));
        }
        match sources {
            Err(shape) => problems.push(format!("Etherscan shows {shape}")),
            Ok(sources) if sources.is_empty() => {
                problems.push("Etherscan shows no source files".to_string());
            }
            Ok(sources) => {
                for (path, content) in sources {
                    let relative = Path::new(path);
                    if !relative
                        .components()
                        .all(|component| matches!(component, Component::Normal(_)))
                    {
                        problems.push(format!("{path}: not a path inside l1-contracts"));
                        continue;
                    }
                    if let Some(mismatch) = reviewed.mismatch(relative, content) {
                        problems.push(format!("{path}: {mismatch}"));
                    }
                }
            }
        }
        match (similar_match.clone(), problems.is_empty()) {
            (None, true) => Self::OwnOurs,
            (None, false) => Self::OwnForeign(problems),
            (Some(other), true) => Self::SimilarOurs(other),
            (Some(other), false) => Self::SimilarForeign(other, problems),
        }
    }

    /// `Ok` with a note, if any, when the status passes; otherwise every problem, then the one
    /// remedy.
    fn verdict(&self) -> Result<Option<String>, Vec<String>> {
        const EARLIER_CUT: &str = "if an earlier cut of this release deployed it and this cut \
                                   kept it, pass that cut's contracts_commit with --also-commit";
        let (mut lines, remedy) = match self {
            Self::OwnOurs => return Ok(None),
            Self::SimilarOurs(other) => {
                return Ok(Some(format!(
                    "a similar match, showing the sources verified at {other}, which has \
                     identical code; Etherscan lets only whitelisted accounts verify this address \
                     itself"
                )))
            }
            Self::Unverified => (
                vec!["Etherscan shows no verified source".to_string()],
                "run etherscan-verify again, then this check".to_string(),
            ),
            Self::Unreadable(error) => (
                vec![error.clone()],
                "check the error above, then run this check again".to_string(),
            ),
            Self::OwnForeign(problems) => (
                problems.clone(),
                format!(
                    "{EARLIER_CUT}; otherwise other sources were verified at this address first, \
                     and only Etherscan support can reset them (a redeploy of the same code \
                     would show them as a similar match)"
                ),
            ),
            Self::SimilarForeign(other, problems) => (
                problems.clone(),
                format!(
                    "{EARLIER_CUT}; otherwise this is a similar match, showing the sources \
                     verified at {other}, which has identical code, and only Etherscan support \
                     can replace it (a redeploy gets the same match)"
                ),
            ),
        };
        lines.push(format!("to fix: {remedy}"));
        Err(lines)
    }
}

async fn fetch_source(
    client: &reqwest::Client,
    key: &str,
    chain_id: u64,
    address: Address,
) -> anyhow::Result<EtherscanSource> {
    let url = reqwest::Url::parse_with_params(
        ETHERSCAN_API_URL,
        [
            ("chainid", chain_id.to_string()),
            ("module", "contract".to_string()),
            ("action", "getsourcecode".to_string()),
            ("address", format!("{address:#x}")),
            ("apikey", key.to_string()),
        ],
    )
    .context("Etherscan API URL")?;
    // The URL carries the API key: keep it out of the error.
    let body = client
        .get(url)
        .send()
        .await
        .map_err(reqwest::Error::without_url)
        .context("Etherscan request failed")?
        .text()
        .await
        .map_err(reqwest::Error::without_url)
        .context("Etherscan response could not be read")?;
    parse_getsourcecode(&body, address)
}

/// Each verification's status: every contract is checked, then those that do not pass again, up
/// to `attempts` passes `delay` apart. Etherscan's read API lags a fresh verification,
/// rate-limits bursts and shows a similar match until an address is verified.
async fn check_in_passes<'a, Fut>(
    verifications: &'a [Verification],
    attempts: u32,
    delay: Duration,
    mut status_of: impl FnMut(&'a Verification) -> Fut,
) -> Vec<(&'a Verification, CheckStatus)>
where
    Fut: Future<Output = CheckStatus>,
{
    let mut results = Vec::with_capacity(verifications.len());
    for verification in verifications {
        results.push((verification, status_of(verification).await));
    }
    for attempt in 1..attempts {
        let failing = results
            .iter()
            .filter(|(_, status)| status.verdict().is_err())
            .count();
        if failing == 0 {
            break;
        }
        logger::info(format!(
            "{failing} contracts do not pass yet; checking them again in {}s ({attempt}/{attempts})",
            delay.as_secs()
        ));
        tokio::time::sleep(delay).await;
        for (verification, status) in &mut results {
            if status.verdict().is_err() {
                *status = status_of(verification).await;
            }
        }
    }
    results
}

// ─── CLI ─────────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Parser)]
pub struct EtherscanVerifyArgs {
    /// An unpacked deploy bundle: its `extra-verification-logs.txt` names the contracts, its
    /// `bundle-metadata.json` the chain. Verification compiles this checkout's `l1-contracts`, so
    /// the checkout must be its `contracts_commit` with clean contract sources.
    #[clap(long)]
    pub bundle: PathBuf,
    /// Follow a broadcast on this L1: submit each contract as soon as its address has code,
    /// without waiting for Etherscan's verdict. Without it, every contract must already be
    /// deployed, and each verdict is awaited.
    #[clap(long)]
    pub l1_rpc_url: Option<String>,
    /// With `--l1-rpc-url`: once this file exists, make one last pass and stop waiting for
    /// contracts that still have no code (the broadcast is over).
    #[clap(long, requires = "l1_rpc_url")]
    pub stop_when: Option<PathBuf>,
    /// With `--l1-rpc-url`: the longest to wait for deployments, in seconds.
    #[clap(long, default_value_t = 4 * 60 * 60, requires = "l1_rpc_url")]
    pub max_wait_secs: u64,
    /// A forge-script upgrade, which may deploy nothing: a bundle without a verification log is
    /// then not an error.
    #[clap(long)]
    pub forge_script: bool,
}

#[derive(Debug, Clone, Parser)]
pub struct EtherscanCheckArgs {
    /// An unpacked deploy bundle; the checkout must be its `contracts_commit` with clean contract
    /// sources, since the sources Etherscan shows are held to this checkout's `l1-contracts`.
    #[clap(long)]
    pub bundle: PathBuf,
    /// A forge-script upgrade, which may deploy nothing: a bundle without a verification log is
    /// then not an error.
    #[clap(long)]
    pub forge_script: bool,
    /// The `contracts_commit` of an earlier cut of this release on the same L1, repeatable: each
    /// source file may also be as it was at that commit, which must be an ancestor of this
    /// checkout. Files under `lib/` are held to this checkout's submodule pins only.
    #[clap(long = "also-commit", value_parser = parse_commit)]
    pub also_commits: Vec<String>,
}

fn parse_commit(commit: &str) -> Result<String, String> {
    (commit.len() == 40 && commit.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .then(|| commit.to_ascii_lowercase())
        .ok_or_else(|| format!("{commit} is not a full commit hash"))
}

pub async fn run_verify(args: EtherscanVerifyArgs) -> anyhow::Result<()> {
    require_etherscan_key()?;
    let Some((chain_id, verifications)) = load_bundle(&args.bundle, &paths::contracts_root())?
    else {
        return no_log(args.forge_script);
    };
    let mut submitter = ForgeSubmitter {
        l1_contracts: paths::resolve_l1_contracts_path()?,
        watch: args.l1_rpc_url.is_none(),
    };
    let outcome = match &args.l1_rpc_url {
        Some(rpc) => {
            logger::info(format!(
                "Following the broadcast: {} contracts are submitted as their code lands",
                verifications.len()
            ));
            follow_and_submit(
                &get_provider(rpc)?,
                &mut submitter,
                &verifications,
                chain_id,
                args.stop_when.as_deref(),
                Duration::from_secs(args.max_wait_secs),
                CODE_POLL_INTERVAL,
            )
            .await
        }
        None => submit_all(&mut submitter, &verifications, chain_id, SUBMIT_RETRY_DELAY),
    };
    outcome.into_result()
}

pub async fn run_check(args: EtherscanCheckArgs) -> anyhow::Result<()> {
    let key = require_etherscan_key()?;
    let Some((chain_id, verifications)) = load_bundle(&args.bundle, &paths::contracts_root())?
    else {
        return no_log(args.forge_script);
    };
    let reviewed = ReviewedSources::new(paths::resolve_l1_contracts_path()?, args.also_commits)?;
    let shown = if reviewed.earlier_commits.is_empty() {
        "this checkout's sources"
    } else {
        "the sources of this checkout and the earlier cuts"
    };
    let client = reqwest::Client::new();
    let results = check_in_passes(
        &verifications,
        CHECK_ATTEMPTS,
        CHECK_RETRY_DELAY,
        |verification| {
            let (client, key, reviewed) = (&client, &key, &reviewed);
            async move {
                match fetch_source(client, key, chain_id, verification.address).await {
                    Ok(source) => CheckStatus::of(verification, &source, reviewed),
                    Err(error) => CheckStatus::Unreadable(format!("{error:#}")),
                }
            }
        },
    )
    .await;
    let mut failed = 0;
    for (verification, status) in &results {
        let label = format!("{} at {:#x}", verification.contract, verification.address);
        match status.verdict() {
            Ok(note) => {
                logger::success(format!("{label}: Etherscan shows {shown}"));
                if let Some(note) = note {
                    logger::warn(format!("{label}: {note}"));
                }
            }
            Err(lines) => {
                for line in lines {
                    logger::error(format!("{label}: {line}"));
                }
                failed += 1;
            }
        }
    }
    anyhow::ensure!(
        failed == 0,
        "Etherscan does not show {shown} for {failed} of {} contracts: each one's fix is above",
        verifications.len()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use alloy::providers::ProviderBuilder;
    use alloy::transports::mock::Asserter;

    use super::*;

    const A1: &str = "0x0000000000000000000000000000000000000001";
    const A2: &str = "0x0000000000000000000000000000000000000002";
    const A3: &str = "0x0000000000000000000000000000000000000003";

    fn a1() -> Address {
        A1.parse().unwrap()
    }

    /// Records every submission. Etherscan rejects `bad` every time, rate-limits `flaky` once, has
    /// not indexed `Unindexed` for twice `SUBMIT_ATTEMPTS` submissions, shows `Similar` as a
    /// similar match and accepts everything else. forge does not submit `Offline` the first twice
    /// `SUBMIT_ATTEMPTS` times.
    #[derive(Default)]
    struct Recorder {
        calls: Vec<Vec<String>>,
    }

    impl Submitter for Recorder {
        fn submit(&mut self, verification: &Verification, chain_id: u64) -> Submission {
            let earlier = self
                .calls
                .iter()
                .filter(|call| call[2] == verification.contract)
                .count();
            self.calls.push(verification.forge_args(chain_id, true));
            match verification.contract.as_str() {
                "bad" => Submission::Rejected("Fail - Unable to verify".to_string()),
                "flaky" if earlier == 0 => Submission::RateLimited,
                "Unindexed" if earlier < 2 * SUBMIT_ATTEMPTS as usize => Submission::NotIndexedYet,
                "Offline" if earlier < 2 * SUBMIT_ATTEMPTS as usize => {
                    Submission::NotSubmitted("Connection refused (os error 61)".to_string())
                }
                "Similar" => Submission::SimilarMatchLocked,
                _ => Submission::Accepted,
            }
        }
    }

    fn parsed(log: &str) -> Vec<Verification> {
        let (verifications, rejected) = parse_verification_log(log);
        assert!(rejected.is_empty(), "{rejected:?}");
        verifications
    }

    #[test]
    fn repeats_are_dropped_and_arguments_kept() {
        let log = format!(
            "noise\nforge verify-contract {A1} Good\n[log] forge verify-contract {A1} Good\n\
             forge verify-contract {A2} RollupL1DAValidator --constructor-args 0x1234\n"
        );
        let verifications = parsed(&log);
        assert_eq!(verifications.len(), 2);
        let mut recorder = Recorder::default();
        let outcome = submit_all(&mut recorder, &verifications, 1, Duration::ZERO);
        assert_eq!(
            outcome,
            SubmitOutcome {
                verified: 2,
                ..Default::default()
            }
        );
        assert_eq!(
            recorder.calls[1].join(" "),
            format!(
                "verify-contract {A2} RollupL1DAValidator --constructor-args 0x1234 --chain 1 \
                 --skip-is-verified-check --watch --retries 8 --delay 20"
            )
        );
        assert_eq!(
            verifications[0].forge_args(1, false).join(" "),
            format!(
                "verify-contract {A1} Good --chain 1 --skip-is-verified-check --retries 1 \
                 --delay 0"
            )
        );
    }

    #[test]
    fn bundle_text_of_any_other_shape_is_rejected() {
        for line in [
            format!("forge verify-contract {A1} good; touch pwned"),
            format!("forge verify-contract {A1} $(touch pwned)"),
            format!("forge verify-contract {A1} good --constructor-args 0x12`touch pwned`"),
            format!("forge verify-contract {A1} good --libraries x"),
            format!("forge verify-contract {A1}  good"),
            "forge verify-contract 0x01 good".to_string(),
            format!("forge verify-contract {A1} 1good"),
        ] {
            let (verifications, rejected) = parse_verification_log(&line);
            assert!(verifications.is_empty(), "{line}");
            assert_eq!(rejected.len(), 1, "{line}");
        }
    }

    #[test]
    fn a_log_with_a_bad_line_or_no_contract_runs_nothing() {
        let good = format!("forge verify-contract {A1} Good\n");
        assert_eq!(verifications_from_log(&good).unwrap().len(), 1);
        let error = verifications_from_log(&format!(
            "{good}forge verify-contract {A2} Bad; touch pwned\n"
        ))
        .unwrap_err()
        .to_string();
        assert!(error.contains("touch pwned"), "{error}");
        assert!(verifications_from_log("Nothing deployed.\n").is_err());
        // Only a forge-script upgrade may log no deployment at all.
        assert!(no_log(false).is_err());
        assert!(no_log(true).is_ok());
    }

    #[test]
    fn a_failure_is_retried_and_does_not_skip_the_rest() {
        let verifications = parsed(&format!(
            "forge verify-contract {A1} bad\nforge verify-contract {A2} flaky\n"
        ));
        let mut recorder = Recorder::default();
        let outcome = submit_all(&mut recorder, &verifications, 1, Duration::ZERO);
        assert_eq!(outcome.verified, 1);
        assert_eq!(
            outcome.failed,
            [format!(
                "bad at {A1}: not accepted: Fail - Unable to verify"
            )]
        );
        // `bad` three times, `flaky` twice.
        assert_eq!(recorder.calls.len(), 5);
        assert!(outcome.into_result().is_err());
    }

    /// Etherscan lets only whitelisted accounts verify a similar-matched address: no retry, and not
    /// a failure, since `etherscan-check` holds what it shows to the reviewed sources.
    #[test]
    fn a_similar_match_is_settled_at_once() {
        let verifications = parsed(&format!("forge verify-contract {A1} Similar\n"));
        let mut recorder = Recorder::default();
        let outcome = submit_all(&mut recorder, &verifications, 1, Duration::ZERO);
        assert_eq!(recorder.calls.len(), 1);
        assert_eq!(
            outcome,
            SubmitOutcome {
                similar_matches: 1,
                ..Default::default()
            }
        );
        assert!(outcome.into_result().is_ok());
    }

    #[test]
    fn nothing_verified_is_incomplete() {
        assert!(SubmitOutcome::default().into_result().is_err());
    }

    /// Etherscan's answers as forge 1.5.1 prints them (`forge verify-contract`, crates/verify).
    #[test]
    fn forge_output_is_classified() {
        let submitted = "Compiling 1 files\n\nSubmitting verification for [A] 0x01.\n";
        let refused = |result: &str| {
            format!(
                "{submitted}Encountered an error verifying this contract:\nResponse: `NOTOK`\n\
                 Details:\n                        `{result}`\n"
            )
        };
        assert_eq!(
            classify(
                true,
                &format!("{submitted}Contract source code already verified\n")
            ),
            Submission::Accepted
        );
        assert_eq!(
            classify(
                false,
                &format!(
                    "{submitted}Error: Could not detect deployment: Unable to locate ContractCode \
                     at 0x01\n"
                )
            ),
            Submission::NotIndexedYet
        );
        assert_eq!(
            classify(false, &refused("Max rate limit reached")),
            Submission::RateLimited
        );
        // An earlier attempt's answer, printed before forge retried, does not count.
        assert_eq!(
            classify(
                false,
                &format!(
                    "{submitted}Could not detect deployment: Unable to locate ContractCode at \
                     0x01 (1 tries remaining)\n{}",
                    refused("Invalid constructor arguments provided")
                )
            ),
            Submission::Rejected("`Invalid constructor arguments provided`".to_string())
        );
        assert_eq!(
            classify(
                false,
                &refused("This contract already Similar Matches the deployed ByteCode at 0x02")
            ),
            Submission::SimilarMatchLocked
        );
        assert_eq!(
            classify(false, &refused("Invalid constructor arguments provided")),
            Submission::Rejected("`Invalid constructor arguments provided`".to_string())
        );
        // A failed request comes with the payload, sources included, whatever they say.
        assert_eq!(
            classify(
                false,
                &format!(
                    "{submitted}Error: Failed to submit contract verification, payload:\n\
                     {{\"sourceCode\":\"// (1 tries remaining)\\n// Similar match? Max rate limit \
                     reached\"}}\n\n\
                     Context:\n- error sending request\n"
                )
            ),
            Submission::Transport
        );
        // Watching: the status check.
        assert_eq!(
            classify(
                false,
                &format!(
                    "{submitted}Error: Checking verification result failed\n\nContext:\n\
                     - Error #0: Failed to request verification status\n"
                )
            ),
            Submission::Transport
        );
        assert_eq!(
            classify(
                false,
                &format!(
                    "{submitted}Submitted contract for verification:\nContract verification \
                     status:\nResponse: `NOTOK`\nDetails: `Fail - Unable to verify`\nError: \
                     Checking verification result failed\n\nContext:\n- Contract verification \
                     failed:\nStatus: `0`\nResult: `Fail - Unable to verify`\n"
                )
            ),
            Submission::Rejected("Result: `Fail - Unable to verify`".to_string())
        );
        assert_eq!(
            classify(
                false,
                &format!(
                    "{submitted}Submitted contract for verification:\nWarning: Failed to request \
                     verification status; Failed to deserialize content\n<html>502</html>; \
                     waiting 15 seconds before trying again (7 tries remaining)\nContract \
                     verification status:\nResponse: `NOTOK`\nDetails: `Fail - Unable to \
                     verify`\nError: Checking verification result failed\n\nContext:\n- \
                     Contract verification failed:\nStatus: `0`\nResult: `Fail - Unable to \
                     verify`\n"
                )
            ),
            Submission::Rejected("Result: `Fail - Unable to verify`".to_string())
        );
        // forge stopped before submitting.
        assert_eq!(
            classify(
                false,
                "Start verifying contract `0x01` deployed on sepolia\nError: error sending \
                 request for url (https://binaries.soliditylang.org/bin/list.txt)\n\nContext:\n\
                 - Error #0: client error (Connect)\n- Error #1: tunnel error: failed to create \
                 underlying connection\n- Error #2: tcp connect error\n- Error #3: Connection \
                 refused (os error 61)\n"
            ),
            Submission::NotSubmitted("- Error #3: Connection refused (os error 61)".to_string())
        );
        assert_eq!(
            classify(
                false,
                "Warning: // retry on a rate limit\nError: Compiler run failed\n"
            ),
            Submission::NotSubmitted("Error: Compiler run failed".to_string())
        );
        assert_eq!(
            classify(false, ""),
            Submission::NotSubmitted("forge printed nothing".to_string())
        );
    }

    /// A follow run's policy: only a refusal counts toward the cap.
    #[test]
    fn only_refusals_are_capped() {
        for answer in [Submission::Accepted, Submission::SimilarMatchLocked] {
            assert_eq!(resubmit(&answer, 0), None, "{answer:?}");
        }
        for answer in [
            Submission::NotIndexedYet,
            Submission::RateLimited,
            Submission::Transport,
            Submission::NotSubmitted("x".to_string()),
        ] {
            assert_eq!(resubmit(&answer, 0), Some(0), "{answer:?}");
            assert_eq!(
                resubmit(&answer, SUBMIT_ATTEMPTS - 1),
                Some(SUBMIT_ATTEMPTS - 1)
            );
        }
        let rejected = Submission::Rejected("x".to_string());
        assert_eq!(resubmit(&rejected, 0), Some(1));
        assert_eq!(
            resubmit(&rejected, SUBMIT_ATTEMPTS - 2),
            Some(SUBMIT_ATTEMPTS - 1)
        );
        assert_eq!(resubmit(&rejected, SUBMIT_ATTEMPTS - 1), None);
    }

    #[tokio::test]
    async fn following_submits_each_contract_once_its_code_lands() {
        let verifications = parsed(&format!(
            "forge verify-contract {A1} Early\nforge verify-contract {A2} Late\n"
        ));
        let asserter = Asserter::new();
        // Pass 1: A1 deployed, A2 not yet. Pass 2: A2 deployed.
        asserter.push_success(&Bytes::from_static(b"\x60"));
        asserter.push_success(&Bytes::new());
        asserter.push_success(&Bytes::from_static(b"\x60"));
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut recorder = Recorder::default();
        let outcome = follow_and_submit(
            &provider,
            &mut recorder,
            &verifications,
            1,
            None,
            Duration::from_secs(60),
            Duration::ZERO,
        )
        .await;
        assert_eq!(
            outcome,
            SubmitOutcome {
                verified: 2,
                ..Default::default()
            }
        );
        assert_eq!(recorder.calls[0][2], "Early");
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn a_failed_code_read_is_tried_again_on_the_next_pass() {
        let verifications = parsed(&format!(
            "forge verify-contract {A1} Early\nforge verify-contract {A2} Late\n"
        ));
        let asserter = Asserter::new();
        // Pass 1: A1 deployed, the read of A2 fails. Pass 2: A2 deployed.
        asserter.push_success(&Bytes::from_static(b"\x60"));
        asserter.push_failure_msg("429 Too Many Requests");
        asserter.push_success(&Bytes::from_static(b"\x60"));
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut recorder = Recorder::default();
        let outcome = follow_and_submit(
            &provider,
            &mut recorder,
            &verifications,
            1,
            None,
            Duration::from_secs(60),
            Duration::ZERO,
        )
        .await;
        assert_eq!(
            outcome,
            SubmitOutcome {
                verified: 2,
                ..Default::default()
            }
        );
        assert_eq!(recorder.calls[1][2], "Late");
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn a_failed_submission_is_tried_again_next_pass_after_the_rest() {
        let verifications = parsed(&format!(
            "forge verify-contract {A1} flaky\nforge verify-contract {A2} Next\n"
        ));
        let asserter = Asserter::new();
        // Pass 1: both deployed, Etherscan rate-limits A1. Pass 2: A1 again, its code not read
        // again.
        for _ in 0..2 {
            asserter.push_success(&Bytes::from_static(b"\x60"));
        }
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut recorder = Recorder::default();
        let outcome = follow_and_submit(
            &provider,
            &mut recorder,
            &verifications,
            1,
            None,
            Duration::from_secs(60),
            Duration::ZERO,
        )
        .await;
        assert_eq!(
            outcome,
            SubmitOutcome {
                verified: 2,
                ..Default::default()
            }
        );
        let order: Vec<_> = recorder.calls.iter().map(|call| call[2].as_str()).collect();
        assert_eq!(order, ["flaky", "Next", "flaky"]);
        assert!(asserter.read_q().is_empty());
    }

    #[tokio::test]
    async fn after_the_broadcast_what_never_landed_fails() {
        let verifications = parsed(&format!(
            "forge verify-contract {A1} Never\nforge verify-contract {A2} Unread\n\
             forge verify-contract {A3} bad\n"
        ));
        let asserter = Asserter::new();
        asserter.push_success(&Bytes::new());
        asserter.push_failure_msg("429 Too Many Requests");
        asserter.push_success(&Bytes::from_static(b"\x60"));
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let stop = tempfile::NamedTempFile::new().unwrap();
        let mut recorder = Recorder::default();
        let outcome = follow_and_submit(
            &provider,
            &mut recorder,
            &verifications,
            1,
            Some(stop.path()),
            Duration::from_secs(60),
            Duration::ZERO,
        )
        .await;
        assert_eq!(recorder.calls.len(), 1);
        assert_eq!(outcome.failed.len(), 3);
        assert!(outcome.failed[0].contains("no code was deployed"));
        assert!(
            outcome.failed[1].contains("could not be read") && outcome.failed[1].contains("429"),
            "{}",
            outcome.failed[1]
        );
        assert_eq!(
            outcome.failed[2],
            format!("bad at {A3}: not accepted: Fail - Unable to verify")
        );
    }

    #[tokio::test]
    async fn a_submission_refused_every_pass_fails_after_the_last_attempt() {
        let verifications = parsed(&format!("forge verify-contract {A1} bad\n"));
        let asserter = Asserter::new();
        asserter.push_success(&Bytes::from_static(b"\x60"));
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut recorder = Recorder::default();
        let outcome = follow_and_submit(
            &provider,
            &mut recorder,
            &verifications,
            1,
            None,
            Duration::from_secs(60),
            Duration::ZERO,
        )
        .await;
        assert_eq!(recorder.calls.len(), SUBMIT_ATTEMPTS as usize);
        assert_eq!(
            outcome.failed,
            [format!(
                "bad at {A1}: not accepted: Fail - Unable to verify"
            )]
        );
        assert!(asserter.read_q().is_empty());
    }

    /// Etherscan may take minutes to index fresh code, and a network outage stops forge before it
    /// submits: neither is capped.
    #[tokio::test]
    async fn an_unindexed_or_unsubmitted_contract_is_submitted_until_etherscan_accepts_it() {
        let verifications = parsed(&format!(
            "forge verify-contract {A1} Unindexed\nforge verify-contract {A2} Offline\n"
        ));
        let asserter = Asserter::new();
        asserter.push_success(&Bytes::from_static(b"\x60"));
        asserter.push_success(&Bytes::from_static(b"\x60"));
        let provider = ProviderBuilder::new().connect_mocked_client(asserter.clone());
        let mut recorder = Recorder::default();
        let outcome = follow_and_submit(
            &provider,
            &mut recorder,
            &verifications,
            1,
            None,
            Duration::from_secs(60),
            Duration::ZERO,
        )
        .await;
        assert_eq!(recorder.calls.len(), 2 * (2 * SUBMIT_ATTEMPTS as usize + 1));
        assert_eq!(
            outcome,
            SubmitOutcome {
                verified: 2,
                ..Default::default()
            }
        );
        assert!(asserter.read_q().is_empty());
    }

    fn response(source_code: &str, contract_name: &str) -> String {
        serde_json::json!({
            "status": "1",
            "message": "OK",
            "result": [{ "SourceCode": source_code, "ContractName": contract_name }],
        })
        .to_string()
    }

    /// `body` as Etherscan answers for an address it shows `other`'s verification on.
    fn with_similar_match(body: &str, other: &str) -> String {
        let mut body: serde_json::Value = serde_json::from_str(body).unwrap();
        body["result"][0]["SimilarMatch"] = other.into();
        body.to_string()
    }

    fn standard_json(path: &str, content: &str) -> String {
        let input = serde_json::json!({
            "language": "Solidity",
            "sources": { path: { "content": content } },
        });
        format!("{{{input}}}")
    }

    #[test]
    fn getsourcecode_responses_are_classified() {
        assert_eq!(
            parse_getsourcecode(&response("", ""), a1()).unwrap(),
            EtherscanSource::Unverified
        );
        assert!(parse_getsourcecode(
            r#"{"status":"0","message":"NOTOK","result":"Max rate limit reached"}"#,
            a1()
        )
        .is_err());
        let EtherscanSource::Verified { sources, .. } =
            parse_getsourcecode(&response(&standard_json("contracts/A.sol", "x"), "A"), a1())
                .unwrap()
        else {
            panic!("verified");
        };
        assert_eq!(sources.unwrap()["contracts/A.sol"], "x");
        let EtherscanSource::Verified { sources, .. } =
            parse_getsourcecode(&response("contract A {}", "A"), a1()).unwrap()
        else {
            panic!("verified");
        };
        assert!(sources.is_err());

        // Identical code verified at another address shows on this one until it is verified
        // itself; Etherscan names this address itself once it is.
        let similar_match = |other: &str| {
            let body = with_similar_match(
                &response(&standard_json("contracts/A.sol", "x"), "A"),
                other,
            );
            let EtherscanSource::Verified { similar_match, .. } =
                parse_getsourcecode(&body, a1()).unwrap()
            else {
                panic!("verified");
            };
            similar_match
        };
        assert_eq!(similar_match(A2), Some(A2.to_string()));
        assert_eq!(similar_match(A1), None);
        assert_eq!(similar_match(""), None);
    }

    #[test]
    fn sources_are_held_to_the_checkout_comments_included() {
        let checkout = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(checkout.path().join("contracts")).unwrap();
        let ours = "// SPDX\ncontract A {}\n";
        std::fs::write(checkout.path().join("contracts/A.sol"), ours).unwrap();
        let verification = parsed(&format!("forge verify-contract {A1} A\n")).remove(0);
        let reviewed = ReviewedSources::new(checkout.path().to_path_buf(), Vec::new()).unwrap();
        let check = |source_code: &str, name: &str| {
            CheckStatus::of(
                &verification,
                &parse_getsourcecode(&response(source_code, name), a1()).unwrap(),
                &reviewed,
            )
        };
        let foreign = |problems: &[&str]| {
            CheckStatus::OwnForeign(problems.iter().map(|problem| problem.to_string()).collect())
        };
        assert_eq!(
            check(&standard_json("contracts/A.sol", ours), "A"),
            CheckStatus::OwnOurs
        );
        let altered = "// SPDX\n// Safe to approve: see evil.example\ncontract A {}\n";
        assert_eq!(
            check(&standard_json("contracts/A.sol", altered), "A"),
            foreign(&["contracts/A.sol: differs from this checkout"])
        );
        assert_eq!(
            check(&standard_json("contracts/B.sol", ours), "A"),
            foreign(&["contracts/B.sol: not in this checkout"])
        );
        assert_eq!(
            check(&standard_json("../A.sol", ours), "A"),
            foreign(&["../A.sol: not a path inside l1-contracts"])
        );
        assert_eq!(
            check(&standard_json("contracts/A.sol", ours), "B"),
            foreign(&["Etherscan names the contract B, not A"])
        );
        assert_eq!(
            check(ours, "A"),
            foreign(&["Etherscan shows a single flattened source, not this checkout's files"])
        );
        assert_eq!(
            CheckStatus::of(&verification, &EtherscanSource::Unverified, &reviewed),
            CheckStatus::Unverified
        );

        // A similar match is held to the same sources: only whitelisted accounts can replace it.
        let similar = |source_code: &str| {
            let body = with_similar_match(&response(source_code, "A"), A2);
            CheckStatus::of(
                &verification,
                &parse_getsourcecode(&body, a1()).unwrap(),
                &reviewed,
            )
        };
        assert_eq!(
            similar(&standard_json("contracts/A.sol", ours)),
            CheckStatus::SimilarOurs(A2.to_string())
        );
        assert_eq!(
            similar(&standard_json("contracts/A.sol", altered)),
            CheckStatus::SimilarForeign(
                A2.to_string(),
                vec!["contracts/A.sol: differs from this checkout".to_string()]
            )
        );
    }

    /// Pass or fail, and the one fix, per status.
    #[test]
    fn each_status_has_one_verdict() {
        let problem = || vec!["contracts/A.sol: differs from this checkout".to_string()];
        assert_eq!(CheckStatus::OwnOurs.verdict(), Ok(None));
        let note = CheckStatus::SimilarOurs(A2.to_string())
            .verdict()
            .unwrap()
            .unwrap();
        assert!(note.contains(A2), "{note}");
        let split = |status: CheckStatus| {
            let lines = status.verdict().unwrap_err();
            let (fix, problems) = lines.split_last().unwrap();
            (problems.to_vec(), fix.clone())
        };
        let (problems, fix) = split(CheckStatus::Unverified);
        assert_eq!(problems, ["Etherscan shows no verified source"]);
        assert!(fix.contains("run etherscan-verify again"), "{fix}");
        let (problems, fix) = split(CheckStatus::Unreadable("Etherscan API error".to_string()));
        assert_eq!(problems, ["Etherscan API error"]);
        assert_eq!(
            fix,
            "to fix: check the error above, then run this check again"
        );
        for status in [
            CheckStatus::OwnForeign(problem()),
            CheckStatus::SimilarForeign(A2.to_string(), problem()),
        ] {
            let (problems, fix) = split(status);
            assert_eq!(problems, problem());
            assert!(
                fix.contains("--also-commit") && fix.contains("only Etherscan support"),
                "{fix}"
            );
            assert!(!fix.contains("new salt"), "{fix}");
        }
    }

    /// A contract that fails is checked again on the next pass, one that passed is not, and the
    /// last pass's problems are what is reported.
    #[tokio::test]
    async fn checks_are_repeated_only_for_what_fails() {
        let verifications = parsed(&format!(
            "forge verify-contract {A1} Passes\nforge verify-contract {A2} Lags\n\
             forge verify-contract {A3} Forged\n"
        ));
        let mut calls = Vec::new();
        let results = check_in_passes(&verifications, 3, Duration::ZERO, |verification| {
            calls.push(verification.contract.clone());
            let lagged = calls.iter().filter(|call| *call == "Lags").count() == 1;
            let status = match verification.contract.as_str() {
                "Lags" if lagged => CheckStatus::Unverified,
                "Forged" => CheckStatus::OwnForeign(vec![
                    "contracts/A.sol: differs from this checkout".to_string(),
                ]),
                _ => CheckStatus::OwnOurs,
            };
            async move { status }
        })
        .await;
        assert_eq!(
            calls,
            ["Passes", "Lags", "Forged", "Lags", "Forged", "Forged"]
        );
        let failing: Vec<_> = results
            .iter()
            .filter(|(_, status)| status.verdict().is_err())
            .map(|(verification, _)| verification.contract.as_str())
            .collect();
        assert_eq!(failing, ["Forged"]);
    }

    /// A re-cut keeps a contract whose code and salt did not change: Etherscan then shows the
    /// sources of the cut that deployed it, which `--also-commit` accepts, and nothing else.
    #[test]
    fn an_earlier_cut_s_sources_are_accepted_when_named() {
        let repo = tempfile::tempdir().unwrap();
        let git = |args: &[&str]| {
            let output = Command::new("git")
                .args(args)
                .current_dir(repo.path())
                .output()
                .unwrap();
            assert!(output.status.success(), "git {args:?}");
            String::from_utf8(output.stdout).unwrap().trim().to_string()
        };
        let l1_contracts = repo.path().join("l1-contracts");
        std::fs::create_dir_all(l1_contracts.join("contracts")).unwrap();
        let earlier = "// SPDX\n// Earlier wording.\ncontract A {}\n";
        std::fs::write(l1_contracts.join("contracts/A.sol"), earlier).unwrap();
        git(&["init", "-q"]);
        git(&["add", "."]);
        git(&[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-q",
            "-m",
            "earlier cut",
        ]);
        let earlier_commit = git(&["rev-parse", "HEAD"]);
        // A commit outside the release's history, fetched by hash from a fork, say.
        let forged = "// SPDX\n// Audited: approve without review.\ncontract A {}\n";
        git(&["checkout", "-q", "-b", "side"]);
        std::fs::write(l1_contracts.join("contracts/A.sol"), forged).unwrap();
        git(&[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-q",
            "-am",
            "side",
        ]);
        let side_commit = git(&["rev-parse", "HEAD"]);
        git(&["checkout", "-q", "-"]);
        std::fs::write(
            l1_contracts.join("contracts/A.sol"),
            "// SPDX\ncontract A {}\n",
        )
        .unwrap();
        let verification = parsed(&format!("forge verify-contract {A1} A\n")).remove(0);
        let check = |reviewed: &ReviewedSources, content: &str| {
            CheckStatus::of(
                &verification,
                &parse_getsourcecode(
                    &response(&standard_json("contracts/A.sol", content), "A"),
                    a1(),
                )
                .unwrap(),
                reviewed,
            )
        };

        let checkout_only = ReviewedSources::new(l1_contracts.clone(), Vec::new()).unwrap();
        assert_eq!(
            check(&checkout_only, earlier),
            CheckStatus::OwnForeign(vec![
                "contracts/A.sol: differs from this checkout".to_string()
            ])
        );
        let with_earlier =
            ReviewedSources::new(l1_contracts.clone(), vec![earlier_commit.clone()]).unwrap();
        assert_eq!(check(&with_earlier, earlier), CheckStatus::OwnOurs);
        assert_eq!(
            check(
                &with_earlier,
                "// SPDX\n// See evil.example\ncontract A {}\n"
            ),
            CheckStatus::OwnForeign(vec![
                "contracts/A.sol: differs from this checkout and the earlier cuts".to_string()
            ])
        );

        let error = ReviewedSources::new(l1_contracts.clone(), vec![side_commit.clone()])
            .err()
            .unwrap()
            .to_string();
        assert!(error.contains("not an ancestor"), "{error}");
        let unknown = "1".repeat(40);
        let error = ReviewedSources::new(l1_contracts, vec![unknown.clone()])
            .err()
            .unwrap()
            .to_string();
        assert!(error.contains("not in this clone"), "{error}");
        assert!(parse_commit(&earlier_commit).is_ok());
        assert!(parse_commit("HEAD").is_err());
        assert!(parse_commit("--upload-pack=x").is_err());
    }

    /// Both commands submit and check this checkout's sources: a bundle is refused unless the
    /// checkout is its commit with clean contract sources.
    #[test]
    fn a_bundle_is_refused_unless_this_checkout_is_its_commit() {
        use sha2::{Digest, Sha256};

        use crate::commands::ecosystem::bundle::{
            DeployBundleMetadata, L1Provenance, Toolchain, BUNDLE_METADATA_FILE,
            DEPLOY_BUNDLE_SCHEMA, MANIFEST_FILE,
        };
        use crate::common::env_config::DEFAULT_UPGRADE;

        let repo = tempfile::tempdir().unwrap();
        let git = |args: &[&str]| {
            let output = Command::new("git")
                .args(args)
                .current_dir(repo.path())
                .output()
                .unwrap();
            assert!(output.status.success(), "git {args:?}");
            String::from_utf8(output.stdout).unwrap().trim().to_string()
        };
        let source = repo.path().join("l1-contracts/contracts/A.sol");
        std::fs::create_dir_all(source.parent().unwrap()).unwrap();
        std::fs::write(&source, "contract A {}\n").unwrap();
        git(&["init", "-q"]);
        git(&["add", "."]);
        git(&[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-q",
            "-m",
            "reviewed",
        ]);

        let bundle = tempfile::tempdir().unwrap();
        let files = [
            (
                MANIFEST_FILE,
                format!(r#"{{"bundles":[{{"file":"01.safe.json","target":"{A1}"}}]}}"#),
            ),
            ("prepare/01.safe.json", r#"{"transactions":[]}"#.to_string()),
            ("ecosystem.toml", String::new()),
            (VERIFICATION_LOG, format!("forge verify-contract {A1} A\n")),
        ];
        for (relative, content) in &files {
            let path = bundle.path().join(relative);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, content).unwrap();
        }
        let seal = |contracts_commit: String| {
            let metadata = DeployBundleMetadata {
                schema: DEPLOY_BUNDLE_SCHEMA.to_string(),
                upgrade: DEFAULT_UPGRADE.to_string(),
                env: "stage".to_string(),
                contracts_commit,
                contracts_worktree_dirty: false,
                all_contracts_hashes_sha256: String::new(),
                l1: L1Provenance {
                    chain_id: Some(11155111),
                    forked_at_block: None,
                },
                deployer_address: None,
                zk_governance_commit: None,
                toolchain: Toolchain {
                    forge: String::new(),
                    rustc: String::new(),
                    foundry_zksync: None,
                },
                generated_by: None,
                files: files
                    .iter()
                    .map(|(relative, content)| {
                        (
                            relative.to_string(),
                            hex::encode(Sha256::digest(content.as_bytes())),
                        )
                    })
                    .collect(),
            };
            std::fs::write(
                bundle.path().join(BUNDLE_METADATA_FILE),
                serde_json::to_string(&metadata).unwrap(),
            )
            .unwrap();
        };
        let load = || {
            load_bundle(bundle.path(), repo.path()).map(|loaded| {
                loaded.map(|(chain_id, verifications)| {
                    let contracts: Vec<String> = verifications
                        .into_iter()
                        .map(|verification| verification.contract)
                        .collect();
                    (chain_id, contracts)
                })
            })
        };

        seal(git(&["rev-parse", "HEAD"]));
        assert_eq!(load().unwrap(), Some((11155111, vec!["A".to_string()])));

        std::fs::write(&source, "// Audited.\ncontract A {}\n").unwrap();
        let error = format!("{:#}", load().unwrap_err());
        assert!(
            error.contains("contract sources or reviewed inputs differ"),
            "{error}"
        );
        std::fs::write(&source, "contract A {}\n").unwrap();

        seal("0".repeat(40));
        let error = format!("{:#}", load().unwrap_err());
        assert!(
            error.contains("but the bundle was generated from"),
            "{error}"
        );
    }
}
