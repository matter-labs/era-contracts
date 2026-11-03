//! Merging the core and per-CTM prepare outputs into the package's one governance bundle.

use std::fs;
use std::path::Path;

use alloy::hex;
use alloy::primitives::Address;
use alloy::sol_types::SolCall;
use anyhow::Context;

use crate::common::external_actions::{ExternalAction, GOVERNANCE_PHASE};
use crate::common::governance_calls::GovernanceCallsTable;
use crate::common::logger;

/// A governance call the merger appends that no prepare script emitted (the PUH/Guardians
/// wiring, the CTM `acceptOwnership()` normalization). Declared in the merged TOML's
/// `external_actions` exactly like the scripts' own, so the merged bundles never carry a call the
/// artifact does not name.
#[derive(Debug, Clone)]
pub(super) struct ExtraGovernanceCall {
    pub label: &'static str,
    pub authority: &'static str,
    pub call: crate::common::governance_calls::GovernanceCall,
}

alloy::sol! {
    /// The domain executors' governance entrypoints — the executor legs a registry-driven package
    /// carries. Each is a function of an (executor, object) pair the prepares report, so the merge
    /// DERIVES them rather than reading them from a prepare bundle. `zkstack-out` does not export
    /// the executors, so only these entrypoints are mirrored.
    interface IUpgradeExecutorEntrypoints {
        function applyL1Upgrade(address _coreTransition);
        function applyInfrastructureUpgrade(address _infrastructureTransition);
        function applyCTMUpgrade(address _transition);
    }
}

/// The provenance invariant of one prepare output: the governance bundle IS the
/// `external_actions` the script declared for the governance phase, in declaration order — same
/// target, same value, same calldata, one for one (`ExternalActionsLib.callsForPhase` emits it from
/// the same ledger). A script that composes a call it never declared fails the merge instead of
/// shipping it; so does one that declares an action it then omits, or emits the declared ones in
/// another order. The executor legs are not in any prepare's bundle: the merge derives them from
/// the objects the prepares report.
pub(super) fn check_bundle_provenance(
    source: &str,
    gov: &GovernanceCallsTable,
    declared: &[ExternalAction],
) -> anyhow::Result<()> {
    use crate::common::governance_calls::decode_calls;
    let calls =
        decode_calls(&gov.calls).with_context(|| format!("{source}: decode governance calls"))?;
    let for_phase: Vec<&ExternalAction> = declared
        .iter()
        .filter(|a| a.phase == GOVERNANCE_PHASE)
        .collect();
    // Matched one-for-one rather than by set membership, so a bundle cannot carry a declared call
    // twice over while a second declaration goes unemitted.
    let mut claimed = vec![false; for_phase.len()];
    let mut order = Vec::with_capacity(calls.len());
    for call in &calls {
        let matched = for_phase
            .iter()
            .enumerate()
            .position(|(i, action)| !claimed[i] && action.is_call(call));
        match matched {
            Some(i) => {
                claimed[i] = true;
                order.push(i);
            }
            None => anyhow::bail!(
                "{source}: the governance bundle carries a call no declared external action \
                 accounts for — target {:#x}, value {}, selector 0x{}. Every emitted call must be \
                 a declared action (see ExternalActionsLib); the executor legs are derived by the \
                 merge from the objects the prepares report",
                call.target,
                call.value,
                hex::encode(&call.data[..call.data.len().min(4)])
            ),
        }
    }
    if let Some(i) = claimed.iter().position(|c| !c) {
        anyhow::bail!(
            "{source}: declares a governance external action it never emits — {}",
            for_phase[i].describe()
        );
    }
    // The verifier holds the merged bundle's external actions to their declared order, so a
    // prepare that emits them in another one is refused here rather than there.
    anyhow::ensure!(
        order.windows(2).all(|pair| pair[0] < pair[1]),
        "{source}: emits its declared governance external actions in another order than it \
         declares them"
    );
    Ok(())
}

/// The objects a prepare reported in its `[registry]` summary, nonzero only.
pub(super) fn registry_object(
    body: &toml::value::Table,
    key: &str,
) -> anyhow::Result<Option<Address>> {
    let Some(value) = body.get("registry").and_then(|registry| registry.get(key)) else {
        return Ok(None);
    };
    let raw = value
        .as_str()
        .with_context(|| format!("[registry] {key} must be an address string"))?;
    let address: Address = raw
        .parse()
        .with_context(|| format!("[registry] {key} = {raw:?} is not an address"))?;
    Ok((!address.is_zero()).then_some(address))
}

