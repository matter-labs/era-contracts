//! Sweeps every privileged role in the ecosystem and groups them by holder.
//!
//! Two shapes are worth calling out and are therefore modelled explicitly: a
//! `pendingOwner` that is still set means an `acceptOwnership` was started and
//! never finished, so the *previous* holder still has the role; and a role
//! held by an EOA means there is a private key where a contract was intended.

use std::collections::BTreeMap;

use alloy::primitives::Address;
use alloy::providers::Provider;
use alloy::rpc::types::Filter;
use alloy::sol_types::SolEvent;
use anyhow::Context;

use crate::common::ethereum::AlloyProvider;
use crate::deployment_verification::contracts::{
    IChainAdminView, IEcosystemEvents, IGovernanceView, IOwnableView,
};
use crate::deployment_verification::discovery::probe;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Role {
    Owner,
    PendingOwner,
    Admin,
    PendingAdmin,
    SecurityCouncil,
    TokenMultiplierSetter,
}

impl Role {
    pub fn label(self) -> &'static str {
        match self {
            Self::Owner => "owner",
            Self::PendingOwner => "pendingOwner",
            Self::Admin => "admin",
            Self::PendingAdmin => "pendingAdmin",
            Self::SecurityCouncil => "securityCouncil",
            Self::TokenMultiplierSetter => "tokenMultiplierSetter",
        }
    }

    /// A pending role that is still set means a two-step handoff stalled.
    pub fn is_pending(self) -> bool {
        matches!(self, Self::PendingOwner | Self::PendingAdmin)
    }
}

#[derive(Debug, Clone)]
pub struct RoleHolding {
    pub contract: String,
    pub contract_address: Address,
    pub role: Role,
    pub holder: Address,
}

#[derive(Default)]
pub struct RoleReport {
    pub holdings: Vec<RoleHolding>,
    /// Whether each holder address has code, so EOA-held roles stand out.
    pub holder_is_contract: BTreeMap<Address, bool>,
}

impl RoleReport {
    /// Roles grouped by holder, holders ordered by how many roles they hold.
    pub fn by_holder(&self) -> Vec<(Address, Vec<&RoleHolding>)> {
        let mut grouped: BTreeMap<Address, Vec<&RoleHolding>> = BTreeMap::new();
        for holding in &self.holdings {
            grouped.entry(holding.holder).or_default().push(holding);
        }
        let mut groups: Vec<_> = grouped.into_iter().collect();
        groups.sort_by_key(|(address, holdings)| (usize::MAX - holdings.len(), *address));
        groups
    }

    /// Handoffs that were started and never accepted, i.e. a pending role
    /// still pointing at somebody other than the current holder. A pending
    /// role equal to the live one is a self-transfer no-op, not a stalled
    /// handoff — `transferOwnership(currentOwner)` leaves it behind.
    pub fn stalled_handoffs(&self) -> Vec<&RoleHolding> {
        self.holdings
            .iter()
            .filter(|holding| holding.role.is_pending() && holding.holder != Address::ZERO)
            .filter(|holding| self.live_holder(holding) != Some(holding.holder))
            .collect()
    }

    /// Pending roles that point at the address already holding the live role.
    pub fn self_transfers(&self) -> Vec<&RoleHolding> {
        self.holdings
            .iter()
            .filter(|holding| holding.role.is_pending() && holding.holder != Address::ZERO)
            .filter(|holding| self.live_holder(holding) == Some(holding.holder))
            .collect()
    }

    /// The non-pending counterpart of a pending role on the same contract.
    fn live_holder(&self, pending: &RoleHolding) -> Option<Address> {
        let live = match pending.role {
            Role::PendingOwner => Role::Owner,
            Role::PendingAdmin => Role::Admin,
            _ => return None,
        };
        self.holdings
            .iter()
            .find(|holding| {
                holding.contract_address == pending.contract_address && holding.role == live
            })
            .map(|holding| holding.holder)
    }

    /// Records a role, ignoring a repeat of one already collected — the
    /// generic `Ownable` sweep and the Governance / ChainAdmin sweeps overlap.
    pub fn record(&mut self, holding: RoleHolding) {
        let duplicate = self.holdings.iter().any(|existing| {
            existing.contract_address == holding.contract_address && existing.role == holding.role
        });
        if !duplicate {
            self.holdings.push(holding);
        }
    }

    pub fn is_eoa(&self, address: &Address) -> bool {
        !self
            .holder_is_contract
            .get(address)
            .copied()
            .unwrap_or(true)
    }
}

/// Reads `owner()` / `pendingOwner()` from an `Ownable2Step`-shaped contract.
/// Contracts that expose neither are skipped — plenty of the ecosystem
/// (facets, verifiers, DA validators) is deliberately role-free.
pub async fn collect_ownable(
    provider: &AlloyProvider,
    report: &mut RoleReport,
    name: &str,
    address: Address,
) -> anyhow::Result<()> {
    let ownable = IOwnableView::new(address, provider);
    let Some(owner) = probe(ownable.owner().call().await, &format!("{name}.owner()")).await? else {
        return Ok(());
    };
    push(report, name, address, Role::Owner, owner);

    // Single-step `Ownable` (OpenZeppelin ProxyAdmin, UpgradeableBeacon) has
    // no pendingOwner, which is why this is a probe rather than a call.
    if let Some(pending) = probe(
        ownable.pendingOwner().call().await,
        &format!("{name}.pendingOwner()"),
    )
    .await?
    {
        push(report, name, address, Role::PendingOwner, pending);
    }
    Ok(())
}

