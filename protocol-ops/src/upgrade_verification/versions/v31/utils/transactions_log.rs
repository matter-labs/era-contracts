//! Parser for the `transactions.txt` files emitted by the v31 prepare flow
//! alongside `ecosystem.toml` and `extra-verification-logs.txt`.
//!
//! Each non-empty, non-comment line is a 0x-prefixed 32-byte L1 transaction
//! hash recording a tx broadcast during prepare. The file is **append-only**
//! across regens, so it may contain hashes from older (now-stale) deployments
//! whose bytecode is no longer in `AllContractsHashes.json`. The PUVT
//! provenance populator filters those out at recognition time — anything not
//! parseable, not a factory call, not successful on-chain, or whose bytecode
//! no longer matches a known contract is silently skipped.

use std::{collections::HashSet, fs, path::Path};

use alloy::primitives::FixedBytes;
use anyhow::{bail, Context};

/// Read and parse a transactions-log file. See [`parse`] for semantics.
pub fn read(path: &Path) -> anyhow::Result<Vec<FixedBytes<32>>> {
    let contents = fs::read_to_string(path)
        .with_context(|| format!("read transactions log at {}", path.display()))?;
    parse(&contents)
}

/// Parse a transactions-log buffer into a deduplicated list of tx hashes.
///
/// - Blank lines and `#`-prefixed comment lines are ignored.
/// - Trailing whitespace per line is trimmed.
/// - Duplicate hashes are collapsed, preserving order of first occurrence.
///   The generator appends per broadcast so duplicates only arise if the
///   same regen's output dir is reused without rotation; harmless either way.
/// - Any malformed line is an error — there is no partial-parse mode.
pub fn parse(contents: &str) -> anyhow::Result<Vec<FixedBytes<32>>> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();

    for (idx, raw) in contents.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let hash = parse_hash(line)
            .with_context(|| format!("transactions log line {}: `{raw}`", idx + 1))?;
        if seen.insert(hash) {
            out.push(hash);
        }
    }

    Ok(out)
}

fn parse_hash(line: &str) -> anyhow::Result<FixedBytes<32>> {
    let stripped = line
        .strip_prefix("0x")
        .or_else(|| line.strip_prefix("0X"))
        .unwrap_or(line);
    if stripped.len() != 64 {
        bail!(
            "expected 0x-prefixed 32-byte hash (64 hex chars), got {} chars",
            stripped.len()
        );
    }
    let bytes: [u8; 32] = alloy::hex::decode(stripped)
        .context("invalid hex")?
        .try_into()
        .map_err(|_| anyhow::anyhow!("hex decoded to wrong length"))?;
    Ok(FixedBytes::<32>::from(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_multiple_hashes_preserving_order() {
        let log = "\
0xd7c663116ac16658627cb2a84c0e553a0e288d7670069970c17722e90bbfd75d
0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
";
        let hashes = parse(log).unwrap();
        assert_eq!(hashes.len(), 3);
        assert_eq!(hashes[0].0[0], 0xd7);
        assert_eq!(hashes[1].0[0], 0xaa);
        assert_eq!(hashes[2].0[0], 0xbb);
    }

    #[test]
    fn dedupes_repeated_hashes() {
        let log = "\
0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
";
        let hashes = parse(log).unwrap();
        assert_eq!(hashes.len(), 2);
        assert_eq!(hashes[0].0[0], 0xaa);
        assert_eq!(hashes[1].0[0], 0xbb);
    }

    #[test]
    fn ignores_blank_and_comment_lines() {
        let log = "\
# leading comment

0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
   # indented comment
0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
";
        let hashes = parse(log).unwrap();
        assert_eq!(hashes.len(), 2);
    }

    #[test]
    fn rejects_wrong_length() {
        let err = parse_hash("0xabcd").unwrap_err();
        assert!(err.to_string().contains("64 hex chars"), "{}", err);
    }

    #[test]
    fn rejects_invalid_hex() {
        // 64 chars but with non-hex `zz`.
        let bad = format!("0x{}", "zz".repeat(32));
        assert!(parse_hash(&bad).is_err());
    }

    /// Sanity check against the committed stage log.
    #[test]
    fn reads_committed_stage_log_if_present() {
        use crate::common::paths::resolve_l1_contracts_path;
        let Ok(l1) = resolve_l1_contracts_path() else {
            return;
        };
        let log = l1.join("upgrade-envs/v0.31.0-interopB/output/stage/transactions.txt");
        let hashes = read(&log).expect("real stage transactions.txt must parse");
        assert!(
            !hashes.is_empty(),
            "stage transactions.txt should have entries"
        );
    }
}
