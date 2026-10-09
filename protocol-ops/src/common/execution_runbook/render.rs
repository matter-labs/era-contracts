//! The Markdown page. Written in the exact layout prettier gives it (aligned tables, one blank
//! line between blocks), so `prettier --check` accepts a freshly generated file.

use std::collections::BTreeSet;

use alloy::primitives::{keccak256, Address, U256};

use super::decode::{self, InnerCall, WrapperKind, INLINE_CALLDATA_MAX_BYTES};
use super::load::network_name;
use super::{Runbook, RunbookTx, SourceKind};

/// Wrapped calls listed inline in a sentence; more become a numbered list.
const MAX_INLINE_CALLS: usize = 4;
/// Prettier's minimum width of a table column (the `---` of the delimiter row).
const MIN_COLUMN_WIDTH: usize = 3;

/// A run of consecutive txs from one sender: `txs[start..end]`.
struct Section {
    from: Address,
    start: usize,
    end: usize,
}

fn sections(txs: &[RunbookTx]) -> Vec<Section> {
    let mut sections: Vec<Section> = Vec::new();
    for (i, tx) in txs.iter().enumerate() {
        match sections.last_mut() {
            Some(section) if section.from == tx.from => section.end = i + 1,
            _ => sections.push(Section {
                from: tx.from,
                start: i,
                end: i + 1,
            }),
        }
    }
    sections
}

/// `tx 3` or `txs 1 to 12`, from 0-based `start..end`.
fn tx_range(start: usize, end: usize) -> String {
    if end - start == 1 {
        format!("tx {end}")
    } else {
        format!("txs {} to {end}", start + 1)
    }
}

fn code(text: impl AsRef<str>) -> String {
    format!("`{}`", text.as_ref())
}

fn address(address: Address) -> String {
    code(address.to_checksum(None))
}

