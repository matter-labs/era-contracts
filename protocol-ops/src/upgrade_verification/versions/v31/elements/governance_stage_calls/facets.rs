//! Diamond-cut + facet-set decomposition (Stage 1 only).
//!
//! Used by two Stage 1 decoders:
//! - `setNewVersionUpgrade.diamondCut.facetCuts` — the upgrade-side cut
//!   (Remove the current chain's facets, then Add the v31 facets).
//! - `setChainCreationParams.diamondCut.facetCuts` — the chain-creation cut
//!   (all-Add, no Remove half).
//!
//! Both verifiers independently reconstruct the expected `FacetCutSet` from
//! the artifact (pulling each facet's bytecode from L1 and deriving
//! selectors via `evmole`), then compare against the proposed cut. This
//! prevents the artifact's `diamond_cut_data` blob from acting as a
//! self-referential source of truth.

use alloy::{
    primitives::{Address, U256},
    providers::Provider,
    sol_types::SolCall,
};
use anyhow::Context;
use std::collections::HashSet;

use crate::upgrade_verification::{
    artifacts::{CtmArtifact, CtmFlavor},
    verifiers::{VerificationResult, Verifiers},
};

use super::super::super::utils::facet_cut_set::{self, FacetCutSet, FacetInfo};
use super::super::set_new_version_upgrade;
use super::helpers::{protocol_label, required_ctm_address};
use super::{Action, FacetCut, GettersFacet};

/// Decodes the `DefaultUpgrade.upgrade(ProposedUpgrade)` payload sitting at
/// `setNewVersionUpgrade.diamondCut.initCalldata` and dispatches the deep
/// `ProposedUpgrade` verification.
pub(super) async fn verify_default_upgrade_payload(
    init_calldata: &[u8],
    expected_new_protocol_version: U256,
    expected_fixed_force_deployments_data: &str,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
    bytecodes_supplier_addr: Option<Address>,
    ctm_flavor: CtmFlavor,
) -> anyhow::Result<usize> {
    let upgrade = set_new_version_upgrade::upgradeCall::abi_decode(init_calldata)
        .context("decoding DefaultUpgrade.upgrade calldata")?;
    upgrade
        ._proposedUpgrade
        .verify_v31_template(
            verifiers,
            result,
            expected_new_protocol_version,
            expected_fixed_force_deployments_data,
            bytecodes_supplier_addr,
            ctm_flavor,
        )
        .await
}

