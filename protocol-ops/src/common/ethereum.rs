use std::str::FromStr;
use std::time::Duration;

use alloy::network::Ethereum;
use alloy::primitives::B256;
use alloy::providers::{Provider, ProviderBuilder, RootProvider};
use alloy::rpc::client::ClientBuilder;
use alloy::transports::layers::{RateLimitRetryPolicy, RetryBackoffLayer, RetryPolicy};
use alloy::transports::TransportError;
use anyhow::Context;
use tokio::task::block_in_place;

use crate::common::l1_contracts::execution_revert_data;

pub type AlloyProvider = RootProvider<Ethereum>;

/// A public endpoint's throttle clears within seconds; a dead one shouldn't stall the run.
const RATE_LIMIT_RETRIES: u32 = 5;
/// The backoff without a hint from the endpoint: public endpoints throttle per second.
const RATE_LIMIT_BACKOFF_MS: u64 = 1_000;
/// Caps the endpoint's hint (Infura asks for minutes on a daily quota), so a stalled call takes
/// seconds.
const MAX_RATE_LIMIT_BACKOFF: Duration = Duration::from_secs(2);
/// No client-side budget: reads go out one at a time, so the backoff alone paces them.
const UNLIMITED_COMPUTE_UNITS_PER_SECOND: u64 = u64::MAX;

/// alloy's rate-limit policy (429, 503, rate-limit messages) with the hint capped, never
/// retrying a revert.
#[derive(Debug, Clone, Copy)]
struct CappedRateLimitPolicy(RateLimitRetryPolicy);

impl RetryPolicy for CappedRateLimitPolicy {
    fn should_retry(&self, error: &TransportError) -> bool {
        // alloy also matches on message text, which a revert reason can contain.
        self.0.should_retry(error) && execution_revert_data(error).is_none()
    }

    fn backoff_hint(&self, error: &TransportError) -> Option<Duration> {
        self.0
            .backoff_hint(error)
            .map(|hint| hint.min(MAX_RATE_LIMIT_BACKOFF))
    }
}

/// Convert a hex-string Merkle proof (as returned by JSON-RPC `zks_*` proof
/// methods) into the `Vec<B256>` form expected by typed `bytes32[]` calldata
/// encoders.
pub fn parse_merkle_proof<S: AsRef<str>>(proof: &[S]) -> anyhow::Result<Vec<B256>> {
    proof
        .iter()
        .map(|s| {
            let s = s.as_ref();
            B256::from_str(s.trim_start_matches("0x"))
                .with_context(|| format!("invalid merkle proof element: {s}"))
        })
        .collect()
}

pub fn get_provider(url: &str) -> anyhow::Result<AlloyProvider> {
    Ok(ProviderBuilder::new()
        .disable_recommended_fillers()
        .connect_http(url.parse().context("invalid RPC URL")?))
}

/// Retries rate-limited calls. Reads only: it also retries a 503, so a send the node accepted
/// before answering 503 would go out twice.
pub fn get_read_provider(url: &str) -> anyhow::Result<AlloyProvider> {
    read_provider(url, RATE_LIMIT_BACKOFF_MS)
}

fn read_provider(url: &str, backoff_ms: u64) -> anyhow::Result<AlloyProvider> {
    let policy = CappedRateLimitPolicy(RateLimitRetryPolicy::default());
    let retry = RetryBackoffLayer::new_with_policy(
        RATE_LIMIT_RETRIES,
        backoff_ms,
        UNLIMITED_COMPUTE_UNITS_PER_SECOND,
        policy,
    );
    let client = ClientBuilder::default()
        .layer(retry)
        .http(url.parse().context("invalid RPC URL")?);
    Ok(ProviderBuilder::new()
        .disable_recommended_fillers()
        .connect_client(client))
}

