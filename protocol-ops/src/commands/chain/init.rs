use alloy::primitives::{Address, B256, U256};
use alloy::sol_types::SolCall;
use anyhow::Context;
use clap::Parser;
use serde::{Deserialize, Serialize};

use crate::common::abi::{
    IDeployL2ContractsAbi, IDeployPaymasterAbi, IEnableEvmEmulatorAbi, IFinalizeChainInitAbi,
    IRegisterOnAllChainsAbi, IRegisterZKChainAbi,
};
use crate::common::addresses::{ETH_ADDRESS, ZERO_ADDRESS};
use crate::common::forge::scripts::{
    deploy_l2_contracts::{
        ConsensusRegistryOutput, DefaultL2UpgradeOutput, Multicall3Output, TimestampAsserterOutput,
    },
    register_chain::{NewChainParams, RegisterChainL1Config, RegisterChainOutput},
    DEPLOY_L2_CONTRACTS_INVOCATION, DEPLOY_PAYMASTER_INVOCATION, REGISTER_CHAIN_INVOCATION,
};
use crate::common::output::write_output_if_requested;
use crate::common::SharedRunArgs;
use crate::common::{
    forge::ForgeRunner,
    logger,
    traits::{FileConfigTrait, ReadConfig, SaveConfig},
    wallets::Wallet,
};
use crate::types::{DAValidatorType, L2ChainId, L2DACommitmentScheme, PubdataContent, VMOption};

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
    /// Where the chain's pubdata goes: the L1 DA validator it registers with. Independent of
    /// `--pubdata-content`, which says how much pubdata there is to publish.
    #[clap(long, value_enum, default_value_t = DAValidatorType::Rollup, help_heading = "Advanced input")]
    pub da_mode: DAValidatorType,
    /// The L2 DA commitment scheme, when it is not the one `--da-mode` defaults to (Rollup +
    /// ZKsync OS defaults to BlobsZKSyncOS). A rollup-validator chain that publishes through
    /// commit-tx calldata rather than blobs takes `blobs-and-pubdata-keccak256`.
    #[clap(long, value_enum, help_heading = "Advanced input")]
    pub l2_da_commitment_scheme: Option<L2DACommitmentScheme>,
    /// How much pubdata the chain's batches commit to (ZKsync OS only; defaults to FullPubdata for
    /// a chain that publishes and LogsOnly for one that does not). Any combination with `--da-mode`
    /// is allowed. Must match the chain's server/prover chain config.
    #[clap(long, value_enum, help_heading = "Advanced input")]
    pub pubdata_content: Option<PubdataContent>,
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
    /// Register the chain for interop with every other chain of the ecosystem (and vice versa) once it
    /// is initialized. Permissionless and once-per-ordered-pair; pairs that are not registrable yet are
    /// skipped, see `RegisterOnAllChains.s.sol`.
    #[clap(long, default_value_t = false, num_args = 0..=1, default_missing_value = "true", help_heading = "Advanced input")]
    pub register_for_interop: bool,
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
    let vm_type = crate::common::l1_contracts::resolve_vm_type(&runner.rpc_url, ctm_proxy).await?;
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
        pubdata_content: args.pubdata_content,
        register_for_interop: args.register_for_interop,
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
    let mut full_output = FullChainInitOutput::from_register(&register_output);
    let should_unpause_deposits = !input.pause_deposits;
    // The DA validator pair is always required for the chain to commit
    // batches; it is an admin call, not a priority transaction, so it must
    // not be skipped for ZKsync OS chains (skip_priority_txs=true).
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
    let commitment_scheme = input.l2_da_commitment_scheme.unwrap_or_else(|| {
        L2DACommitmentScheme::from_da_and_vm_types(input.chain_params.da_mode, input.vm_type)
    });

    // The pubdata content is part of every batch's public input (via the ZKsync OS chain config hash),
    // so it is set here, at creation, before the chain commits its first batch. `None` means the chain
    // has no such setting (Era) and the call must not be made at all.
    let pubdata_content = input.pubdata_content.or_else(|| {
        PubdataContent::from_da_and_vm_types(input.chain_params.da_mode, input.vm_type)
    });
    anyhow::ensure!(
        !(input.make_permanent_rollup && pubdata_content == Some(PubdataContent::LogsOnly)),
        "a permanent rollup must publish the full pubdata, so it cannot be created with \
         pubdata content LogsOnly (chain {})",
        input.chain_params.chain_id.as_u64()
    );
    // A fresh chain starts at `FullPubdata`, so only a differing value needs a transaction.
    let should_set_pubdata_content =
        pubdata_content.is_some_and(|content| content != PubdataContent::FullPubdata);

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
                    pubdataContent: pubdata_content.unwrap_or_default().to_u8(),
                    shouldUnpauseDeposits: should_unpause_deposits,
                    shouldSetDaValidatorPair: should_set_da_validator_pair,
                    shouldSetPubdataContent: should_set_pubdata_content,
                    shouldMakePermanentRollup: input.make_permanent_rollup,
                },
            })
            .with_wallet(owner),
    )?;

    // The Era-style L2 contract bootstrap (EVM emulator enable, paymaster,
    // ConsensusRegistry/Multicall3/TimestampAsserter/etc.) is irrelevant on
    // ZKsync-OS chains: those L2 contracts are Era-specific and the helpers
    // read ZK-format bytecode from `zkout/`. Skip the whole block for OS.
    if !input.skip_priority_txs && !input.vm_type.is_zksync_os() {
        // These EraVM-only steps invoke default entrypoints that read/write
        // conventional IO paths; their scripts have no path-taking variants.
        anyhow::ensure!(
            runner.subdir().is_none(),
            "--subdir is not yet supported for EraVM chain-init steps \
             (L2 contracts / paymaster deployment)"
        );
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
        )?;
        full_output.l2_default_upgrader = Some(l2_output.l2_default_upgrader);
        full_output.consensus_registry_proxy = Some(l2_output.consensus_registry_proxy);
        full_output.multicall3 = Some(l2_output.multicall3);
        full_output.timestamp_asserter = Some(l2_output.timestamp_asserter);
    }

    // Register the chain for interop with the rest of the ecosystem (if requested). Kept last: the
    // script requires the chain to be registered on the Bridgehub with a batch leaf in the message
    // root, which `register_chain` above establishes (a fresh ZKsync OS chain gets its genesis leaf
    // seeded by `MessageRootBase.seedGenesisRoot`), and its service transactions need deposits
    // unpaused, which `finalizeChainInit` does.
    if input.register_for_interop {
        logger::step("Registering the chain for interop on all other chains...");
        register_on_all_chains_step(
            runner,
            deployer,
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
        // The legacy-bridge setup this gated was removed with legacy bridging.
        false,
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

fn enable_evm_emulator_step(
    runner: &mut ForgeRunner,
    auth: &Wallet,
    chain_admin: Address,
    diamond_proxy: Address,
) -> anyhow::Result<()> {
    let forge = runner
        .script_call(IEnableEvmEmulatorAbi::chainAllowEvmEmulationCall {
            chainAdmin: chain_admin,
            target: diamond_proxy,
        })
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
) -> anyhow::Result<FullL2DeployOutput> {
    let calldata = IDeployL2ContractsAbi::runCall {
        _bridgehub: bridgehub,
        _chainId: U256::from(chain_id),
        _governance: governance,
        _consensusRegistryOwner: consensus_registry_owner,
        _daValidatorType: U256::from(da_mode.to_u8()),
    }
    .abi_encode();
    let forge = runner
        .script_with_calldata(&DEPLOY_L2_CONTRACTS_INVOCATION, calldata)
        .with_wallet(auth);

    runner.run(forge)?;

    let output_path = runner.output_path(&DEPLOY_L2_CONTRACTS_INVOCATION);
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
    let forge = runner
        .script_call(IDeployPaymasterAbi::runCall {
            _bridgehub: bridgehub,
            _chainId: U256::from(chain_id),
        })
        .with_wallet(auth);

    runner.run(forge)?;

    let output_path = runner.output_path(&DEPLOY_PAYMASTER_INVOCATION);
    let output = DeployPaymasterOutput::read(output_path)?;
    Ok(output.paymaster)
}

/// Registers the chain on every other chain of the ecosystem and vice versa, through
/// `ChainRegistrationSender`. Both directions of a pair are registrable as of v32 even when both chains
/// settle directly on L1.
fn register_on_all_chains_step(
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
    pub vm_type: VMOption,
    pub l2_da_commitment_scheme: Option<L2DACommitmentScheme>,
    /// Overrides the pubdata content derived from the DA mode; see
    /// [`PubdataContent::from_da_and_vm_types`]. `None` keeps the derived value.
    pub pubdata_content: Option<PubdataContent>,
    /// Run the interop registration step (see `register_on_all_chains_step`). Off by default: on a
    /// production ecosystem which chains may talk to each other is a deliberate decision, not a
    /// side effect of creating one.
    pub register_for_interop: bool,
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
