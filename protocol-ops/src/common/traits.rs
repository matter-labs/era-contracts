use std::path::Path;

use anyhow::{bail, Context};
use serde::{de::DeserializeOwned, Serialize};

use crate::common::files::{
    read_json_file, read_toml_file, read_yaml_file, save_json_file, save_toml_file, save_yaml_file,
};

pub trait FileConfigTrait {}

impl<T: Serialize + FileConfigTrait> SaveConfig for T {
    fn save(&self, path: impl AsRef<Path>) -> anyhow::Result<()> {
        save_with_comment(path, self, "")
    }
}

pub trait ReadConfig: Sized {
    fn read(path: impl AsRef<Path>) -> anyhow::Result<Self>;
}

impl<T: DeserializeOwned + Clone + FileConfigTrait> ReadConfig for T {
    fn read(path: impl AsRef<Path>) -> anyhow::Result<Self> {
        let error_context = || format!("Failed to parse config file {:?}.", path.as_ref());
        match path.as_ref().extension().and_then(|ext| ext.to_str()) {
            Some("yaml") | Some("yml") => read_yaml_file(&path).with_context(error_context),
            Some("toml") => read_toml_file(&path).with_context(error_context),
            Some("json") => read_json_file(&path).with_context(error_context),
            _ => bail!(
                "Unsupported file extension for config file {:?}.",
                path.as_ref()
            ),
        }
    }
}

pub trait SaveConfig {
    fn save(&self, path: impl AsRef<Path>) -> anyhow::Result<()>;
}

fn save_with_comment(
    path: impl AsRef<Path>,
    data: impl Serialize,
    comment: impl ToString,
) -> anyhow::Result<()> {
    match path.as_ref().extension().and_then(|ext| ext.to_str()) {
        Some("yaml") | Some("yml") => save_yaml_file(path, data, comment)?,
        Some("toml") => save_toml_file(path, data, comment)?,
        Some("json") => save_json_file(path, data)?,
        _ => bail!("Unsupported file extension for config file."),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::{Deserialize, Serialize};
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[derive(Debug, Serialize, Deserialize, PartialEq, Clone)]
    struct Dummy {
        x: u32,
    }
    impl FileConfigTrait for Dummy {}

    #[test]
    fn read_config_json_no_shell() {
        let mut f = NamedTempFile::with_suffix(".json").unwrap();
        write!(f, r#"{{"x":42}}"#).unwrap();
        let d: Dummy = Dummy::read(f.path()).unwrap();
        assert_eq!(d, Dummy { x: 42 });
    }

    #[test]
    fn save_and_read_json() {
        let f = NamedTempFile::with_suffix(".json").unwrap();
        let original = Dummy { x: 99 };
        original.save(f.path()).unwrap();
        let loaded: Dummy = Dummy::read(f.path()).unwrap();
        assert_eq!(loaded, original);
    }
}
