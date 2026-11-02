use super::*;

use clap::Parser;

use crate::common::forge::scripts::{current_release, CurrentRelease};
use crate::common::paths;
use clap::CommandFactory;

/// Another release's upgrade-env dir, kept in the tree, for the release-selection tests.
const UPGRADE_V33_ENV_DIR: &str = "/upgrade-envs/v0.33.0-atomic-interop";

#[test]
fn prepare_defaults_to_current_release() {
    let args = UpgradePrepareAllArgs::try_parse_from(["prepare"]).unwrap();
    let release = current_release().unwrap();
    assert_eq!(
        or_current_release(&args.ctm_script_path, |r| r.ctm_script_path.clone()).unwrap(),
        release.ctm_script_path
    );
    assert_eq!(
        or_current_release(&args.core_script_path, |r| r.core_script_path.clone()).unwrap(),
        release.core_script_path
    );
    assert_eq!(
        or_current_release(&args.upgrade_input_path, CurrentRelease::local_input_path).unwrap(),
        release.local_input_path()
    );
    let help = UpgradePrepareAllArgs::command()
        .render_long_help()
        .to_string();
    assert!(help.contains("--ctm-script-path"));
    assert!(help.contains("--upgrade-input-path"));
}

/// The Foundry full-flow upgrade test of the default edge (`UpgradeTest_Local`, the registry
/// bootstrap) must run the scripts this command prepares with by default: its CTM test subclass
/// extends the default CTM script, and it runs the default core script (or a subclass). A
/// release that changes a default here fails this until that test is moved onto the new
/// scripts too.
#[test]
fn prepare_defaults_match_the_foundry_full_flow_test() {
    let contract_name = |script_path: &str| -> String {
        let file = script_path.rsplit('/').next().unwrap();
        file.trim_end_matches(".s.sol").to_string()
    };
    let read = |relative: &str| {
        std::fs::read_to_string(crate::common::paths::path_from_root(relative)).unwrap()
    };
    let release = current_release().unwrap();

    let local_test = read("l1-contracts/test/foundry/l1/integration/UpgradeTest_Local.t.sol");
    let ctm = contract_name(&release.ctm_script_path);
    assert!(
        local_test.contains(&format!(" is {ctm} {{")),
        "UpgradeTest_Local's CTM test subclass must extend the default CTM script {ctm}"
    );
    let core = contract_name(&release.core_script_path);
    assert!(
            local_test.contains(&format!(" is {core} {{"))
                || local_test.contains(&format!("new {core}()")),
            "UpgradeTest_Local must run the default core script {core}, itself or a test subclass of it"
        );
}

/// The current release (`latest.json`'s version) has its local input and its core and CTM upgrade scripts,
/// so a prepare with the defaults runs. `yarn new-release` creates all three.
#[test]
fn current_release_has_its_input_and_scripts() {
    let release = current_release().unwrap();
    let l1 = paths::resolve_l1_contracts_path().unwrap();
    let local_input = release.local_input_path();
    for path in [
        local_input.trim_start_matches('/'),
        &release.core_script_path,
        &release.ctm_script_path,
    ] {
        assert!(l1.join(path).is_file(), "the current release has no {path}");
    }
}

/// `--upgrade-env-dir` selects the env's input as well as its salts and output dir, so a prepare never mixes
/// one release's input with another's salts.
#[test]
fn upgrade_env_dir_selects_the_per_env_input() {
    let historical = UpgradePrepareAllArgs::try_parse_from([
        "prepare",
        "--env",
        "stage",
        "--upgrade-env-dir",
        UPGRADE_V33_ENV_DIR.trim_start_matches('/'),
    ])
    .unwrap();
    let cfg = prepare_env_config(&historical).unwrap().unwrap();
    assert_eq!(
        per_env_upgrade_input(&cfg).unwrap(),
        format!("{UPGRADE_V33_ENV_DIR}/stage.toml")
    );

    let current = UpgradePrepareAllArgs::try_parse_from(["prepare", "--env", "stage"]).unwrap();
    let cfg = prepare_env_config(&current).unwrap().unwrap();
    assert_eq!(
        per_env_upgrade_input(&cfg).unwrap(),
        format!("/{}/stage.toml", current_release().unwrap().env_dir())
    );
}

/// `--upgrade-env-dir` is the only release selector: an explicit `--upgrade-input-path` from another
/// release's dir is rejected rather than mixed with the selected release's salts; one inside it is accepted.
#[test]
fn explicit_input_must_sit_in_the_selected_release_dir() {
    let mixed = UpgradePrepareAllArgs::try_parse_from([
        "prepare",
        "--env",
        "stage",
        "--upgrade-input-path",
        &format!("{UPGRADE_V33_ENV_DIR}/stage.toml"),
    ])
    .unwrap();
    assert!(prepare_env_config(&mixed).is_err());

    let consistent = UpgradePrepareAllArgs::try_parse_from([
        "prepare",
        "--env",
        "stage",
        "--upgrade-env-dir",
        UPGRADE_V33_ENV_DIR.trim_start_matches('/'),
        "--upgrade-input-path",
        &format!("{UPGRADE_V33_ENV_DIR}/stage.toml"),
    ])
    .unwrap();
    let cfg = prepare_env_config(&consistent).unwrap().unwrap();
    assert!(cfg.create2_factory_salt_for_upgrade().unwrap().is_some());
    assert!(cfg
        .protocol_ops_out_dir()
        .ends_with("upgrade-envs/v0.33.0-atomic-interop/output/stage"));
}
