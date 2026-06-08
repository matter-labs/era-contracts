use alloy::primitives::{Address, B256, U256};
use alloy::sol_types::SolCall;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::abi::{
    IDeployL2ContractsAbi, IDeployPaymasterAbi, IEnableEvmEmulatorAbi, IRegisterZKChainAbi,
    ISetupLegacyBridgeAbi,
};
use crate::common::admin_functions::{
    accept_admin, make_permanent_rollup, set_da_validator_pair, set_token_multiplier_setter,
    unpause_deposits,
};
use crate::common::output::write_output_if_requested;

use crate::common::forge::scripts::{
    deploy_l2_contracts::{
        ConsensusRegistryOutput, DefaultL2UpgradeOutput, Multicall3Output, TimestampAsserterOutput,
        DEPLOY_L2_CONTRACTS_SCRIPT_PARAMS,
    },
    register_chain::{
        NewChainParams, RegisterChainL1Config, RegisterChainOutput, DEPLOY_PAYMASTER_SCRIPT_PARAMS,
        ENABLE_EVM_EMULATOR_PARAMS, REGISTER_CHAIN_SCRIPT_PARAMS, SETUP_LEGACY_BRIDGE,
    },
};
use crate::common::SharedRunArgs;
use crate::common::{
    forge::{Forge, ForgeRunner},
    logger,
    traits::{FileConfigTrait, ReadConfig, SaveConfig},
    wallets::Wallet,
};
use crate::types::{DAValidatorType, L2ChainId, L2DACommitmentScheme, VMOption};

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
    /// L1 batch prove operator (also execute operator for EraVM)
    #[clap(long, help_heading = "Input")]
    pub prove_operator: Address,
    /// L1 batch execute operator (ZKSync OS only)
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
        default_value = "0x0000000000000000000000000000000000000000",
        help_heading = "Advanced input"
    )]
    pub token_multiplier_setter: Option<Address>,
    /// Base token address (default: ETH = 0x0...01)
    #[clap(
        long,
        default_value = "0x0000000000000000000000000000000000000001",
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
    /// Enable EVM emulator on the chain
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub evm_emulator: bool,
    /// Deploy testnet paymaster contract
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub deploy_paymaster: bool,
    /// Make the chain a permanent rollup (irreversible)
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub make_permanent_rollup: bool,
    /// Skip L2 deployments via priority transactions
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

    // Resolve VM type from CTM.
    let vm_type = {
        let is_zksync_os =
            crate::common::l1_contracts::resolve_is_zksync_os(&runner.rpc_url, ctm_proxy)
                .await
                .context("Failed to resolve isZKsyncOS from CTM")?;
        if is_zksync_os {
            VMOption::ZKSyncOsVM
        } else {
            VMOption::EraVM
        }
    };
    logger::info(format!("VM type (from L1): {:?}", vm_type));

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
        vm_type,
    };

    let input = ChainInitInput {
        ctm_proxy,
        bridgehub: args.bridgehub,
        l1_da_validator: args.l1_da_validator,
        chain_params,
        vm_type,
        l2_da_commitment_scheme: args.l2_da_commitment_scheme,
        with_legacy_bridge: args.with_legacy_bridge,
        create2_factory_salt: None,
        pause_deposits: args.pause_deposits,
        evm_emulator: args.evm_emulator,
        deploy_paymaster: args.deploy_paymaster,
        make_permanent_rollup: args.make_permanent_rollup,
        skip_priority_txs: args.skip_priority_txs,
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

/// Initialize a chain: register, accept admin, configure DA/validators, deploy L2 contracts.
pub async fn chain_init(
    runner: &mut ForgeRunner,
    deployer: &Wallet,
    owner: &Wallet,
    bridgehub_admin: &Wallet,
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
    let mut full_output = FullChainInitOutput::from_register(&register_output);

    // Accept admin via forge broadcast so the diamond proxy's admin is set on the
    // fork immediately, and the broadcast is captured in runner.runs() for Safe bundle generation.
    logger::step("Accepting ownership of chain admin...");
    accept_admin(runner, chain_admin, owner, diamond_proxy)?;

    // TODO: make this more straightforward
    // Unpause deposits unless:
    // - pause_deposits=true (caller wants them to stay paused), or
    // - with_legacy_bridge=true (RegisterZKChain.s.sol already unpaused them internally)
    if !input.pause_deposits && !input.with_legacy_bridge {
        logger::step("Unpausing deposits...");
        unpause_deposits(
            runner,
            owner,
            input.chain_params.chain_id.as_u64(),
            input.bridgehub,
        )?;
    }

    // Set DA validator pair — always required for L1-settling chains; not a
    // priority transaction and must not be skipped for ZKsync OS chains.
    logger::step("Setting DA validator pair...");
    let commitment_scheme = input.l2_da_commitment_scheme.unwrap_or_else(|| {
        L2DACommitmentScheme::from_da_and_vm_types(input.chain_params.da_mode, input.vm_type)
    });
    set_da_validator_pair(
        runner,
        owner,
        input.chain_params.chain_id.as_u64(),
        input.bridgehub,
        input.l1_da_validator,
        commitment_scheme,
    )?;

    // The remaining steps are EraVM-only: they deploy L2 system contracts via
    // L1 priority transactions. ZKsync OS embeds system contracts in genesis,
    // so skip_priority_txs=true bypasses this entire block.
    if !input.skip_priority_txs {
        // TODO: remove (pass as constructor parameter for chain admin)
        // Set token multiplier setter (only needed for non-ETH base tokens)
        let eth_base_token: Address = "0x0000000000000000000000000000000000000001"
            .parse()
            .expect("valid address");
        if input.chain_params.base_token_addr != eth_base_token {
            if let Some(setter) = input.chain_params.token_multiplier_setter {
                if setter != Address::ZERO {
                    logger::step("Setting token multiplier setter...");
                    set_token_multiplier_setter(
                        runner,
                        owner,
                        register_output.chain_admin_addr,
                        register_output.access_control_restriction_addr,
                        diamond_proxy,
                        setter,
                    )?;
                }
            }
        }

        // Enable EVM emulator (if requested)
        if input.evm_emulator {
            logger::step("Enabling EVM emulator...");
            enable_evm_emulator_step(runner, owner, chain_admin, diamond_proxy)?;
        }

        // Deploy paymaster (if requested, as owner — before L2 contracts so
        // all owner/multisig transactions are grouped together)
        if input.deploy_paymaster {
            logger::step("Deploying paymaster...");
            let paymaster_addr = deploy_paymaster_step(
                runner,
                owner,
                input.bridgehub,
                input.chain_params.chain_id.as_u64(),
            )?;
            full_output.paymaster_addr = Some(paymaster_addr);
            logger::info(format!("Paymaster deployed at: {:#x}", paymaster_addr));
        }

        // Deploy L2 contracts (deployer — last so all owner/multisig
        // transactions above are in a single signing batch)
        let governance = register_output.governance_addr;
        logger::step("Deploying L2 contracts...");
        let l2_output = deploy_l2_contracts_step(
            runner,
            deployer,
            input.bridgehub,
            input.chain_params.chain_id.as_u64(),
            governance,
            input.chain_params.owner,
            input.chain_params.da_mode,
            input.with_legacy_bridge,
        )?;
        full_output.l2_default_upgrader = Some(l2_output.l2_default_upgrader);
        full_output.consensus_registry_proxy = Some(l2_output.consensus_registry_proxy);
        full_output.multicall3 = Some(l2_output.multicall3);
        full_output.timestamp_asserter = Some(l2_output.timestamp_asserter);
    }

    // Make permanent rollup (if requested, as owner)
    if input.make_permanent_rollup {
        logger::step("Making chain a permanent rollup...");
        make_permanent_rollup(runner, chain_admin, owner, diamond_proxy)?;
    }

    // Setup legacy bridge (if requested)
    if input.with_legacy_bridge {
        logger::step("Setting up legacy bridge...");
        setup_legacy_bridge_step(
            runner,
            bridgehub_admin,
            input.bridgehub,
            input.chain_params.chain_id.as_u64(),
        )?;
    }

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

    let input_path = REGISTER_CHAIN_SCRIPT_PARAMS.input(&runner.foundry_scripts_path);
    deploy_config.save(input_path)?;

    let calldata = IRegisterZKChainAbi::runCall {
        _chainTypeManagerProxy: input.ctm_proxy,
        _chainChainId: U256::from(input.chain_params.chain_id.as_u64()),
    }
    .abi_encode()
    .into();

    let forge = Forge::new(&runner.foundry_scripts_path)
        .script(
            &REGISTER_CHAIN_SCRIPT_PARAMS.script(),
            runner.forge_args.clone(),
        )
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(runner.rpc_url.clone())
        .with_broadcast()
        .with_wallet(auth)
        .with_env("CREATE2_FACTORY_SALT", format!("{:#x}", salt));

    runner.run(forge)?;

    let output_path = REGISTER_CHAIN_SCRIPT_PARAMS.output(&runner.foundry_scripts_path);
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

fn enable_evm_emulator_step(
    runner: &mut ForgeRunner,
    auth: &Wallet,
    chain_admin: Address,
    diamond_proxy: Address,
) -> anyhow::Result<()> {
    let calldata = IEnableEvmEmulatorAbi::chainAllowEvmEmulationCall {
        chainAdmin: chain_admin,
        target: diamond_proxy,
    }
    .abi_encode()
    .into();

    let forge = Forge::new(&runner.foundry_scripts_path)
        .script(
            &ENABLE_EVM_EMULATOR_PARAMS.script(),
            runner.forge_args.clone(),
        )
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(runner.rpc_url.clone())
        .with_broadcast()
        .with_wallet(auth);

    runner.run(forge)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn deploy_l2_contracts_step(
    runner: &mut ForgeRunner,
    auth: &Wallet,
    bridgehub: Address,
    chain_id: u64,
    governance: Address,
    consensus_registry_owner: Address,
    da_mode: DAValidatorType,
    with_legacy_bridge: bool,
) -> anyhow::Result<FullL2DeployOutput> {
    let calldata = if with_legacy_bridge {
        IDeployL2ContractsAbi::runWithLegacyBridgeCall {
            _bridgehub: bridgehub,
            _chainId: U256::from(chain_id),
            _governance: governance,
            _consensusRegistryOwner: consensus_registry_owner,
            _daValidatorType: U256::from(da_mode.to_u8()),
        }
        .abi_encode()
        .into()
    } else {
        IDeployL2ContractsAbi::runCall {
            _bridgehub: bridgehub,
            _chainId: U256::from(chain_id),
            _governance: governance,
            _consensusRegistryOwner: consensus_registry_owner,
            _daValidatorType: U256::from(da_mode.to_u8()),
        }
        .abi_encode()
        .into()
    };

    let forge = Forge::new(&runner.foundry_scripts_path)
        .script(
            &DEPLOY_L2_CONTRACTS_SCRIPT_PARAMS.script(),
            runner.forge_args.clone(),
        )
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(runner.rpc_url.clone())
        .with_broadcast()
        .with_wallet(auth);

    runner.run(forge)?;

    let output_path = DEPLOY_L2_CONTRACTS_SCRIPT_PARAMS.output(&runner.foundry_scripts_path);
    let upgrader_output = DefaultL2UpgradeOutput::read(&output_path)?;
    let consensus_output = ConsensusRegistryOutput::read(&output_path)?;
    let multicall3_output = Multicall3Output::read(&output_path)?;
    let timestamp_output = TimestampAsserterOutput::read(&output_path)?;

    Ok(FullL2DeployOutput {
        l2_default_upgrader: upgrader_output.l2_default_upgrader,
        consensus_registry_proxy: consensus_output.consensus_registry_proxy,
        multicall3: multicall3_output.multicall3,
        timestamp_asserter: timestamp_output.timestamp_asserter,
    })
}

fn deploy_paymaster_step(
    runner: &mut ForgeRunner,
    auth: &Wallet,
    bridgehub: Address,
    chain_id: u64,
) -> anyhow::Result<Address> {
    let calldata = IDeployPaymasterAbi::runCall {
        _bridgehub: bridgehub,
        _chainId: U256::from(chain_id),
    }
    .abi_encode()
    .into();

    let forge = Forge::new(&runner.foundry_scripts_path)
        .script(
            &DEPLOY_PAYMASTER_SCRIPT_PARAMS.script(),
            runner.forge_args.clone(),
        )
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(runner.rpc_url.clone())
        .with_broadcast()
        .with_wallet(auth);

    runner.run(forge)?;

    let output_path = DEPLOY_PAYMASTER_SCRIPT_PARAMS.output(&runner.foundry_scripts_path);
    let output = DeployPaymasterOutput::read(output_path)?;
    Ok(output.paymaster)
}

fn setup_legacy_bridge_step(
    runner: &mut ForgeRunner,
    auth: &Wallet,
    bridgehub: Address,
    chain_id: u64,
) -> anyhow::Result<()> {
    let calldata = ISetupLegacyBridgeAbi::runCall {
        _bridgehub: bridgehub,
        _chainId: U256::from(chain_id),
    }
    .abi_encode()
    .into();

    let forge = Forge::new(&runner.foundry_scripts_path)
        .script(&SETUP_LEGACY_BRIDGE.script(), runner.forge_args.clone())
        .with_ffi()
        .with_calldata(&calldata)
        .with_rpc_url(runner.rpc_url.clone())
        .with_broadcast()
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
    pub vm_type: VMOption,
    pub l2_da_commitment_scheme: Option<L2DACommitmentScheme>,
    pub with_legacy_bridge: bool,
    pub create2_factory_salt: Option<B256>,
    pub pause_deposits: bool,
    pub evm_emulator: bool,
    pub deploy_paymaster: bool,
    pub make_permanent_rollup: bool,
    pub skip_priority_txs: bool,
}

#[derive(Debug, Clone, Default)]
pub struct FullChainInitOutput {
    pub diamond_proxy_addr: Address,
    pub governance_addr: Address,
    pub chain_admin_addr: Address,
    pub access_control_restriction_addr: Address,
    pub chain_proxy_admin_addr: Address,
    pub l2_legacy_shared_bridge_addr: Option<Address>,
    pub l2_default_upgrader: Option<Address>,
    pub consensus_registry_proxy: Option<Address>,
    pub multicall3: Option<Address>,
    pub timestamp_asserter: Option<Address>,
    pub paymaster_addr: Option<Address>,
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
            ..Default::default()
        }
    }
}

#[derive(Debug, Clone)]
struct FullL2DeployOutput {
    l2_default_upgrader: Address,
    consensus_registry_proxy: Address,
    multicall3: Address,
    timestamp_asserter: Address,
}

#[derive(Debug, Deserialize, Clone)]
struct DeployPaymasterOutput {
    paymaster: Address,
}

impl FileConfigTrait for DeployPaymasterOutput {}

// ── Output structs ──────────────────────────────────────────────────────────

#[derive(Serialize)]
pub struct ChainInitL2Contracts {
    pub l2_default_upgrader: Address,
    pub consensus_registry_addr: Address,
    pub multicall3_addr: Address,
    pub timestamp_asserter_addr: Address,
}

#[derive(Serialize)]
pub struct ChainInitOutputData {
    pub diamond_proxy_addr: Address,
    pub governance_addr: Address,
    pub chain_admin_addr: Address,
    pub access_control_restriction_addr: Address,
    pub chain_proxy_admin_addr: Address,
    pub l2_legacy_shared_bridge_addr: Option<Address>,
    pub l2_contracts: Option<ChainInitL2Contracts>,
    pub paymaster_addr: Option<Address>,
}

impl ChainInitOutputData {
    pub fn from_full_output(output: &FullChainInitOutput) -> Self {
        let l2_contracts = match (
            output.l2_default_upgrader,
            output.consensus_registry_proxy,
            output.multicall3,
            output.timestamp_asserter,
        ) {
            (Some(upgrader), Some(consensus), Some(multicall3), Some(ts_asserter)) => {
                Some(ChainInitL2Contracts {
                    l2_default_upgrader: upgrader,
                    consensus_registry_addr: consensus,
                    multicall3_addr: multicall3,
                    timestamp_asserter_addr: ts_asserter,
                })
            }
            _ => None,
        };

        Self {
            diamond_proxy_addr: output.diamond_proxy_addr,
            governance_addr: output.governance_addr,
            chain_admin_addr: output.chain_admin_addr,
            access_control_restriction_addr: output.access_control_restriction_addr,
            chain_proxy_admin_addr: output.chain_proxy_admin_addr,
            l2_legacy_shared_bridge_addr: output.l2_legacy_shared_bridge_addr,
            l2_contracts,
            paymaster_addr: output.paymaster_addr,
        }
    }
}
