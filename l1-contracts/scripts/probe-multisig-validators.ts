#!/usr/bin/env ts-node
/**
 * For a given environment (stage / testnet / mainnet), enumerate every chain
 * registered on the bridgehub, list the addresses currently holding any
 * `ValidatorTimelock` role for that chain, and classify each address as:
 *
 *   - EOA  (no code)
 *   - contract (has code)
 *
 * For each contract validator we also print best-effort introspection so
 * the operator can decide who would need to sign a future MultisigValidator
 * impl swap:
 *
 *   - `owner()` (if callable)
 *   - EIP-1967 admin slot (proxy admin, if it's a TUPP)
 *   - `getName()` / contract version, when the contract exposes them
 *
 * Usage:
 *   ts-node scripts/probe-multisig-validators.ts --env stage   --rpc <sepolia>
 *   ts-node scripts/probe-multisig-validators.ts --env testnet --rpc <sepolia>
 *   ts-node scripts/probe-multisig-validators.ts --env mainnet --rpc <mainnet>
 *
 * Scope (intentional): only probes the current ValidatorTimelock proxy and the
 * v29+ AccessControlEnumerable-per-chain interface. Chains still on a pre-v29
 * ValidatorTimelock (no per-chain role enumeration) are reported as such and
 * skipped — those need an event-scan probe instead.
 */

import { ethers } from "ethers";
import { Command } from "commander";

import { getBridgehubAddress } from "./upgrade-script-utils";

const BRIDGEHUB_ABI = [
  "function getAllZKChainChainIDs() view returns (uint256[])",
  "function getZKChain(uint256) view returns (address)",
  "function chainTypeManager(uint256) view returns (address)",
];

const CTM_ABI = [
  "function validatorTimelock() view returns (address)",
  "function validatorTimelockPostV29() view returns (address)",
];

// AccessControlEnumerablePerChainAddressUpgradeable surface added in v29
// ValidatorTimelock. Pre-v29 instances revert on both calls.
const VALIDATOR_TIMELOCK_ABI = [
  "function getRoleMemberCount(address chainAddress, bytes32 role) view returns (uint256)",
  "function getRoleMember(address chainAddress, bytes32 role, uint256 index) view returns (address)",
  "function executionDelay() view returns (uint32)",
  "function owner() view returns (address)",
];

const CONTRACT_INTROSPECTION_ABI = [
  "function owner() view returns (address)",
  "function getName() view returns (string)",
  // EraMultisigValidator-only — plain ValidatorTimelock doesn't expose these.
  "function threshold() view returns (uint256)",
];

const ROLES: Record<string, string> = {
  PRECOMMITTER_ROLE: ethers.utils.id("PRECOMMITTER_ROLE"),
  COMMITTER_ROLE: ethers.utils.id("COMMITTER_ROLE"),
  REVERTER_ROLE: ethers.utils.id("REVERTER_ROLE"),
  PROVER_ROLE: ethers.utils.id("PROVER_ROLE"),
  EXECUTOR_ROLE: ethers.utils.id("EXECUTOR_ROLE"),
  UPGRADER_ROLE: ethers.utils.id("UPGRADER_ROLE"),
};

// EIP-1967 admin slot: keccak256("eip1967.proxy.admin") - 1
const EIP1967_ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";

type ValidatorInfo = {
  address: string;
  isContract: boolean;
  roles: string[];
  owner: string | null;
  proxyAdmin: string | null;
  getName: string | null;
  /// Non-null when the contract exposes `threshold()` (`EraMultisigValidator` etc.).
  /// `getName()` is "ValidatorTimelock" on both — `threshold()` is the actual discriminator.
  multisigThreshold: string | null;
};

type ChainReport = {
  chainId: string;
  diamond: string;
  ctm: string;
  validatorTimelock: string | null;
  validatorTimelockPostV29: string | null;
  validators: ValidatorInfo[];
  note: string | null;
};

async function getCodeOrNull(provider: ethers.providers.Provider, addr: string): Promise<string | null> {
  if (addr === ethers.constants.AddressZero) return null;
  const code = await provider.getCode(addr);
  return code === "0x" ? null : code;
}

async function safeCall<T>(p: Promise<T>): Promise<T | null> {
  try {
    return await p;
  } catch {
    return null;
  }
}

async function probeValidatorAddress(
  provider: ethers.providers.Provider,
  addr: string
): Promise<Pick<ValidatorInfo, "isContract" | "owner" | "proxyAdmin" | "getName">> {
  const code = await getCodeOrNull(provider, addr);
  if (!code) {
    return { isContract: false, owner: null, proxyAdmin: null, getName: null };
  }
  const c = new ethers.Contract(addr, CONTRACT_INTROSPECTION_ABI, provider);
  const owner = (await safeCall<unknown>(c.owner())) as string | null;
  const adminSlotValue = await provider.getStorageAt(addr, EIP1967_ADMIN_SLOT);
  const proxyAdmin =
    adminSlotValue === ethers.constants.HashZero
      ? null
      : ethers.utils.getAddress("0x" + adminSlotValue.slice(-40));
  const getName = (await safeCall<unknown>(c.getName())) as string | null;
  return { isContract: true, owner, proxyAdmin, getName };
}

