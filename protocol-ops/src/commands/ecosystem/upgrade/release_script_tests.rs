use super::*;

use clap::Parser;

use crate::common::forge::scripts::CURRENT_UPGRADE_ENV_DIR;
use crate::common::forge::scripts::{
    CURRENT_CORE_UPGRADE_SCRIPT_PATH, CURRENT_CTM_UPGRADE_SCRIPT_PATH,
    CURRENT_UPGRADE_LOCAL_INPUT_PATH,
};
use clap::CommandFactory;

/// Another release's upgrade-env dir, kept in the tree, for the release-selection tests.
const UPGRADE_V33_ENV_DIR: &str = "/upgrade-envs/v0.33.0-atomic-interop";

#[test]
fn prepare_defaults_to_current_release() {
    let args = UpgradePrepareAllArgs::try_parse_from(["prepare"]).unwrap();
    assert_eq!(args.ctm_script_path, CURRENT_CTM_UPGRADE_SCRIPT_PATH);
    assert_eq!(args.core_script_path, CURRENT_CORE_UPGRADE_SCRIPT_PATH);
    assert_eq!(args.upgrade_input_path, CURRENT_UPGRADE_LOCAL_INPUT_PATH);
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
    let args = UpgradePrepareAllArgs::try_parse_from(["prepare"]).unwrap();

    let local_test = read("l1-contracts/test/foundry/l1/integration/UpgradeTest_Local.t.sol");
    let ctm = contract_name(&args.ctm_script_path);
    assert!(
        local_test.contains(&format!(" is {ctm} {{")),
        "UpgradeTest_Local's CTM test subclass must extend the default CTM script {ctm}"
    );
    let core = contract_name(&args.core_script_path);
    assert!(
            local_test.contains(&format!(" is {core} {{"))
                || local_test.contains(&format!("new {core}()")),
            "UpgradeTest_Local must run the default core script {core}, itself or a test subclass of it"
        );
}

/// The default scripts must be the current release's: `yarn new-release` moves them together with the
/// upgrade-env dir, so a hand edit of one without the other would prepare a release with another
/// release's scripts.
#[test]
fn release_specific_defaults_belong_to_the_current_release() {
    let current_minor = CURRENT_UPGRADE_ENV_DIR
        .split("/v0.")
        .nth(1)
        .and_then(|rest| rest.split('.').next())
        .unwrap();
    let args = UpgradePrepareAllArgs::try_parse_from(["prepare"]).unwrap();
    for script in [&args.ctm_script_path, &args.core_script_path] {
        let script_minor = script
            .strip_prefix("deploy-scripts/upgrade/v")
            .and_then(|rest| rest.split('/').next());
        assert_eq!(
            script_minor,
            Some(current_minor),
            "{script} is not the current release's script"
        );
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
        format!("{CURRENT_UPGRADE_ENV_DIR}/stage.toml")
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
