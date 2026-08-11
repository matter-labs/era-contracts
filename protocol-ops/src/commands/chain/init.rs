use alloy::primitives::{Address, B256, U256};
use alloy::sol_types::SolCall;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::abi::{IFinalizeChainInitAbi, IRegisterOnAllChainsAbi, IRegisterZKChainAbi};
use crate::common::addresses::{ETH_ADDRESS, ZERO_ADDRESS};
use crate::common::forge::scripts::{
    register_chain::{NewChainParams, RegisterChainL1Config, RegisterChainOutput},
    REGISTER_CHAIN_INVOCATION,
};
use crate::common::output::write_output_if_requested;
use crate::common::SharedRunArgs;
use crate::common::{
    forge::ForgeRunner,
    logger,
    traits::{ReadConfig, SaveConfig},
    wallets::Wallet,
};
use crate::types::{DAValidatorType, L2ChainId, L2DACommitmentScheme};

// ── CLI args ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Parser)]
pub struct ChainInitArgs {
    // Input
    /// L1 DA validator address
    #[clap(long, help_heading = "Input")]
    pub l1_da_validator: Address,
    /// Chain ID
    #[clap(long, help_heading = "Input")]
    pub chain_id: u64,
    /// L1 batch commit operator
    #[clap(long, help_heading = "Input")]
    pub commit_operator: Address,
    /// L1 batch prove operator
    #[clap(long, help_heading = "Input")]
    pub prove_operator: Address,
    /// L1 batch execute operator
    #[clap(long, help_heading = "Input")]
    pub execute_operator: Option<Address>,

    /// Bridgehub proxy address
    #[clap(long, help_heading = "Input")]
    pub bridgehub: Address,

    /// Owner address for the chain (default: sender)
    #[clap(long, help_heading = "Signers")]
    pub owner: Option<Address>,

    /// Deployer EOA address. Bootstrap emits a directory of Safe bundles via
    /// `--out`; the deployer applies them with `dev execute-safe` or any
    /// Safe-bundle-aware executor.
    #[clap(long, help_heading = "Signers")]
    pub deployer_address: Address,

    #[clap(flatten)]
    #[serde(flatten)]
    pub shared: SharedRunArgs,

    // Advanced input
    /// Token multiplier setter address
    #[clap(
        long,
        default_value = ZERO_ADDRESS,
        help_heading = "Advanced input"
    )]
    pub token_multiplier_setter: Option<Address>,
    /// Base token address (default: ETH = 0x0...01)
    #[clap(
        long,
        default_value = ETH_ADDRESS,
        help_heading = "Advanced input"
    )]
    pub base_token_addr: Address,
    /// Base token price ratio relative to ETH (numerator/denominator)
    /// e.g. "4000/1" means: 1 ETH = 4000 base tokens
    #[clap(long, default_value = "1/1", help_heading = "Advanced input")]
    pub base_token_price_ratio: String,
    /// Data availability mode
    #[clap(long, value_enum, default_value_t = DAValidatorType::Rollup, help_heading = "Advanced input")]
    pub da_mode: DAValidatorType,
    /// Override L2 DA commitment scheme (default: Rollup + ZKsync OS VM uses BlobsZKSyncOS, etc.)
    #[clap(long, value_enum, help_heading = "Advanced input")]
    pub l2_da_commitment_scheme: Option<L2DACommitmentScheme>,
    /// Keep deposits paused after init
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub pause_deposits: bool,
    /// Enable EVM emulator on the chain (forwarded to the register-chain
    /// script config as `allow_evm_emulator`)
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub evm_emulator: bool,
    /// Make the chain a permanent rollup (irreversible)
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub make_permanent_rollup: bool,
    /// Deprecated no-op, kept for CLI compatibility: ZKsync OS chains never
    /// deploy L2 contracts via priority transactions (L2 system contracts
    /// live in genesis).
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub skip_priority_txs: bool,
    /// Enable support for legacy bridge testing
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub with_legacy_bridge: bool,
}

// ── run() ───────────────────────────────────────────────────────────────────

