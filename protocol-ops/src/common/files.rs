use std::{fs, path::Path};

use serde::{de::DeserializeOwned, Serialize};

pub fn read_yaml_file<T: DeserializeOwned>(path: impl AsRef<Path>) -> anyhow::Result<T> {
    let content = fs::read_to_string(path.as_ref())
        .map_err(|e| anyhow::anyhow!("read {}: {e}", path.as_ref().display()))?;
    Ok(serde_yaml::from_str(&content)?)
}

pub fn read_toml_file<T: DeserializeOwned>(path: impl AsRef<Path>) -> anyhow::Result<T> {
    let content = fs::read_to_string(path.as_ref())
        .map_err(|e| anyhow::anyhow!("read {}: {e}", path.as_ref().display()))?;
    Ok(toml::from_str(&content)?)
}

pub fn read_json_file<T: DeserializeOwned>(path: impl AsRef<Path>) -> anyhow::Result<T> {
    let content = fs::read_to_string(path.as_ref())
        .map_err(|e| anyhow::anyhow!("read {}: {e}", path.as_ref().display()))?;
    Ok(serde_json::from_str(&content)?)
}

pub fn save_yaml_file(
    path: impl AsRef<Path>,
    content: impl Serialize,
    comment: impl ToString,
) -> anyhow::Result<()> {
    let data = format!(
        "{}{}",
        comment.to_string(),
        serde_yaml::to_string(&content)?
    );
    fs::write(path.as_ref(), data)
        .map_err(|e| anyhow::anyhow!("write {}: {e}", path.as_ref().display()))
}

pub fn save_toml_file(
    path: impl AsRef<Path>,
    content: impl Serialize,
    comment: impl ToString,
) -> anyhow::Result<()> {
    let data = format!("{}{}", comment.to_string(), toml::to_string(&content)?);
    fs::write(path.as_ref(), data)
        .map_err(|e| anyhow::anyhow!("write {}: {e}", path.as_ref().display()))
}

/// Pretty-printed JSON with a final newline, so generated files diff cleanly and GitHub
/// does not flag them.
pub fn save_json_file(path: impl AsRef<Path>, content: impl Serialize) -> anyhow::Result<()> {
    fs::write(
        path.as_ref(),
        serde_json::to_string_pretty(&content)? + "\n",
    )
    .map_err(|e| anyhow::anyhow!("write {}: {e}", path.as_ref().display()))
}
