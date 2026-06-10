use anyhow::Context;
use serde::Deserialize;

use crate::common::logger;

pub(crate) const DEFAULT_MIGRATION_READY_TIMEOUT_SECS: u64 = 300;
pub(crate) const DEFAULT_MIGRATION_READY_POLL_INTERVAL_SECS: u64 = 2;
const MIGRATION_READY_RPC_REQUEST_TIMEOUT_SECS: u64 = 30;

#[derive(Debug)]
pub(crate) struct MigrationReadyBoundary {
    pub(crate) settlement_change_block: u64,
    pub(crate) required_finalized_block: u64,
    pub(crate) finalized_block: u64,
}

pub(crate) async fn wait_for_settlement_change_ready(
    chain_rpc_url: &str,
    previous_settlement_change_block: Option<u64>,
    timeout_secs: u64,
    poll_interval_secs: u64,
    wait_label: &str,
) -> anyhow::Result<MigrationReadyBoundary> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(
            MIGRATION_READY_RPC_REQUEST_TIMEOUT_SECS,
        ))
        .build()
        .context("build migration readiness RPC client")?;
    let timeout = std::time::Duration::from_secs(timeout_secs);
    let poll_interval = std::time::Duration::from_secs(poll_interval_secs);
    let start = std::time::Instant::now();
    let mut last_status = None::<String>;

    let settlement_change_block = loop {
        if start.elapsed() >= timeout {
            anyhow::bail!("timeout waiting for {wait_label} readiness after {timeout_secs}s");
        }

        let Some(settlement_change_block) =
            get_last_settlement_change_block_with_client(&client, chain_rpc_url).await?
        else {
            log_readiness_status(
                &mut last_status,
                "server has not reported a settlement-change block yet",
            );
            tokio::time::sleep(poll_interval).await;
            continue;
        };

        if let Some(previous_block) = previous_settlement_change_block {
            if settlement_change_block <= previous_block {
                log_readiness_status(
                    &mut last_status,
                    format!(
                        "server still reports settlement-change block {settlement_change_block}; \
                         waiting for a block greater than previous {previous_block}"
                    ),
                );
                tokio::time::sleep(poll_interval).await;
                continue;
            }
        }

        break settlement_change_block;
    };

    let required_finalized_block = settlement_change_block.saturating_sub(1);
    log_readiness_status(
        &mut last_status,
        format!(
            "using settlement-change block {settlement_change_block}; \
             waiting for finalized block >= {required_finalized_block}"
        ),
    );

    loop {
        if start.elapsed() >= timeout {
            anyhow::bail!("timeout waiting for {wait_label} readiness after {timeout_secs}s");
        }

        let Some(finalized_block) = get_finalized_block_number(&client, chain_rpc_url).await?
        else {
            log_readiness_status(
                &mut last_status,
                "server has not reported a finalized block yet",
            );
            tokio::time::sleep(poll_interval).await;
            continue;
        };

        if finalized_block >= required_finalized_block {
            return Ok(MigrationReadyBoundary {
                settlement_change_block,
                required_finalized_block,
                finalized_block,
            });
        }

        log_readiness_status(
            &mut last_status,
            format!(
                "settlement-change block {settlement_change_block}; \
                 finalized block {finalized_block}, waiting for >= {required_finalized_block}"
            ),
        );
        tokio::time::sleep(poll_interval).await;
    }
}

pub(crate) async fn get_last_settlement_change_block(
    chain_rpc_url: &str,
) -> anyhow::Result<Option<u64>> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(
            MIGRATION_READY_RPC_REQUEST_TIMEOUT_SECS,
        ))
        .build()
        .context("build settlement-change RPC client")?;

    get_last_settlement_change_block_with_client(&client, chain_rpc_url).await
}

fn log_readiness_status(last_status: &mut Option<String>, status: impl Into<String>) {
    let status = status.into();
    if last_status.as_deref() != Some(status.as_str()) {
        logger::info(status.clone());
        *last_status = Some(status);
    }
}

async fn get_last_settlement_change_block_with_client(
    client: &reqwest::Client,
    chain_rpc_url: &str,
) -> anyhow::Result<Option<u64>> {
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "zks_lastSettlementChangeBlock",
        "params": [],
    });
    let resp: JsonRpcResponse<serde_json::Value> = client
        .post(chain_rpc_url)
        .json(&body)
        .send()
        .await
        .context("send zks_lastSettlementChangeBlock request")?
        .json()
        .await
        .context("parse zks_lastSettlementChangeBlock response")?;

    if let Some(error) = resp.error {
        anyhow::bail!(
            "{} returned {}",
            "zks_lastSettlementChangeBlock",
            error.describe()
        );
    }

    resp.result
        .as_ref()
        .map(parse_u64_rpc_value)
        .transpose()
        .context("parse zks_lastSettlementChangeBlock result")
}

async fn get_finalized_block_number(
    client: &reqwest::Client,
    chain_rpc_url: &str,
) -> anyhow::Result<Option<u64>> {
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_getBlockByNumber",
        "params": ["finalized", false],
    });
    let resp: JsonRpcResponse<serde_json::Value> = client
        .post(chain_rpc_url)
        .json(&body)
        .send()
        .await
        .context("send eth_getBlockByNumber(finalized) request")?
        .json()
        .await
        .context("parse eth_getBlockByNumber(finalized) response")?;

    if let Some(error) = resp.error {
        anyhow::bail!(
            "{} returned {}",
            "eth_getBlockByNumber(finalized)",
            error.describe()
        );
    }

    let Some(block) = resp.result else {
        return Ok(None);
    };
    let number = block
        .get("number")
        .ok_or_else(|| anyhow::anyhow!("eth_getBlockByNumber(finalized) result has no number"))?;

    parse_u64_rpc_value(number)
        .map(Some)
        .context("parse eth_getBlockByNumber(finalized).number")
}

fn parse_u64_rpc_value(value: &serde_json::Value) -> anyhow::Result<u64> {
    match value {
        serde_json::Value::Number(number) => number
            .as_u64()
            .ok_or_else(|| anyhow::anyhow!("expected unsigned u64 JSON number, got {value}")),
        serde_json::Value::String(raw) => {
            if let Some(hex) = raw.strip_prefix("0x") {
                u64::from_str_radix(hex, 16).with_context(|| format!("parse hex u64 value {raw}"))
            } else {
                raw.parse::<u64>()
                    .with_context(|| format!("parse decimal u64 value {raw}"))
            }
        }
        _ => anyhow::bail!("expected u64 JSON number or string, got {value}"),
    }
}

#[derive(Debug, Deserialize)]
struct JsonRpcResponse<T> {
    result: Option<T>,
    #[serde(default)]
    error: Option<JsonRpcError>,
}

#[derive(Debug, Deserialize)]
struct JsonRpcError {
    code: i64,
    message: String,
    #[serde(default)]
    data: Option<serde_json::Value>,
}

impl JsonRpcError {
    fn describe(&self) -> String {
        match &self.data {
            Some(data) => format!("JSON-RPC error {}: {} ({data})", self.code, self.message),
            None => format!("JSON-RPC error {}: {}", self.code, self.message),
        }
    }
}
