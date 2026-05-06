use std::path::Path;

use crate::common::files::{
    read_json_file, read_toml_file, read_yaml_file, save_json_file, save_toml_file, save_yaml_file,
};
use anyhow::{bail, Context};
use serde::{de::DeserializeOwned, Serialize};
use xshell::Shell;

// Configs that we use only inside ZK Stack CLI, we don't have protobuf implementation for them.
pub trait FileConfigTrait {}

impl<T: Serialize + FileConfigTrait> SaveConfig for T {
    fn save(&self, shell: &Shell, path: impl AsRef<Path>) -> anyhow::Result<()> {
        save_with_comment(shell, path, self, "")
    }
}

/// Reads a config file from a given path, correctly parsing file extension.
/// Supported file extensions are: `yaml`, `yml`, `toml`, `json`.
pub trait ReadConfig: Sized {
    fn read(shell: &Shell, path: impl AsRef<Path>) -> anyhow::Result<Self>;
}

impl<T> ReadConfig for T
where
    T: DeserializeOwned + Clone + FileConfigTrait,
{
    fn read(shell: &Shell, path: impl AsRef<Path>) -> anyhow::Result<Self> {
        let error_context = || format!("Failed to parse config file {:?}.", path.as_ref());

        match path.as_ref().extension().and_then(|ext| ext.to_str()) {
            Some("yaml") | Some("yml") => read_yaml_file(shell, &path).with_context(error_context),
            Some("toml") => read_toml_file(shell, &path).with_context(error_context),
            Some("json") => read_json_file(shell, &path).with_context(error_context),
            _ => bail!(format!(
                "Unsupported file extension for config file {:?}.",
                path.as_ref()
            )),
        }
    }
}

/// Saves a config file to a given path, correctly parsing file extension.
/// Supported file extensions are: `yaml`, `yml`, `toml`, `json`.
pub trait SaveConfig {
    fn save(&self, shell: &Shell, path: impl AsRef<Path>) -> anyhow::Result<()>;
}

fn save_with_comment(
    shell: &Shell,
    path: impl AsRef<Path>,
    data: impl Serialize,
    comment: impl ToString,
) -> anyhow::Result<()> {
    match path.as_ref().extension().and_then(|ext| ext.to_str()) {
        Some("yaml") | Some("yml") => save_yaml_file(shell, path, data, comment)?,
        Some("toml") => save_toml_file(shell, path, data, comment)?,
        Some("json") => save_json_file(shell, path, data)?,
        _ => bail!("Unsupported file extension for config file."),
    }
    Ok(())
}
