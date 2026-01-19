use protocol_cli_common::logger;
use protocol_cli_common::forge::ForgeRunner;

pub fn display_summary(runner: &ForgeRunner) {
    // if runner.out.is_none() {
    //     return;
    // }

    // let output = runner.out.unwrap();
    // let result = AdminScriptOutput::read(shell, output).unwrap();

    // let builder = AdminCallBuilder::new(result.calls);
    // logger::info(format!(
    //     "Breakdown of calls to be performed by the chain admin:\n{}",
    //     builder.to_json_string()
    // ));

    // logger::info("\nThe calldata to be sent by the admin owner:".to_string());
    // logger::info(format!("Admin address (to): {:#?}", result.admin_address));

    // let (data, value) = builder.compile_full_calldata();

    // logger::info(format!("Total data: {}", hex::encode(&data)));
    // logger::info(format!("Total value: {}", value));
}