/// `1,234`.
fn thousands(n: usize) -> String {
    let digits = n.to_string();
    let mut out = String::new();
    for (i, digit) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

fn is_long(tx: &RunbookTx) -> bool {
    tx.data.len() > INLINE_CALLDATA_MAX_BYTES
}

impl Runbook {
    fn emergency(&self) -> Option<(Address, Address, Address)> {
        match self.source {
            SourceKind::EmergencyBoard {
                board,
                handler,
                owner,
            } => Some((board, handler, owner)),
            _ => None,
        }
    }

    fn is_owner(&self, sender: Address) -> bool {
        self.emergency()
            .is_some_and(|(_, _, owner)| owner == sender)
    }

    fn is_eoa(&self, sender: Address) -> bool {
        self.facts
            .as_ref()
            .is_some_and(|facts| facts.eoa_senders.contains(&sender))
    }

    /// `` `0x…` `` plus the input's name for it, if any.
    fn named(&self, target: Address) -> String {
        match self.names.get(&target) {
            Some(name) => format!("{} ({name})", address(target)),
            None => address(target),
        }
    }

    /// A sender as the Senders bullet and section headings show it.
    fn sender(&self, sender: Address) -> String {
        let role = if self.is_owner(sender) {
            let env = self
                .env
                .as_deref()
                .map(|env| format!("{env} "))
                .unwrap_or_default();
            let eoa = if self.is_eoa(sender) { " EOA" } else { "" };
            format!("the {env}owner{eoa} ")
        } else if self.is_eoa(sender) {
            "the EOA ".to_string()
        } else {
            String::new()
        };
        match self.names.get(&sender) {
            Some(name) => format!("{role}{} ({name})", address(sender)),
            None => format!("{role}{}", address(sender)),
        }
    }

    /// Where a wrapped call goes: `Era CTM `0x…`` or `` `0x…` ``.
    fn call_target(&self, target: Address) -> String {
        match self.names.get(&target) {
            Some(name) => format!("{name} {}", address(target)),
            None => address(target),
        }
    }

    fn inner_call(&self, call: &InnerCall) -> String {
        let mut text = decode::call_display(&call.data);
        if let Some(note) = decode::annotation(&call.data) {
            text.push_str(&format!(" ({note})"));
        }
        text.push_str(&format!(" on {}", self.call_target(call.target)));
        if !call.value.is_zero() {
            text.push_str(&format!(" with value {} wei", call.value));
        }
        text
    }
}

/// `**<lead>:** a, b.` or `**<lead>** (N calls):` plus a numbered list.
fn calls_bullet(runbook: &Runbook, lead: &str, calls: &[InnerCall]) -> String {
    if calls.is_empty() {
        return format!("- **{lead}:** no calls.");
    }
    if calls.len() <= MAX_INLINE_CALLS {
        let list: Vec<String> = calls.iter().map(|call| runbook.inner_call(call)).collect();
        return format!("- **{lead}:** {}.", list.join(", "));
    }
    let mut bullet = format!("- **{lead}** ({} calls):", calls.len());
    for (i, call) in calls.iter().enumerate() {
        bullet.push_str(&format!("\n  {}. {}", i + 1, runbook.inner_call(call)));
    }
    bullet
}

fn sender_bullet(runbook: &Runbook, sections: &[Section]) -> String {
    let count = runbook.txs.len();
    if let [only] = sections {
        let lead = if count == 1 {
            "Sender".to_string()
        } else {
            format!("Sender for all {count} txs")
        };
        let mut bullet = format!("- **{lead}:** {}.", runbook.sender(only.from));
        if runbook.is_owner(only.from) {
            let approvals = count - 1;
            bullet.push_str(&format!(
                " It owns the {approvals} member Safes of the Emergency Upgrade Board."
            ));
        }
        return bullet;
    }
    let senders: BTreeSet<Address> = sections.iter().map(|section| section.from).collect();
    let runs: Vec<String> = sections
        .iter()
        .map(|section| {
            format!(
                "{} from {}",
                tx_range(section.start, section.end),
                runbook.sender(section.from)
            )
        })
        .collect();
    format!(
        "- **Senders ({} accounts; switch accounts between sections):** {}.",
        senders.len(),
        runs.join("; ")
    )
}

fn order_bullet(runbook: &Runbook) -> String {
    let count = runbook.txs.len();
    match runbook.emergency() {
        Some(_) if count > 1 => format!(
            "- **Order:** {} approve the proposal hash on each member Safe; tx {count} executes the \
             upgrade on the Emergency Upgrade Board. Wait for each tx to be mined before sending \
             the next; tx {count} reverts if any approval is missing.",
            tx_range(0, count - 1)
        ),
        _ => "- **Order:** send the txs in the order listed. Wait for each tx to be mined before \
              sending the next."
            .to_string(),
    }
}

/// One bullet per wrapper tx: what it runs, and how it depends on an earlier schedule.
fn what_bullets(runbook: &Runbook) -> Vec<String> {
    let mut bullets = Vec::new();
    // (tx number, target, operation, delay annotation) of each scheduleTransparent so far.
    let mut scheduled: Vec<(usize, Address, alloy::dyn_abi::DynSolValue, Option<String>)> =
        Vec::new();
    for (i, tx) in runbook.txs.iter().enumerate() {
        let number = i + 1;
        let Some(wrapped) = decode::wrapped(&tx.data) else {
            continue;
        };
        match wrapped.kind {
            WrapperKind::Schedule => {
                bullets.push(calls_bullet(
                    runbook,
                    &format!("What tx {number} schedules"),
                    &wrapped.calls,
                ));
                if let Some(operation) = wrapped.operation {
                    scheduled.push((number, tx.to, operation, decode::annotation(&tx.data)));
                }
            }
            WrapperKind::Atomic | WrapperKind::NonAtomic => {
                let schedule = wrapped.operation.as_ref().and_then(|operation| {
                    scheduled.iter().rev().find(|(_, target, scheduled_op, _)| {
                        *target == tx.to && scheduled_op == operation
                    })
                });
                if let Some((scheduled_at, _, _, delay)) = schedule {
                    let wait = match delay.as_deref() {
                        Some(delay) if delay != "delay 0 s" => {
                            format!(" and its {delay} has passed")
                        }
                        _ => String::new(),
                    };
                    bullets.push(format!(
                        "- **What tx {number} does:** executes, atomically, the operation tx \
                         {scheduled_at} schedules; it reverts unless tx {scheduled_at} is mined \
                         first{wait}."
                    ));
                } else if wrapped.kind == WrapperKind::Atomic {
                    bullets.push(calls_bullet(
                        runbook,
                        &format!("What tx {number} does, atomically"),
                        &wrapped.calls,
                    ));
                } else {
                    bullets.push(calls_bullet(
                        runbook,
                        &format!("What tx {number} does (a failing call does not revert it)"),
                        &wrapped.calls,
                    ));
                }
            }
        }
    }
    bullets
}

fn facts_bullet(runbook: &Runbook) -> Option<String> {
    let facts = runbook.facts.as_ref()?;
    let first_tx = |sender: Address| {
        runbook
            .txs
            .iter()
            .position(|tx| tx.from == sender)
            .map(|i| i + 1)
            .unwrap_or_default()
    };
    let nonces = match facts.nonces.as_slice() {
        [(sender, nonce)] => {
            let role = if runbook.is_owner(*sender) {
                "owner"
            } else {
                "sender"
            };
            format!("{role} nonce {nonce} before tx {}", first_tx(*sender))
        }
        many => {
            let list: Vec<String> = many
                .iter()
                .map(|(sender, nonce)| {
                    format!("{} {nonce} (tx {})", address(*sender), first_tx(*sender))
                })
                .collect();
            format!("sender nonces before their first tx: {}", list.join(", "))
        }
    };
    let after = facts
        .replayed_after
        .as_deref()
        .map(|what| format!(", after {what}"))
        .unwrap_or_default();
    let outcome = match runbook.txs.len() {
        1 => "the tx succeeds".to_string(),
        count => format!("all {count} txs succeed"),
    };
    Some(format!(
        "- **Checked on {}:** {nonces}; {outcome} on a {} fork at block {}{after}.",
        facts.date,
        network_name(runbook.chain_id),
        facts.fork_block
    ))
}

fn has_value(runbook: &Runbook) -> bool {
    runbook.txs.iter().any(|tx| !tx.value.is_zero())
}

fn metamask_bullet(runbook: &Runbook) -> String {
    let amount = if has_value(runbook) {
        "amount = the Value column (0 where it says 0)"
    } else {
        "amount 0"
    };
    format!(
        "- **Sending by hand in MetaMask:** Send, recipient = the `to` address, {amount}, and \
         paste the data into the hex data field (enable it under Settings > Advanced > Show hex \
         data)."
    )
}

fn value_cell(value: U256) -> String {
    if value.is_zero() {
        "0".to_string()
    } else {
        format!("{value} wei")
    }
}

fn cell(text: &str) -> String {
    text.replace(['\n', '\r'], " ").replace('|', "\\|")
}

fn table_rows(runbook: &Runbook, section: &Section) -> Vec<Vec<String>> {
    let with_value = has_value(runbook);
    let emergency = runbook.emergency().is_some();
    runbook.txs[section.start..section.end]
        .iter()
        .enumerate()
        .map(|(offset, tx)| {
            let number = section.start + offset + 1;
            let mut to = runbook.named(tx.to);
            if emergency && !runbook.names.contains_key(&tx.to) && number < runbook.txs.len() {
                to.push_str(" (member Safe)");
            }
            let mut call = decode::call_display(&tx.data);
            if let Some(note) = decode::annotation(&tx.data) {
                call.push_str(&format!(" ({note})"));
            }
            let data = if is_long(tx) {
                format!(
                    "{} bytes, keccak {}; full hex below",
                    thousands(tx.data.len()),
                    code(format!("{:#x}", keccak256(&tx.data)))
                )
            } else {
                code(format!("{:#x}", tx.data))
            };
            let mut row = vec![number.to_string(), cell(&tx.label), to, call];
            if with_value {
                row.push(value_cell(tx.value));
            }
            row.push(data);
            row
        })
        .collect()
}

/// A table exactly as prettier aligns it.
fn table(header: &[&str], rows: &[Vec<String>]) -> String {
    let width = |text: &str| text.chars().count();
    let widths: Vec<usize> = header
        .iter()
        .enumerate()
        .map(|(column, title)| {
            rows.iter()
                .map(|row| width(&row[column]))
                .chain([width(title), MIN_COLUMN_WIDTH])
                .max()
                .unwrap_or(MIN_COLUMN_WIDTH)
        })
        .collect();
    let line = |cells: Vec<String>| {
        let padded: Vec<String> = cells
            .iter()
            .zip(&widths)
            .map(|(text, w)| format!("{text}{}", " ".repeat(w - width(text))))
            .collect();
        format!("| {} |", padded.join(" | "))
    };
    let mut lines = vec![
        line(header.iter().map(|title| title.to_string()).collect()),
        line(widths.iter().map(|w| "-".repeat(*w)).collect()),
    ];
    lines.extend(rows.iter().map(|row| line(row.clone())));
    lines.join("\n")
}

fn safe_files_line(runbook: &Runbook, section: &Section) -> Option<String> {
    let mut files: Vec<&str> = Vec::new();
    for tx in &runbook.txs[section.start..section.end] {
        if let Some(file) = tx.safe_file.as_deref() {
            if !files.contains(&file) {
                files.push(file);
            }
        }
    }
    if files.is_empty() {
        return None;
    }
    let links: Vec<String> = files
        .iter()
        .map(|link| {
            let name = link.rsplit('/').next().unwrap_or(link);
            format!("[{}]({link})", code(name))
        })
        .collect();
    let noun = if links.len() == 1 { "file" } else { "files" };
    Some(format!(
        "Safe Transaction Builder {noun} for these txs: {}.",
        links.join(", ")
    ))
}

/// Named addresses the txs reference (targets and wrapped-call targets), in order of appearance;
/// the board and handler first for an emergency list.
fn addresses_line(runbook: &Runbook) -> Option<String> {
    let mut ordered: Vec<Address> = Vec::new();
    if let Some((board, handler, _)) = runbook.emergency() {
        ordered.extend([board, handler]);
    }
    for tx in &runbook.txs {
        let inner = decode::wrapped(&tx.data)
            .map(|wrapped| wrapped.calls)
            .unwrap_or_default();
        for target in std::iter::once(tx.to).chain(inner.iter().map(|call| call.target)) {
            if runbook.names.contains_key(&target) && !ordered.contains(&target) {
                ordered.push(target);
            }
        }
    }
    let listed: Vec<String> = ordered
        .iter()
        .filter_map(|target| {
            runbook
                .names
                .get(target)
                .map(|name| format!("{name} {}", address(*target)))
        })
        .collect();
    (!listed.is_empty()).then(|| format!("Addresses: {}.", listed.join(", ")))
}

fn details_block(number: usize, tx: &RunbookTx) -> String {
    format!(
        "<details>\n<summary>Tx {number} calldata ({} bytes)</summary>\n\n```text\n{:#x}\n```\n\n</details>",
        thousands(tx.data.len()),
        tx.data
    )
}

/// The whole page.
pub fn render(runbook: &Runbook) -> String {
    let sections = sections(&runbook.txs);
    let mut blocks: Vec<String> = vec![format!("# {}", runbook.title)];

    let link_text = runbook.source_link.trim_start_matches("./");
    let whose = match runbook.source {
        SourceKind::SafeBundles => " and the Safe Transaction Builder files it lists, which are",
        _ if runbook.source_in_same_dir => " in this directory, which is",
        _ => ", which is",
    };
    blocks.push(format!(
        "Generated by `protocol_ops dev execution-runbook` from [{}]({}){whose} the source of \
         truth. Network: {} (chain id {}).",
        code(link_text),
        runbook.source_link,
        network_name(runbook.chain_id),
        runbook.chain_id
    ));

    let mut bullets = vec![sender_bullet(runbook, &sections)];
    if runbook.txs.len() > 1 {
        bullets.push(order_bullet(runbook));
    }
    bullets.extend(what_bullets(runbook));
    for (i, tx) in runbook.txs.iter().enumerate() {
        if let Some(seconds) = tx.time_increase {
            bullets.push(format!(
                "- **Before tx {}:** the simulator advances time by {seconds} s here; on a real \
                 chain, send it only once the deadline it checks has passed.",
                i + 1
            ));
        }
    }
    bullets.extend(
        runbook
            .notes
            .iter()
            .map(|note| format!("- **Note:** {note}")),
    );
    bullets.extend(facts_bullet(runbook));
    bullets.push(metamask_bullet(runbook));
    if runbook.source == SourceKind::SafeBundles {
        bullets.push(
            "- **Sending from a Safe instead:** load the Safe Transaction Builder file named \
             above the txs in the Safe app; it holds the same txs."
                .to_string(),
        );
    }
    blocks.push(bullets.join("\n"));

    let mut header = vec!["#", "Label", "To", "Call"];
    if has_value(runbook) {
        header.push("Value");
    }
    header.push("Data");
    let multiple = sections.len() > 1;
    for section in &sections {
        if multiple {
            blocks.push(format!(
                "## {}: send from {}",
                capitalized(&tx_range(section.start, section.end)),
                runbook.sender(section.from)
            ));
        }
        blocks.extend(safe_files_line(runbook, section));
        blocks.push(table(&header, &table_rows(runbook, section)));
    }

    blocks.extend(addresses_line(runbook));
    for (i, tx) in runbook.txs.iter().enumerate() {
        if is_long(tx) {
            blocks.push(details_block(i + 1, tx));
        }
    }
    blocks.join("\n\n") + "\n"
}

fn capitalized(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}