/// Upgrade-side facet-cut decomposition. Compares the proposed
/// `(Remove* …, Add* …)` against an exact reconstruction of what the
/// representative chain currently has, plus the expected v31 added facets.
pub(super) async fn verify_v31_upgrade_facet_cuts(
    facet_cuts: &[set_new_version_upgrade::FacetCut],
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> anyhow::Result<usize> {
    let initial_error_count = result.errors;
    let proposed_facet_cuts = proposed_upgrade_facet_cut_set(facet_cuts, result);

    match expected_v31_upgrade_facet_cuts(ctm, verifiers, result).await? {
        Some(ExpectedFacetCuts::Exact {
            facets: expected_facet_cuts,
            chain_id,
        }) if proposed_facet_cuts == expected_facet_cuts => {
            result.report_ok(&format!(
                "{} chain upgrade facet cuts match chain {} current diamond and new facets",
                ctm.flavor.label(),
                chain_id
            ));
        }
        Some(ExpectedFacetCuts::Exact {
            facets: expected_facet_cuts,
            chain_id,
        }) => {
            result.report_error(&format!(
                "Invalid {} chain upgrade facet cuts for representative chain {}. Expected: {:#?}\nReceived: {:#?}",
                ctm.flavor.label(),
                chain_id,
                expected_facet_cuts,
                proposed_facet_cuts
            ));
        }
        None if verifiers.representative_era_chain_id.is_none() => {
            result.report_warn(
                "Skipped exact chain upgrade facet-cut reconstruction; env era_chain_id was not loaded",
            );
        }
        None => {}
    }

    Ok((result.errors - initial_error_count) as usize)
}

fn proposed_upgrade_facet_cut_set(
    facet_cuts: &[set_new_version_upgrade::FacetCut],
    result: &mut VerificationResult,
) -> FacetCutSet {
    let mut used_add = false;
    let mut proposed_facet_cuts = FacetCutSet::new();
    for facet in facet_cuts {
        let action = match facet.action {
            set_new_version_upgrade::Action::Add => {
                used_add = true;
                facet_cut_set::Action::Add
            }
            set_new_version_upgrade::Action::Remove => {
                if used_add {
                    result.report_error(
                        "Remove action is unexpected after Add in upgrade diamond cut",
                    );
                }
                if facet.facet != Address::ZERO {
                    result.report_error(&format!(
                        "Remove action must use zero facet address, got {}",
                        facet.facet
                    ));
                }
                facet_cut_set::Action::Remove
            }
            set_new_version_upgrade::Action::Replace => {
                result.report_error("Replace action is unexpected in upgrade diamond cut");
                continue;
            }
            set_new_version_upgrade::Action::__Invalid => {
                result.report_error("Invalid action in upgrade diamond cut");
                continue;
            }
        };

        proposed_facet_cuts.add_facet(FacetInfo {
            facet: facet.facet,
            action,
            is_freezable: facet.isFreezable,
            selectors: facet.selectors.iter().map(|x| x.0).collect(),
        });
    }
    proposed_facet_cuts
}

enum ExpectedFacetCuts {
    Exact { facets: FacetCutSet, chain_id: U256 },
}

struct RepresentativeChainDiamond {
    chain_id: U256,
    diamond: Address,
}

async fn expected_v31_upgrade_facet_cuts(
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> anyhow::Result<Option<ExpectedFacetCuts>> {
    let added_facets = expected_v31_added_facets(ctm, verifiers, result).await?;
    let Some(representative) = find_representative_chain_diamond(ctm, verifiers, result).await?
    else {
        result.report_error(&format!(
            "Cannot reconstruct exact {} chain upgrade facet cuts: no registered chain on this CTM matches artifact old protocol {}",
            ctm.flavor.label(),
            protocol_label(U256::from(ctm.contracts_config.old_protocol_version))
        ));
        return Ok(None);
    };

    let current_facets = match GettersFacet::new(
        representative.diamond,
        verifiers.network_verifier.get_l1_provider(),
    )
    .facets()
    .call()
    .await
    {
        Ok(facets) => facets,
        Err(err) => {
            result.report_error(&format!(
                "Cannot fetch current diamond facets from {}: {err}",
                representative.diamond
            ));
            return Ok(None);
        }
    };

    let mut facets_to_remove = FacetCutSet::new();
    for facet in current_facets {
        facets_to_remove.add_facet(FacetInfo {
            facet: Address::ZERO,
            is_freezable: false,
            action: facet_cut_set::Action::Remove,
            selectors: facet.selectors.iter().map(|x| x.0).collect(),
        });
    }

    Ok(Some(ExpectedFacetCuts::Exact {
        facets: facets_to_remove.merge(added_facets),
        chain_id: representative.chain_id,
    }))
}

async fn find_representative_chain_diamond(
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> anyhow::Result<Option<RepresentativeChainDiamond>> {
    let Some(ctm_proxy) = required_ctm_address(
        ctm,
        &["state_transition", "chain_type_manager_proxy"],
        result,
    ) else {
        return Ok(None);
    };

    let expected_protocol = U256::from(ctm.contracts_config.old_protocol_version);

    if ctm.flavor == CtmFlavor::Era {
        if let Some(era_chain_id) = verifiers.representative_era_chain_id {
            let chain_id = U256::from(era_chain_id);
            if let Some(representative) = inspect_chain_for_facet_cut_reconstruction(
                chain_id,
                ctm_proxy,
                expected_protocol,
                verifiers,
            )
            .await?
            {
                return Ok(Some(representative));
            }
        }
    }

    let chain_ids = match verifiers
        .network_verifier
        .try_get_all_zk_chain_ids(verifiers.bridgehub_address)
        .await
    {
        Ok(ids) => ids,
        Err(err) => {
            result.report_warn(&format!(
                "Cannot scan registered chains for {} facet removal reconstruction: {err}",
                ctm.flavor.label()
            ));
            return Ok(None);
        }
    };

    for chain_id in chain_ids {
        if let Some(representative) = inspect_chain_for_facet_cut_reconstruction(
            chain_id,
            ctm_proxy,
            expected_protocol,
            verifiers,
        )
        .await?
        {
            return Ok(Some(representative));
        }
    }

    Ok(None)
}

async fn inspect_chain_for_facet_cut_reconstruction(
    chain_id: U256,
    expected_ctm: Address,
    expected_protocol: U256,
    verifiers: &Verifiers,
) -> anyhow::Result<Option<RepresentativeChainDiamond>> {
    let chain_ctm = match verifiers
        .network_verifier
        .try_get_chain_type_manager_from_bridgehub(verifiers.bridgehub_address, chain_id)
        .await
    {
        Ok(chain_ctm) => chain_ctm,
        Err(_) => return Ok(None),
    };
    if chain_ctm != expected_ctm {
        return Ok(None);
    }

    let diamond = match verifiers
        .network_verifier
        .try_get_chain_diamond_from_bridgehub(verifiers.bridgehub_address, chain_id)
        .await
    {
        Ok(diamond) if diamond != Address::ZERO => diamond,
        _ => return Ok(None),
    };

    let protocol = match verifiers
        .network_verifier
        .try_get_chain_protocol_version(diamond)
        .await
    {
        Ok(protocol) => protocol,
        Err(_) => return Ok(None),
    };
    if protocol != expected_protocol {
        return Ok(None);
    }

    Ok(Some(RepresentativeChainDiamond { chain_id, diamond }))
}

async fn expected_v31_added_facets(
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> anyhow::Result<FacetCutSet> {
    let mut facets_to_add = FacetCutSet::new();
    for (facet_name, is_freezable) in EXPECTED_V31_UPGRADE_FACETS {
        let Some(facet_address) =
            required_ctm_address(ctm, &["state_transition", facet_name], result)
        else {
            continue;
        };

        let bytecode = match verifiers
            .network_verifier
            .get_l1_provider()
            .get_code_at(facet_address)
            .await
        {
            Ok(bytecode) if !bytecode.is_empty() => bytecode,
            Ok(_) => {
                result.report_error(&format!(
                    "No bytecode at expected facet {} ({})",
                    facet_name, facet_address
                ));
                continue;
            }
            Err(err) => {
                result.report_error(&format!(
                    "Cannot fetch bytecode for expected facet {} ({}): {err}",
                    facet_name, facet_address
                ));
                continue;
            }
        };

        let selectors = facet_selectors_from_bytecode(&bytecode);
        if selectors.is_empty() {
            result.report_error(&format!(
                "Cannot derive selectors from expected facet {} ({})",
                facet_name, facet_address
            ));
            continue;
        }

        facets_to_add.add_facet(FacetInfo {
            facet: facet_address,
            action: facet_cut_set::Action::Add,
            is_freezable,
            selectors,
        });
    }

    Ok(facets_to_add)
}

const EXPECTED_V31_UPGRADE_FACETS: [(&str, bool); 6] = [
    ("admin_facet_addr", false),
    ("getters_facet_addr", false),
    ("mailbox_facet_addr", true),
    ("executor_facet_addr", true),
    ("migrator_facet_addr", false),
    ("committer_facet_addr", true),
];

/// Independently reconstructs the expected chain-creation facet set from the
/// v31 facet addresses in the artifact, decodes the proposed cut while
/// enforcing the all-Add invariant, and compares the two sets. This catches
/// drift in the artifact's `diamond_cut_data` blob itself — the blob hex
/// check in the caller only catches gov-call ↔ artifact drift.
///
/// The v31 chain-creation facet list matches the v31 upgrade facet list (the
/// same six facets, all Add), so `expected_v31_added_facets` is reused as-is.
pub(super) async fn verify_v31_chain_creation_facet_cuts(
    facet_cuts: &[FacetCut],
    ctm: &CtmArtifact,
    verifiers: &Verifiers,
    result: &mut VerificationResult,
) -> usize {
    let expected = match expected_v31_added_facets(ctm, verifiers, result).await {
        Ok(set) => set,
        Err(err) => {
            result.report_error(&format!(
                "{} chain creation facet cut decomposition: cannot build expected set: {err}",
                ctm.flavor.label()
            ));
            return 1;
        }
    };

    let mut proposed = FacetCutSet::new();
    let mut errors = 0;
    for facet in facet_cuts {
        let action = match facet.action {
            Action::Add => facet_cut_set::Action::Add,
            Action::Remove => {
                result.report_error(&format!(
                    "{} chain creation diamond cut: Remove action is unexpected",
                    ctm.flavor.label()
                ));
                errors += 1;
                continue;
            }
            Action::Replace => {
                result.report_error(&format!(
                    "{} chain creation diamond cut: Replace action is unexpected",
                    ctm.flavor.label()
                ));
                errors += 1;
                continue;
            }
            Action::__Invalid => {
                result.report_error(&format!(
                    "{} chain creation diamond cut: invalid action",
                    ctm.flavor.label()
                ));
                errors += 1;
                continue;
            }
        };
        proposed.add_facet(FacetInfo {
            facet: facet.facet,
            action,
            is_freezable: facet.isFreezable,
            selectors: facet.selectors.iter().map(|x| x.0).collect(),
        });
    }

    if expected != proposed {
        result.report_error(&format!(
            "{} chain creation facet cut mismatch.\nExpected: {:#?}\nReceived: {:#?}",
            ctm.flavor.label(),
            expected,
            proposed
        ));
        errors += 1;
    } else if errors == 0 {
        result.report_ok(&format!(
            "{} chain creation facet cut matches independent reconstruction (all Add)",
            ctm.flavor.label()
        ));
    }

    errors
}

fn facet_selectors_from_bytecode(bytecode: &[u8]) -> HashSet<[u8; 4]> {
    evmole::contract_info(evmole::ContractInfoArgs::new(bytecode).with_selectors())
        .functions
        .unwrap_or_default()
        .into_iter()
        .map(|function| function.selector)
        // Exclude getName(); this is included for tooling only and is not part of the diamond cut.
        .filter(|selector| selector != &[0x17, 0xd7, 0xde, 0x7c])
        .collect()
}
