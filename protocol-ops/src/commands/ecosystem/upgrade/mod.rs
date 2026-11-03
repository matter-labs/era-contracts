//! Ecosystem-level upgrade flow.
//!
//! Two top-level commands:
//!
//!   `upgrade-prepare-all` deploys new ecosystem contracts (deployer EOA signs)
//!                         by running the release's `CoreUpgrade_v<N>` once + `CTMUpgrade_v<N>`
//!                         once for the target `--ctm-proxy` on a single anvil fork, then
//!                         executes the CTM-admin calls the CTM prepare emits (the
//!                         registry bootstrap's ServerNotifier handover; none on a
//!                         recurring upgrade). Emits per-script governance TOMLs.
//!   `upgrade-governance`  replays the package's one governance bundle
//!                         (`[governance_calls] calls`) on an anvil fork, holds a
//!                         registry package's fork state against what it must
//!                         leave, and emits one Safe bundle (governance owner
//!                         signs). Accepts multiple `--governance-toml` args and
//!                         replays their bundles in the order given.

mod governance;
mod list_ctms;
mod merge;
mod prepare;

pub use governance::*;
pub use list_ctms::*;
pub use merge::*;
pub use prepare::*;

#[cfg(test)]
mod release_script_tests;
#[cfg(test)]
mod tests;