pub fn query_chain_id_sync(rpc_url: &str) -> anyhow::Result<u64> {
    let provider = get_provider(rpc_url)?;
    if let Ok(handle) = tokio::runtime::Handle::try_current() {
        block_in_place(|| handle.block_on(provider.get_chain_id())).context("eth_chainId")
    } else {
        tokio::runtime::Runtime::new()
            .context("failed to create Tokio runtime")?
            .block_on(provider.get_chain_id())
            .context("eth_chainId")
    }
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    use alloy::transports::RpcError;

    use super::*;

    const RATE_LIMITED: (&str, &str) = ("429 Too Many Requests", "");
    const CHAIN_ID: (&str, &str) = ("200 OK", r#""result":"0xaa36a7""#);
    const REVERT: (&str, &str) = (
        "200 OK",
        r#""error":{"code":3,"message":"execution reverted","data":"0x"}"#,
    );
    const RATE_LIMIT_REVERT: (&str, &str) = (
        "200 OK",
        r#""error":{"code":3,"message":"execution reverted: rate limit exceeded","data":"0x"}"#,
    );

    /// The JSON-RPC id of one HTTP request.
    fn read_request_id(stream: &mut TcpStream) -> serde_json::Value {
        let mut data = Vec::new();
        let mut buffer = [0u8; 4096];
        loop {
            let read = stream.read(&mut buffer).unwrap();
            assert_ne!(read, 0, "the connection closed mid-request");
            data.extend_from_slice(&buffer[..read]);
            let text = String::from_utf8_lossy(&data).to_string();
            let Some(end) = text.find("\r\n\r\n") else {
                continue;
            };
            let length = text[..end]
                .lines()
                .find_map(|line| {
                    line.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .map(|v| v.trim().parse::<usize>().unwrap())
                })
                .unwrap_or(0);
            if data.len() >= end + 4 + length {
                let body: serde_json::Value = serde_json::from_str(&text[end + 4..]).unwrap();
                return body["id"].clone();
            }
        }
    }

    /// A local endpoint answering `responses` (status line, JSON-RPC result or error) in turn,
    /// the last repeating; returns its URL and request count.
    fn serve(responses: &'static [(&'static str, &'static str)]) -> (String, Arc<AtomicUsize>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(AtomicUsize::new(0));
        let seen = requests.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let mut stream = stream.unwrap();
                let id = read_request_id(&mut stream);
                let index = seen.fetch_add(1, Ordering::SeqCst).min(responses.len() - 1);
                let (status, payload) = responses[index];
                let body = match payload {
                    "" => String::new(),
                    payload => format!(r#"{{"jsonrpc":"2.0","id":{id},{payload}}}"#),
                };
                let response = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                stream.write_all(response.as_bytes()).unwrap();
            }
        });
        (url, requests)
    }

    #[tokio::test]
    async fn a_rate_limited_read_is_retried_and_a_revert_is_not() {
        let (url, requests) = serve(&[RATE_LIMITED, CHAIN_ID]);
        let chain_id = read_provider(&url, 1)
            .unwrap()
            .get_chain_id()
            .await
            .unwrap();
        assert_eq!((chain_id, requests.load(Ordering::SeqCst)), (11_155_111, 2));

        for revert in [&[REVERT], &[RATE_LIMIT_REVERT]] {
            let (url, requests) = serve(revert);
            assert!(read_provider(&url, 1)
                .unwrap()
                .get_chain_id()
                .await
                .is_err());
            assert_eq!(requests.load(Ordering::SeqCst), 1);
        }
    }

    #[tokio::test]
    async fn retries_stop_at_the_cap() {
        let (url, requests) = serve(&[RATE_LIMITED]);
        let error = read_provider(&url, 1)
            .unwrap()
            .get_chain_id()
            .await
            .unwrap_err();
        assert!(
            error.to_string().contains("Max retries exceeded"),
            "{error}"
        );
        let tries = usize::try_from(RATE_LIMIT_RETRIES).unwrap() + 1;
        assert_eq!(requests.load(Ordering::SeqCst), tries);
    }

    #[test]
    fn the_policy_caps_hints_and_never_retries_a_revert() {
        let error = |response: &str| -> TransportError {
            RpcError::ErrorResp(serde_json::from_str(response).unwrap())
        };
        let policy = CappedRateLimitPolicy(RateLimitRetryPolicy::default());
        let limited = error(r#"{"code":429,"message":"rate limited, try again in 3600s"}"#);
        assert!(policy.should_retry(&limited));
        assert_eq!(policy.backoff_hint(&limited), Some(MAX_RATE_LIMIT_BACKOFF));
        let revert = error(r#"{"code":3,"message":"execution reverted: rate limit exceeded"}"#);
        assert!(RateLimitRetryPolicy::default().should_retry(&revert));
        assert!(!policy.should_retry(&revert));
    }
}