/// One derived executor leg, in canonical order (`LegKind`'s order in the verifier).
pub(super) fn executor_leg(
    executor: Address,
    data: Vec<u8>,
) -> crate::common::governance_calls::GovernanceCall {
    crate::common::governance_calls::GovernanceCall {
        target: executor,
        value: alloy::primitives::U256::ZERO,
        data,
    }
}

/// The executor legs the merged bundle carries, DERIVED from the prepare summaries in canonical
/// order — core, then CTM infrastructure, then the CTM transition — each only when its object is
/// nonzero, all with no value:
///
/// 1. `CoreUpgradeExecutor.applyL1Upgrade(core_transition_addr)` on `core_upgrade_executor_addr`;
/// 2. `CTMUpgradeExecutor.applyInfrastructureUpgrade(ctm_infrastructure_transition_addr)` on
///    `ctm_upgrade_executor_addr`;
/// 3. `CTMUpgradeExecutor.applyCTMUpgrade(ctm_transition_addr)` on `ctm_upgrade_executor_addr`.
///
/// A bootstrap edge (`bootstrap_migration_addr` nonzero) and a transition replacement
/// (`replacement_transition_addr` nonzero) derive none: the bootstrap's core transition rides its
/// own derived sequence, and a replacement is one declared `forward`. Either one reporting an
/// object only a leg would apply is refused, as is a leg whose executor is missing or zero and a
/// package that is none of the three kinds yet derives no leg.
pub(super) fn derive_executor_legs(
    core: &toml::value::Table,
    ctms: &[(Address, &toml::value::Table)],
) -> anyhow::Result<Vec<crate::common::governance_calls::GovernanceCall>> {
    let core_transition = registry_object(core, "core_transition_addr").context("core prepare")?;
    let core_executor =
        registry_object(core, "core_upgrade_executor_addr").context("core prepare")?;

    let mut infrastructure = None;
    let mut transition = None;
    let mut ctm_executor = None;
    let mut bootstrap = None;
    let mut replacement = None;
    for (proxy, body) in ctms {
        let read = |key: &str| {
            registry_object(body, key).with_context(|| format!("CTM prepare {proxy:#x}"))
        };
        for (slot, key) in [
            (&mut infrastructure, "ctm_infrastructure_transition_addr"),
            (&mut transition, "ctm_transition_addr"),
            (&mut ctm_executor, "ctm_upgrade_executor_addr"),
            (&mut bootstrap, "bootstrap_migration_addr"),
            (&mut replacement, "replacement_transition_addr"),
        ] {
            if let Some(address) = read(key)? {
                anyhow::ensure!(
                    slot.is_none(),
                    "two CTM prepares report a {key}; one upgrade drives exactly one CTM"
                );
                *slot = Some(address);
            }
        }
    }

    if let Some(migration) = bootstrap {
        anyhow::ensure!(
            replacement.is_none(),
            "the CTM prepare reports both a bootstrap migration ({migration:#x}) and a \
             replacement transition: one package is one kind"
        );
        for (key, object) in [
            ("ctm_infrastructure_transition_addr", infrastructure),
            ("ctm_transition_addr", transition),
        ] {
            if let Some(object) = object {
                anyhow::bail!(
                    "the bootstrap edge {migration:#x} derives no executor leg, but its CTM \
                     prepare reports {key} {object:#x}, which nothing in the edge would apply"
                );
            }
        }
        return Ok(Vec::new());
    }
    if let Some(replacement) = replacement {
        for (key, object) in [
            ("core_transition_addr", core_transition),
            ("ctm_infrastructure_transition_addr", infrastructure),
        ] {
            if let Some(object) = object {
                anyhow::bail!(
                    "the transition replacement {replacement:#x} carries no executor leg, but \
                     the package reports {key} {object:#x}, which nothing in it would apply"
                );
            }
        }
        return Ok(Vec::new());
    }

    let require_executor = |executor: Option<Address>, key: &str, object: Address| {
        executor.with_context(|| {
            format!(
                "the prepares report {object:#x} for an executor leg but no {key} (missing or \
                 zero) to send it to"
            )
        })
    };
    let mut legs = Vec::new();
    if let Some(object) = core_transition {
        let executor = require_executor(core_executor, "core_upgrade_executor_addr", object)?;
        legs.push(executor_leg(
            executor,
            IUpgradeExecutorEntrypoints::applyL1UpgradeCall {
                _coreTransition: object,
            }
            .abi_encode(),
        ));
    }
    if let Some(object) = infrastructure {
        let executor = require_executor(ctm_executor, "ctm_upgrade_executor_addr", object)?;
        legs.push(executor_leg(
            executor,
            IUpgradeExecutorEntrypoints::applyInfrastructureUpgradeCall {
                _infrastructureTransition: object,
            }
            .abi_encode(),
        ));
    }
    if let Some(object) = transition {
        let executor = require_executor(ctm_executor, "ctm_upgrade_executor_addr", object)?;
        legs.push(executor_leg(
            executor,
            IUpgradeExecutorEntrypoints::applyCTMUpgradeCall {
                _transition: object,
            }
            .abi_encode(),
        ));
    }
    anyhow::ensure!(
        !legs.is_empty(),
        "the prepares report no core transition, no CTM infrastructure transition and no CTM \
         transition, and the package is neither a bootstrap edge nor a transition replacement: \
         it upgrades nothing"
    );
    Ok(legs)
}