async function enumerateValidators(
  provider: ethers.providers.Provider,
  vt: string,
  diamond: string
): Promise<{ map: Map<string, Set<string>>; supported: boolean }> {
  const map = new Map<string, Set<string>>();
  const c = new ethers.Contract(vt, VALIDATOR_TIMELOCK_ABI, provider);
  let supported = true;
  for (const [roleName, roleHash] of Object.entries(ROLES)) {
    let count: ethers.BigNumber | null;
    try {
      count = await c.getRoleMemberCount(diamond, roleHash);
    } catch {
      supported = false;
      return { map, supported };
    }
    const n = (count ?? ethers.constants.Zero).toNumber();
    for (let i = 0; i < n; i++) {
      const member = await c.getRoleMember(diamond, roleHash, i);
      const key = ethers.utils.getAddress(member);
      const set = map.get(key) ?? new Set();
      set.add(roleName);
      map.set(key, set);
    }
  }
  return { map, supported };
}

async function probeChain(
  provider: ethers.providers.Provider,
  bridgehub: ethers.Contract,
  chainId: ethers.BigNumber
): Promise<ChainReport> {
  const diamond = await bridgehub.getZKChain(chainId);
  const ctmAddr = await bridgehub.chainTypeManager(chainId);
  const report: ChainReport = {
    chainId: chainId.toString(),
    diamond,
    ctm: ctmAddr,
    validatorTimelock: null,
    validatorTimelockPostV29: null,
    validators: [],
    note: null,
  };
  if (ctmAddr === ethers.constants.AddressZero || diamond === ethers.constants.AddressZero) {
    report.note = "no CTM or diamond registered";
    return report;
  }
  const ctm = new ethers.Contract(ctmAddr, CTM_ABI, provider);
  const vtLegacy = (await safeCall<unknown>(ctm.validatorTimelock())) as string | null;
  const vtPostV29 = (await safeCall<unknown>(ctm.validatorTimelockPostV29())) as string | null;
  report.validatorTimelock = vtLegacy;
  report.validatorTimelockPostV29 = vtPostV29;

  // Prefer the post-v29 timelock (covers ZKsyncOS chains); fall back to legacy.
  const vt = vtPostV29 && vtPostV29 !== ethers.constants.AddressZero ? vtPostV29 : vtLegacy;
  if (!vt || vt === ethers.constants.AddressZero) {
    report.note = "no validator timelock resolved";
    return report;
  }

  const { map, supported } = await enumerateValidators(provider, vt, diamond);
  if (!supported) {
    report.note = "pre-v29 validator timelock (no role enumeration); use event scan to probe";
    return report;
  }

  for (const [addr, roleSet] of map.entries()) {
    const introspect = await probeValidatorAddress(provider, addr);
    report.validators.push({ address: addr, roles: Array.from(roleSet).sort(), ...introspect });
  }
  return report;
}

function fmtAddr(a: string | null): string {
  return a && a !== ethers.constants.AddressZero ? a : "—";
}

function printReport(env: string, reports: ChainReport[]): void {
  console.log(`\n=== ${env.toUpperCase()} — ${reports.length} chains ===`);
  let contractValidatorChains = 0;
  for (const r of reports) {
    const hasContractValidator = r.validators.some((v) => v.isContract);
    if (hasContractValidator) contractValidatorChains += 1;
    const tag = hasContractValidator ? "★" : " ";
    console.log(
      `${tag} chain ${r.chainId.padStart(10)}  diamond=${fmtAddr(r.diamond)}  vt=${fmtAddr(
        r.validatorTimelockPostV29 ?? r.validatorTimelock
      )}${r.note ? "  [" + r.note + "]" : ""}`
    );
    for (const v of r.validators) {
      const kind = v.isContract ? "contract" : "EOA";
      console.log(
        `      ${kind.padEnd(8)} ${v.address}  roles=${v.roles.join(",")}` +
          (v.isContract
            ? `\n         owner=${fmtAddr(v.owner)}  proxyAdmin=${fmtAddr(v.proxyAdmin)}` +
              (v.getName ? `  name=${v.getName}` : "")
            : "")
      );
    }
  }
  console.log(`\nChains with at least one contract-validator: ${contractValidatorChains}/${reports.length}`);
}

async function main(): Promise<void> {
  const program = new Command();
  program
    .requiredOption("--env <name>", "stage|testnet|mainnet")
    .requiredOption("--rpc <url>", "L1 RPC URL");
  program.parse(process.argv);
  const { env, rpc } = program.opts<{ env: string; rpc: string }>();

  const provider = new ethers.providers.JsonRpcProvider(rpc);
  const bridgehubAddr = getBridgehubAddress(env);
  const bridgehub = new ethers.Contract(bridgehubAddr, BRIDGEHUB_ABI, provider);
  const chainIds = (await bridgehub.getAllZKChainChainIDs()) as ethers.BigNumber[];
  console.log(`Bridgehub: ${bridgehubAddr}  chains: ${chainIds.length}`);

  const reports: ChainReport[] = [];
  for (const id of chainIds) {
    process.stdout.write(`  probing chain ${id.toString()}...`);
    try {
      reports.push(await probeChain(provider, bridgehub, id));
      process.stdout.write(" ok\n");
    } catch (e) {
      process.stdout.write(` failed: ${(e as Error).message}\n`);
      reports.push({
        chainId: id.toString(),
        diamond: "?",
        ctm: "?",
        validatorTimelock: null,
        validatorTimelockPostV29: null,
        validators: [],
        note: `probe failed: ${(e as Error).message}`,
      });
    }
  }
  printReport(env, reports);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