pub async fn run(args: ChainInitArgs) -> anyhow::Result<()> {
    let (price_ratio_num, price_ratio_den) = parse_ratio(&args.base_token_price_ratio)?;

    let mut runner = ForgeRunner::new(&args.shared)?;
    let deployer = runner.prepare_sender(args.deployer_address).await?;

    let owner = Wallet::resolve(args.owner, None, &deployer)?;

    let bridgehub_admin_addr =
        crate::common::l1_contracts::resolve_bridgehub_admin(&runner.rpc_url, args.bridgehub)
            .await
            .context("resolving bridgehub.admin() from L1")?;
    let bridgehub_admin = runner.prepare_sender(bridgehub_admin_addr).await?;

    // Discover CTM proxy from L1.
    let ctm_proxy =
        crate::common::l1_contracts::discover_ctm_proxy(&runner.rpc_url, args.bridgehub)
            .await
            .context("Failed to discover CTM proxy from L1")?;
    logger::info(format!("CTM proxy (from L1): {:#x}", ctm_proxy));

    // This tooling only provisions ZKsync OS chains — refuse EraVM CTMs.
    let is_zksync_os =
        crate::common::l1_contracts::resolve_is_zksync_os(&runner.rpc_url, ctm_proxy)
            .await
            .context("Failed to resolve isZKsyncOS from CTM")?;
    anyhow::ensure!(
        is_zksync_os,
        "CTM {ctm_proxy:#x} is not a ZKsync OS CTM; this tooling only supports ZKsync OS chains"
    );

    let chain_params = NewChainParams {
        chain_id: L2ChainId::new(args.chain_id)
            .map_err(|e| anyhow::anyhow!("invalid chain ID {}: {e}", args.chain_id))?,
        base_token_addr: args.base_token_addr,
        base_token_gas_price_multiplier_numerator: price_ratio_num,
        base_token_gas_price_multiplier_denominator: price_ratio_den,
        owner: owner.address,
        commit_operator: args.commit_operator,
        prove_operator: args.prove_operator,
        execute_operator: args.execute_operator.unwrap_or(Address::ZERO),
        token_multiplier_setter: args.token_multiplier_setter,
        da_mode: args.da_mode,
    };

    let input = ChainInitInput {
        ctm_proxy,
        bridgehub: args.bridgehub,
        l1_da_validator: args.l1_da_validator,
        chain_params,
        l2_da_commitment_scheme: args.l2_da_commitment_scheme,
        with_legacy_bridge: args.with_legacy_bridge,
        create2_factory_salt: None,
        pause_deposits: args.pause_deposits,
        evm_emulator: args.evm_emulator,
        make_permanent_rollup: args.make_permanent_rollup,
    };
    let output = chain_init(&mut runner, &deployer, &owner, &bridgehub_admin, &input).await?;

    write_output_if_requested(
        "chain.init",
        &args.shared,
        &runner,
        &input,
        &ChainInitOutputData::from_full_output(&output),
    )
    .await?;

    logger::info("Chain initialized");
    logger::info(format!("Diamond proxy: {:#x}", output.diamond_proxy_addr));
    logger::info(format!("ChainAdmin:    {:#x}", output.chain_admin_addr));
    Ok(())
}