/// Merge the core + per-CTM prepare TOMLs, the derived executor legs and the merger's own extras
/// (the in-memory PUH/Guardians wiring and the CTM `acceptOwnership()` normalization) into a
/// single ecosystem TOML at `dst`.
///
/// The merger COMPOSES nothing. The one bundle is, in order: the extras (they must precede a
/// bootstrap's `ctm.transferOwnership(migration)`, which assumes governance already owns the
/// CTM), the core prepare's declared calls, the DERIVED executor legs ([`derive_executor_legs`]:
/// one contiguous run in canonical order, none for a bootstrap or a replacement), then the CTM
/// prepare's declared calls. Every call other than a leg is declared in `external_actions` with
/// phase `governance`; a prepare bundle carrying a call the artifact does not name fails the
/// merge (`check_bundle_provenance`). The legs need no summary table of their own: the verifier
/// recovers them from the calldata and reconciles them with `[core.registry]` and
/// `[ctms.*.registry]`. Shape:
///
/// ```toml
/// [[external_actions]]            # every governance/admin call that is NOT an executor leg,
/// phase = "governance"            # carrying the call itself (see `common::external_actions`)
/// label = "…"
/// authority = "…"
/// target = "0x…"
/// value = "0"
/// data = "0x…"
///
/// [governance_calls]              # the one bundle: extras, core actions, the DERIVED legs,
/// calls = "0x..."                 # CTM actions
///
/// [test_upgrade_calls]            # the CTM prepare's simulator probes, when it wrote any
/// test_create_chain_zkos = "0x..."
/// test_create_chain_zkos_caller = "0x..."
/// test_upgrade_chain_zkos = "0x..."
/// test_upgrade_chain_zkos_caller = "0x..."
///
/// [core]                          # whole core TOML minus its [governance_calls]; its
/// ...                             # [registry] names the core leg's object and executor
///
/// [ctms.zksync_os]                # whole CTM TOML minus its [governance_calls] and probes;
/// ...                             # one section per ZKsyncOS CTM.
/// ...
///
/// [zk_governance]                 # only when the PUH governance set was redeployed
/// new_puh_impl = "0x..."
/// new_guardians = "0x..."
/// new_security_council = "0x..."
/// new_emergency_upgrade_board = "0x..."
/// ```
pub(super) fn write_merged_ecosystem_toml(
    core_toml: &Path,
    ctm_entries: &[crate::commands::ecosystem::upgrade_inner::CtmPrepareEntry],
    extras: &[ExtraGovernanceCall],
    zk_governance: Option<&crate::commands::ecosystem::zk_governance::ZkGovernanceOutcome>,
    dst: &Path,
) -> anyhow::Result<()> {
    use toml::value::Value;

    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut ctm_outputs = Vec::with_capacity(ctm_entries.len());
    for entry in ctm_entries {
        ctm_outputs.push((entry.proxy, load_prepare_output(&entry.toml)?));
    }
    let mut doc = merge_prepare_outputs(load_prepare_output(core_toml)?, ctm_outputs, extras)?;
    if let Some(zk_governance) = zk_governance {
        let mut table = toml::value::Table::new();
        table.insert(
            "new_puh_impl".into(),
            Value::String(format!("{:#x}", zk_governance.new_puh_impl)),
        );
        table.insert(
            "new_guardians".into(),
            Value::String(format!("{:#x}", zk_governance.new_guardians)),
        );
        table.insert(
            "new_security_council".into(),
            Value::String(format!("{:#x}", zk_governance.new_security_council)),
        );
        table.insert(
            "new_emergency_upgrade_board".into(),
            Value::String(format!("{:#x}", zk_governance.new_emergency_upgrade_board)),
        );
        doc.insert("zk_governance".into(), Value::Table(table));
    }

    let body = format!(
        "# Auto-generated by `protocol-ops ecosystem upgrade-prepare-all`.\n\
         # Merged ecosystem upgrade artifact: top-level [governance_calls] calls is\n\
         # the one governance bundle of {} prepare TOML(s) — the merger's extras,\n\
         # the core prepare's calls, the derived executor legs (applyL1Upgrade ->\n\
         # applyInfrastructureUpgrade -> applyCTMUpgrade) and the CTM prepare's calls,\n\
         # never composed here; `external_actions` names every call in it that is\n\
         # not an executor leg.\n\
         # [core] mirrors the\n\
         # core prepare output (minus its own [governance_calls]); [ctms.zksync_os]\n\
         # mirrors the ZKsyncOS CTM prepare output\n\
         # for downstream verification. [misc] carries shared metadata used\n\
         # by verification. When [zk_governance] is present, it names\n\
         # the zk-governance contracts the bundle wires in.\n\n{}",
        1 + ctm_entries.len(),
        toml::to_string(&doc).context("serialize merged ecosystem TOML")?
    );
    fs::write(dst, body)
        .with_context(|| format!("Failed to write merged ecosystem TOML: {}", dst.display()))?;
    logger::info(format!(
        "Merged ecosystem TOML written to: {}",
        dst.display()
    ));
    Ok(())
}

