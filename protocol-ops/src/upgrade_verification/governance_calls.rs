use crate::upgrade_verification::{artifacts::GovernanceCalls, hex::decode_required_hex};

pub(crate) fn validate(calls: &GovernanceCalls) -> anyhow::Result<()> {
    decode_required_hex("governance_calls.stage0_calls", &calls.stage0_calls)?;
    decode_required_hex("governance_calls.stage1_calls", &calls.stage1_calls)?;
    decode_required_hex("governance_calls.stage2_calls", &calls.stage2_calls)?;

    Ok(())
}

pub(crate) fn from_value(
    artifact_name: &str,
    value: &toml::Value,
) -> anyhow::Result<Option<GovernanceCalls>> {
    let Some(governance_calls) = value.get("governance_calls") else {
        return Ok(None);
    };
    let table = governance_calls
        .as_table()
        .ok_or_else(|| anyhow::anyhow!("{artifact_name}.governance_calls must be a table"))?;

    Ok(Some(GovernanceCalls {
        stage0_calls: required_string_field(artifact_name, table, "stage0_calls")?.to_string(),
        stage1_calls: required_string_field(artifact_name, table, "stage1_calls")?.to_string(),
        stage2_calls: required_string_field(artifact_name, table, "stage2_calls")?.to_string(),
    }))
}

fn required_string_field<'a>(
    artifact_name: &str,
    table: &'a toml::map::Map<String, toml::Value>,
    field: &str,
) -> anyhow::Result<&'a str> {
    table
        .get(field)
        .and_then(toml::Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("{artifact_name}.governance_calls.{field} must be a string"))
}