/// Initialize a chain: register, accept admin, configure DA/validators.
pub async fn chain_init(
    runner: &mut ForgeRunner,
    deployer: &Wallet,
    owner: &Wallet,
    // Retained for call-site compatibility; the legacy-bridge setup that used it has been removed.
    _bridgehub_admin: &Wallet,
    input: &ChainInitInput,
) -> anyhow::Result<FullChainInitOutput> {
    // Register chain on CTM
    logger::step(format!(
        "Registering chain ({}) on CTM...",
        input.chain_params.chain_id.as_u64()
    ));
    // Forge `--sender` controls the `from` field recorded for every bare
    // `vm.broadcast()` in RegisterZKChain.s.sol (including Utils'
    // `deployViaCreate2` which broadcasts as `tx.origin`). Passing the
    // bridgehub admin *contract* here is wrong: the resulting Safe bundle
    // targets a contract, which `dev execute-safe --private-key` can't
    // replay. Admin-gated calls in the script already broadcast explicitly
    // via `vm.broadcast(admin.owner())`, so they don't need `--sender` to
    // be the admin — the deployer EOA works for everything else.
    let register_output = register_chain(runner, deployer, input)?;
    let diamond_proxy = register_output.diamond_proxy_addr;
    let chain_admin = register_output.chain_admin_addr;
    let full_output = FullChainInitOutput::from_register(&register_output);
    let should_unpause_deposits = !input.pause_deposits && !input.with_legacy_bridge;
    // The DA validator pair is always required for the chain to commit
    // batches.
    let should_set_da_validator_pair = true;
    let eth_base_token: Address = ETH_ADDRESS.parse().expect("valid address");
    let token_multiplier_setter = if input.chain_params.base_token_addr != eth_base_token {
        input
            .chain_params
            .token_multiplier_setter
            .filter(|setter| !setter.is_zero())
            .unwrap_or_default()
    } else {
        Address::ZERO
    };
    let commitment_scheme = input
        .l2_da_commitment_scheme
        .unwrap_or_else(|| L2DACommitmentScheme::from_da_type(input.chain_params.da_mode));

    logger::step("Finalizing chain admin operations...");
    runner.run(
        runner
            .script_call(IFinalizeChainInitAbi::finalizeChainInitCall {
                _params: IFinalizeChainInitAbi::FinalizeChainInitParams {
                    chainAdmin: chain_admin,
                    accessControlRestriction: register_output.access_control_restriction_addr,
                    diamondProxy: diamond_proxy,
                    bridgehub: input.bridgehub,
                    chainId: U256::from(input.chain_params.chain_id.as_u64()),
                    l1DaValidator: input.l1_da_validator,
                    tokenMultiplierSetter: token_multiplier_setter,
                    l2DaCommitmentScheme: commitment_scheme as u8,
                    shouldUnpauseDeposits: should_unpause_deposits,
                    shouldSetDaValidatorPair: should_set_da_validator_pair,
                    shouldMakePermanentRollup: input.make_permanent_rollup,
                },
            })
            .with_wallet(owner),
    )?;

    Ok(full_output)
}

/// Register a chain on the CTM.
pub fn register_chain(
    runner: &mut ForgeRunner,
    auth: &Wallet,
    input: &ChainInitInput,
) -> anyhow::Result<RegisterChainOutput> {
    let salt = input
        .create2_factory_salt
        .unwrap_or_else(|| B256::from(rand::random::<[u8; 32]>()));
    // CREATE2 factory address is the deterministic proxy — the Solidity
    // script hardcodes `Utils.DETERMINISTIC_CREATE2_ADDRESS` and ignores
    // this config field. Passing zero to make that dead-code nature
    // explicit.
    let deploy_config = RegisterChainL1Config::new(
        &input.chain_params,
        Address::ZERO,
        Some(salt),
        input.with_legacy_bridge,
        input.evm_emulator,
    )?;

    let input_path = runner.input_path(&REGISTER_CHAIN_INVOCATION)?;
    deploy_config.save(input_path)?;

    // protocol-ops always states the script's IO paths explicitly (the
    // conventional ones unless a per-run --subdir is set); `run` with its
    // baked-in paths is for manual forge use.
    let calldata = IRegisterZKChainAbi::runWithPathsCall {
        inputPath: runner.script_rel_path(REGISTER_CHAIN_INVOCATION.input_rel()),
        outputPath: runner.script_rel_path(REGISTER_CHAIN_INVOCATION.output_rel()),
        _chainTypeManagerProxy: input.ctm_proxy,
        _chainChainId: U256::from(input.chain_params.chain_id.as_u64()),
    }
    .abi_encode();
    let forge = runner
        .script_with_calldata(&REGISTER_CHAIN_INVOCATION, calldata)
        .with_wallet(auth)
        .with_env("CREATE2_FACTORY_SALT", format!("{:#x}", salt));

    runner.run(forge)?;

    let output_path = runner.output_path(&REGISTER_CHAIN_INVOCATION);
    RegisterChainOutput::read(output_path)
}