/// A ZKsync OS CTM's probes under the simulator's tags: `test_<probe>` becomes `test_<probe>_zkos`
/// and its `test_<probe>_caller` becomes `test_<probe>_zkos_caller`.
pub(super) fn zksync_os_probe_tags(probes: toml::value::Table) -> toml::value::Table {
    probes
        .into_iter()
        .map(|(key, value)| {
            let tag = match key.strip_suffix("_caller") {
                Some(probe) => format!("{probe}_zkos_caller"),
                None => format!("{key}_zkos"),
            };
            (tag, value)
        })
        .collect()
}

/// One prepare output split into its body, its governance bundle and its declared actions.
pub(super) struct PrepareOutputParts {
    pub(super) body: toml::value::Table,
    pub(super) gov: GovernanceCallsTable,
    /// The script's declared `external_actions` (see `ExternalActionsLib.serialize`).
    pub(super) external_actions: Vec<ExternalAction>,
}

/// Reads a prepare output and pops its `[governance_calls]` (always present) and
/// `external_actions` out, so governance can be merged at top level.
pub(super) fn load_prepare_output(path: &Path) -> anyhow::Result<PrepareOutputParts> {
    let raw = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let mut value: toml::value::Table =
        toml::from_str(&raw).with_context(|| format!("parse {}", path.display()))?;
    let gov = value
        .remove("governance_calls")
        .with_context(|| format!("missing [governance_calls] in {}", path.display()))?;
    let gov: GovernanceCallsTable = gov
        .try_into()
        .with_context(|| format!("invalid [governance_calls] in {}", path.display()))?;
    let external_actions: Vec<ExternalAction> = value
        .remove("external_actions")
        .map(|v| {
            v.try_into()
                .with_context(|| format!("invalid external_actions in {}", path.display()))
        })
        .transpose()?
        .unwrap_or_default();
    Ok(PrepareOutputParts {
        body: value,
        gov,
        external_actions,
    })
}