/// Adds `admin` / `pendingAdmin` for the Bridgehub and the CTM. `pendingAdmin`
/// is private storage on both, so it comes from the last `NewPendingAdmin`
/// event rather than a getter — a cleared pending admin is exactly what
/// `acceptAdmin` emits.
pub async fn collect_admin(
    provider: &AlloyProvider,
    report: &mut RoleReport,
    name: &str,
    address: Address,
    admin: Address,
    from_block: u64,
) -> anyhow::Result<()> {
    push(report, name, address, Role::Admin, admin);

    let filter = Filter::new()
        .address(address)
        .event_signature(IEcosystemEvents::NewPendingAdmin::SIGNATURE_HASH)
        .from_block(from_block);
    let logs = provider
        .get_logs(&filter)
        .await
        .with_context(|| format!("eth_getLogs for {name} NewPendingAdmin"))?;
    let pending = match logs.last() {
        Some(log) => {
            IEcosystemEvents::NewPendingAdmin::decode_log_data(log.data())
                .with_context(|| format!("decoding {name} NewPendingAdmin"))?
                .newPendingAdmin
        }
        None => Address::ZERO,
    };
    push(report, name, address, Role::PendingAdmin, pending);
    Ok(())
}

pub async fn collect_governance(
    provider: &AlloyProvider,
    report: &mut RoleReport,
    address: Address,
) -> anyhow::Result<()> {
    collect_ownable(provider, report, "Governance", address).await?;
    if let Some(council) = probe(
        IGovernanceView::new(address, provider)
            .securityCouncil()
            .call()
            .await,
        "governance.securityCouncil()",
    )
    .await?
    {
        push(
            report,
            "Governance",
            address,
            Role::SecurityCouncil,
            council,
        );
    }
    Ok(())
}

pub async fn collect_chain_admin(
    provider: &AlloyProvider,
    report: &mut RoleReport,
    address: Address,
) -> anyhow::Result<()> {
    collect_ownable(provider, report, "ChainAdminOwnable", address).await?;
    if let Some(setter) = probe(
        IChainAdminView::new(address, provider)
            .tokenMultiplierSetter()
            .call()
            .await,
        "chainAdmin.tokenMultiplierSetter()",
    )
    .await?
    {
        push(
            report,
            "ChainAdminOwnable",
            address,
            Role::TokenMultiplierSetter,
            setter,
        );
    }
    Ok(())
}

/// Fills in `holder_is_contract` for every holder seen so far.
pub async fn classify_holders(
    provider: &AlloyProvider,
    report: &mut RoleReport,
) -> anyhow::Result<()> {
    let holders: Vec<Address> = report
        .holdings
        .iter()
        .map(|holding| holding.holder)
        .filter(|holder| *holder != Address::ZERO)
        .collect();
    for holder in holders {
        if report.holder_is_contract.contains_key(&holder) {
            continue;
        }
        let code = provider
            .get_code_at(holder)
            .await
            .with_context(|| format!("eth_getCode({holder})"))?;
        report.holder_is_contract.insert(holder, !code.is_empty());
    }
    Ok(())
}

fn push(report: &mut RoleReport, name: &str, address: Address, role: Role, holder: Address) {
    report.record(RoleHolding {
        contract: name.to_string(),
        contract_address: address,
        role,
        holder,
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn holding(contract: &str, role: Role, holder: u8) -> RoleHolding {
        RoleHolding {
            contract: contract.into(),
            contract_address: Address::ZERO,
            role,
            holder: Address::repeat_byte(holder),
        }
    }

    #[test]
    fn groups_by_holder_most_roles_first() {
        let report = RoleReport {
            holdings: vec![
                holding("A", Role::Owner, 1),
                holding("B", Role::Owner, 2),
                holding("C", Role::Owner, 2),
            ],
            ..Default::default()
        };
        let groups = report.by_holder();
        assert_eq!(groups[0].0, Address::repeat_byte(2));
        assert_eq!(groups[0].1.len(), 2);
    }

    #[test]
    fn a_cleared_pending_role_is_not_a_stalled_handoff() {
        let report = RoleReport {
            holdings: vec![
                RoleHolding {
                    contract: "A".into(),
                    contract_address: Address::ZERO,
                    role: Role::PendingOwner,
                    holder: Address::ZERO,
                },
                holding("B", Role::PendingOwner, 3),
            ],
            ..Default::default()
        };
        let stalled = report.stalled_handoffs();
        assert_eq!(stalled.len(), 1);
        assert_eq!(stalled[0].contract, "B");
    }
}
