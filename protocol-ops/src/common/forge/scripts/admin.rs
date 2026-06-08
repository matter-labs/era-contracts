use super::ForgeScriptParams;

pub const ADMIN_FUNCTIONS_SCRIPT_PARAMS: ForgeScriptParams = ForgeScriptParams {
    input: "script-config/config-admin-functions.toml",
    output: "script-out/output-admin-functions.toml",
    script_path: "deploy-scripts/AdminFunctions.s.sol",
};