/// The merged document of [`write_merged_ecosystem_toml`] minus `[zk_governance]`:
/// `external_actions`, `[governance_calls]`, the optional `[test_upgrade_calls]`, `[core]`,
/// `[ctms.*]` and `[misc]`. `toml::to_string` writes the keys in alphabetical order.
pub(super) fn merge_prepare_outputs(
    core: PrepareOutputParts,
    ctms: Vec<(Address, PrepareOutputParts)>,
    extras: &[ExtraGovernanceCall],
) -> anyhow::Result<toml::value::Table> {
    use crate::common::governance_calls::{encode_calls, merge_call_array_hex};
    use toml::value::{Table, Value};

    let PrepareOutputParts {
        body: mut core_body,
        gov: core_gov,
        external_actions: core_actions,
    } = core;
    check_bundle_provenance("core prepare", &core_gov, &core_actions)?;
    let legs = derive_executor_legs(
        &core_body,
        &ctms
            .iter()
            .map(|(proxy, ctm)| (*proxy, &ctm.body))
            .collect::<Vec<_>>(),
    )?;
    let misc_body = match core_body.remove("misc") {
        Some(Value::Table(table)) => Some(table),
        Some(other) => anyhow::bail!(
            "[misc] in the core prepare output must be a table (got {})",
            other.type_str()
        ),
        None => None,
    };

    let extra_calls: Vec<_> = extras.iter().map(|e| e.call.clone()).collect();
    let mut external_actions: Vec<ExternalAction> = extras
        .iter()
        .map(|e| ExternalAction::governance(e.label, e.authority, &e.call))
        .collect();
    external_actions.extend(core_actions);
    let mut chunks: Vec<String> = vec![
        format!("0x{}", hex::encode(encode_calls(&extra_calls))),
        core_gov.calls,
    ];

    // The derived legs sit after the core prepare's declared actions and before the CTM's.
    chunks.push(format!("0x{}", hex::encode(encode_calls(&legs))));

    // `UpgradeInner::prepare` rejects any non-ZKsync-OS CTM, so every CTM that
    // reaches the merge is ZKsync OS. The merge keys per-CTM sections by the fixed
    // `zksync_os` label, so two CTMs in one upgrade collide here.
    let mut ctms_table = Table::new();
    let mut test_upgrade_calls: Option<Table> = None;
    for (proxy, ctm) in ctms {
        let label = "zksync_os";
        if ctms_table.contains_key(label) {
            anyhow::bail!(
                "duplicate CTM section `{label}`: a single upgrade merges at most one ZKsyncOS CTM"
            );
        }
        check_bundle_provenance(
            &format!("CTM prepare {proxy:#x}"),
            &ctm.gov,
            &ctm.external_actions,
        )?;
        external_actions.extend(ctm.external_actions);
        let mut body = ctm.body;
        // The simulator reads the probes at the top level only, under ZKsync OS tags.
        test_upgrade_calls = match body.remove("test_upgrade_calls") {
            Some(Value::Table(probes)) => Some(zksync_os_probe_tags(probes)),
            Some(other) => anyhow::bail!(
                "[test_upgrade_calls] in CTM prepare {proxy:#x} must be a table (got {})",
                other.type_str()
            ),
            None => None,
        };
        ctms_table.insert(label.to_string(), Value::Table(body));
        chunks.push(ctm.gov.calls);
    }

    let mut governance_calls_table = Table::new();
    governance_calls_table.insert(
        "calls".into(),
        Value::String(merge_call_array_hex(
            &chunks.iter().map(String::as_str).collect::<Vec<_>>(),
        )?),
    );

    let mut doc = Table::new();
    doc.insert(
        "external_actions".into(),
        Value::try_from(&external_actions).context("serialize the merged external actions")?,
    );
    doc.insert(
        "governance_calls".into(),
        Value::Table(governance_calls_table),
    );
    if let Some(probes) = test_upgrade_calls {
        doc.insert("test_upgrade_calls".into(), Value::Table(probes));
    }
    doc.insert("core".into(), Value::Table(core_body));
    doc.insert("ctms".into(), Value::Table(ctms_table));
    if let Some(body) = misc_body {
        doc.insert("misc".into(), Value::Table(body));
    }
    Ok(doc)
}

/// Read the `acceptOwnership()` Call list written by
/// `AdminFunctions.ensureCtmsAndProxyAdminsOwnedByGovernanceWithWraps`
/// (in `<l1-contracts>/script-out/pre-governance-accept-ownerships.toml`):
/// one per CTM, and one per CTM ValidatorTimelock, whose `pendingOwner` is
/// governance after the prepare pre-step.
/// Returns an empty vector when the file doesn't exist (e.g. a prior regen
/// without this step) — the merge step then has nothing to prepend.
pub(super) fn read_pre_governance_accept_ownership_calls(
    contracts_path: &Path,
) -> anyhow::Result<Vec<crate::common::governance_calls::GovernanceCall>> {
    let path = contracts_path
        .join("script-out")
        .join("pre-governance-accept-ownerships.toml");
    if !path.exists() {
        return Ok(Vec::new());
    }
    let raw = fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
    let parsed: toml::Table =
        toml::from_str(&raw).with_context(|| format!("parse {}", path.display()))?;
    // foundry's `vm.serializeBytes(objectKey, valueKey, value)` + `vm.writeToml(_, path)`
    // emits `valueKey = "0x..."` at the root of the TOML — the `objectKey`
    // is just the serialization identifier, not a nested table. So the
    // file's top-level key is `calls`, not `pre_governance_accept_ownerships.calls`.
    let hex_str = parsed
        .get("calls")
        .and_then(|v| v.as_str())
        .with_context(|| format!("missing calls in {}", path.display()))?;
    crate::common::governance_calls::decode_calls(hex_str).with_context(|| {
        format!(
            "decode pre_governance_accept_ownerships.calls from {}",
            path.display()
        )
    })
}