/// Parse a ratio string like "4000/1" into (numerator, denominator).
fn parse_ratio(s: &str) -> anyhow::Result<(u64, u64)> {
    let parts: Vec<&str> = s.split('/').collect();
    if parts.len() != 2 {
        anyhow::bail!(
            "Invalid ratio format '{}'. Expected 'numerator/denominator' (e.g. '4000/1')",
            s
        );
    }
    let num: u64 = parts[0]
        .trim()
        .parse()
        .map_err(|_| anyhow::anyhow!("Invalid numerator '{}' in ratio '{}'", parts[0].trim(), s))?;
    let den: u64 = parts[1].trim().parse().map_err(|_| {
        anyhow::anyhow!("Invalid denominator '{}' in ratio '{}'", parts[1].trim(), s)
    })?;
    if den == 0 {
        anyhow::bail!("Denominator cannot be zero in ratio '{}'", s);
    }
    Ok((num, den))
}

fn _register_on_all_chains_step(
    runner: &mut ForgeRunner,
    auth: &Wallet,
    bridgehub: Address,
    chain_id: u64,
) -> anyhow::Result<()> {
    let forge = runner
        .script_call(IRegisterOnAllChainsAbi::registerOnOtherChainsCall {
            _bridgehub: bridgehub,
            _chainId: U256::from(chain_id),
        })
        .with_wallet(auth);

    runner.run(forge)?;
    Ok(())
}

// ── Internal structs ────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize)]
pub struct ChainInitInput {
    pub ctm_proxy: Address,
    pub bridgehub: Address,
    pub l1_da_validator: Address,
    pub chain_params: NewChainParams,
    pub l2_da_commitment_scheme: Option<L2DACommitmentScheme>,
    pub with_legacy_bridge: bool,
    pub create2_factory_salt: Option<B256>,
    pub pause_deposits: bool,
    pub evm_emulator: bool,
    pub make_permanent_rollup: bool,
}

#[derive(Debug, Clone, Default)]
pub struct FullChainInitOutput {
    pub diamond_proxy_addr: Address,
    pub governance_addr: Address,
    pub chain_admin_addr: Address,
    pub access_control_restriction_addr: Address,
    pub chain_proxy_admin_addr: Address,
    pub l2_legacy_shared_bridge_addr: Option<Address>,
}

impl FullChainInitOutput {
    fn from_register(output: &RegisterChainOutput) -> Self {
        Self {
            diamond_proxy_addr: output.diamond_proxy_addr,
            governance_addr: output.governance_addr,
            chain_admin_addr: output.chain_admin_addr,
            access_control_restriction_addr: output.access_control_restriction_addr,
            chain_proxy_admin_addr: output.chain_proxy_admin_addr,
            l2_legacy_shared_bridge_addr: output.l2_legacy_shared_bridge_addr,
        }
    }
}

// ── Output structs ──────────────────────────────────────────────────────────

#[derive(Serialize)]
pub struct ChainInitOutputData {
    pub diamond_proxy_addr: Address,
    pub governance_addr: Address,
    pub chain_admin_addr: Address,
    pub access_control_restriction_addr: Address,
    pub chain_proxy_admin_addr: Address,
    pub l2_legacy_shared_bridge_addr: Option<Address>,
}

impl ChainInitOutputData {
    pub fn from_full_output(output: &FullChainInitOutput) -> Self {
        Self {
            diamond_proxy_addr: output.diamond_proxy_addr,
            governance_addr: output.governance_addr,
            chain_admin_addr: output.chain_admin_addr,
            access_control_restriction_addr: output.access_control_restriction_addr,
            chain_proxy_admin_addr: output.chain_proxy_admin_addr,
            l2_legacy_shared_bridge_addr: output.l2_legacy_shared_bridge_addr,
        }
    }
}
