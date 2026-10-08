#!/usr/bin/env bash
# Validates a fetched transaction file and turns the selected range into a plan.
#
#   resolve.sh --plan-dir DIR --environment stage|testnet [--range N|A-B]
#              [--rpc-url URL] [--simulation-only]
#
# Reads DIR/transactions.json and DIR/source.json (see fetch.sh). Two formats:
#   emergency-upgrade-board  {"owner", "emergency_upgrade_board", "transactions":
#                            [{"step", "label", "from", "to", "data"}], ...}
#                            (upgrade-envs/*/output/*/emergency-upgrade-board.json;
#                            value is always 0, the network is the environment's)
#   transaction-simulator    [{"description", "network", "from", "to", "value", "data", ...}]
#                            (value in ETH, as in matter-labs/transaction-simulator)
# Writes:
#   DIR/normalized.json   every entry of the file in one shape
#   DIR/plan.json         the selected transactions (value in wei)
#   DIR/plan.json.sha256  its sha256, carried to later jobs as a job output
#   DIR/summary.md        the table the approver sees
#
# Indices are 0-based and inclusive. A plan has exactly one sender, because a
# broadcast run holds one key; --simulation-only lifts that for fork simulation
# of a multi-sender file (execute.sh refuses to sign such a plan).

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

plan_dir="" environment="" range="" rpc="" simulation_only=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan-dir) plan_dir="$2"; shift 2 ;;
    --environment) environment="$2"; shift 2 ;;
    --range) range="$2"; shift 2 ;;
    --rpc-url) rpc="$2"; shift 2 ;;
    --simulation-only) simulation_only=true; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [ -z "$plan_dir" ] || [ -z "$environment" ]; then
  die "usage: resolve.sh --plan-dir DIR --environment ENV [--range N|A-B] [--rpc-url URL] [--simulation-only]"
fi

check_foundry
file="$plan_dir/transactions.json"
[ -f "$file" ] || die "$file not found (run fetch.sh first)"
[ -f "$plan_dir/source.json" ] || die "$plan_dir/source.json not found (run fetch.sh first)"

network="$(network_of_env "$environment")"
chain_id="$(chain_id_of_network "$network")"
rpc="${rpc:-$(rpc_of_network "$network")}"
# Outputs of an earlier run in the same directory must not outlive a failure.
rm -f "$plan_dir/normalized.json" "$plan_dir/plan.json" "$plan_dir/plan.json.sha256" "$plan_dir/summary.md"
require_chain_id "$rpc" "$chain_id"

# ---------------------------------------------------------------- format
format="$(jq -r '
  if type == "array" then "transaction-simulator"
  elif type == "object" and (.transactions | type) == "array" then "emergency-upgrade-board"
  else "unknown" end' "$file" 2>/dev/null)" || die "$file is not valid JSON"

# Unknown fields are an error on purpose: a new field may change what a
# transaction means, so the tool must be taught about it first.
case "$format" in
  transaction-simulator)
    shape_errors="$(jq -r '
      def allowed: ["description", "network", "from", "to", "value", "valueToMint", "data",
                    "tag", "testOnly", "emulateAllBatchesExecuted", "timeIncrease"];
      if length == 0 then "the file has no transactions" else
      to_entries[] | .key as $i | .value as $t |
      if ($t | type) != "object" then "tx \($i): not a JSON object"
      else
        ((($t | keys) - allowed) | select(length > 0) | "tx \($i): unknown field(s): \(join(", "))"),
        (["network", "from", "to", "value", "data"][] as $k
          | select(($t[$k] | type) != "string") | "tx \($i): \($k) must be a string"),
        (select(($t.description // "" | type) != "string") | "tx \($i): description must be a string")
      end end' "$file")"
    [ -z "$shape_errors" ] || die "malformed transaction file:
$shape_errors"
    jq '[.[] | {description: (.description // ""), network, from, to, value, data,
               testOnly, emulateAllBatchesExecuted, timeIncrease}]' "$file" >"$plan_dir/normalized.json"
    ;;
  emergency-upgrade-board)
    shape_errors="$(jq -r '
      def top: ["_comment", "emergency_upgrade_board", "protocol_upgrade_handler", "owner", "transactions"];
      def allowed: ["step", "label", "from", "to", "data"];
      (((keys) - top) | select(length > 0) | "unknown top-level field(s): \(join(", "))"),
      (["emergency_upgrade_board", "protocol_upgrade_handler", "owner"][] as $k
        | select(has($k) and ((.[$k] | type) != "string" or (.[$k] | test("^0x[0-9a-fA-F]{40}$") | not)))
        | "\($k) is not a 20-byte hex address"),
      (select((._comment // "" | type) != "string") | "_comment must be a string"),
      (select((.transactions | length) == 0) | "the file has no transactions"),
      (.transactions | to_entries[] | .key as $i | .value as $t |
        if ($t | type) != "object" then "tx \($i): not a JSON object"
        else
          ((($t | keys) - allowed) | select(length > 0) | "tx \($i): unknown field(s): \(join(", "))"),
          (["from", "to", "data"][] as $k | select(($t[$k] | type) != "string") | "tx \($i): \($k) must be a string"),
          (select(($t.label // "" | type) != "string") | "tx \($i): label must be a string"),
          (select($t | has("step")) | select($t.step != $i + 1)
            | "tx \($i): step is \($t.step), expected \($i + 1) (steps must run 1, 2, 3, ... in file order)")
        end)' "$file")"
    [ -z "$shape_errors" ] || die "malformed emergency-upgrade-board file:
$shape_errors"
    jq --arg net "$network" '[.transactions | to_entries[] | .value as $t | {
        description: ((if $t.step != null then "step \($t.step)" else "tx \(.key)" end)
                      + (if ($t.label // "") != "" then ": \($t.label)" else "" end)),
        network: $net, from: $t.from, to: $t.to, value: "0", data: $t.data}]' "$file" >"$plan_dir/normalized.json"
    ;;
  *) die "$file is neither an emergency-upgrade-board file nor a transaction-simulator file" ;;
esac
norm="$plan_dir/normalized.json"
count="$(jq length "$norm")"

# ---------------------------------------------------------------- field values
value_errors="$(jq -r '
  to_entries[] | .key as $i | .value as $t |
  (select($t.description | explode | any(. < 32 or . == 127)) | "tx \($i): description contains control characters"),
  (["from", "to"][] as $k | select($t[$k] | test("^0x[0-9a-fA-F]{40}$") | not)
    | "tx \($i): \($k) is not a 20-byte hex address"),
  (select($t.data | test("^0x([0-9a-fA-F]{2})*$") | not) | "tx \($i): data is not 0x-prefixed, even-length hex"),
  (select($t.value | test("^[0-9]+(\\.[0-9]{1,18})?$") | not)
    | "tx \($i): value must be a decimal ETH amount with at most 18 decimals")
' "$norm")"
[ -z "$value_errors" ] || die "malformed transaction file:
$value_errors"

# EIP-55: a mixed-case address must carry a valid checksum (catches typos).
for i in $(seq 0 $((count - 1))); do
  for k in from to; do
    a="$(jq -r --argjson i "$i" --arg k "$k" '.[$i][$k]' "$norm")"
    if [ "$a" != "$(lower "$a")" ] && [ "$a" != "$("$CAST" to-check-sum-address "$a")" ]; then
      die "tx $i: $k $a has an invalid EIP-55 checksum"
    fi
  done
done

# ---------------------------------------------------------------- selection
if [ -z "$range" ]; then
  first=0 last=$((count - 1))
elif [[ "$range" =~ ^([0-9]{1,6})-([0-9]{1,6})$ ]]; then
  first=$((10#${BASH_REMATCH[1]})) last=$((10#${BASH_REMATCH[2]}))
elif [[ "$range" =~ ^[0-9]{1,6}$ ]]; then
  first=$((10#$range)) last=$first
else
  die "range must be N or A-B (0-based, inclusive), got: '$range'"
fi
[ "$first" -le "$last" ] || die "range start $first is after its end $last"
[ "$last" -lt "$count" ] || die "range end $last is out of bounds: the file has $count transactions (0..$((count - 1)))"

# Not cfg: jq -e treats a false result as a failure.
allow_value="$(jq -r '.execution.allowNonZeroValue' "$CONFIG_FILE")"
case "$allow_value" in true | false) ;; *) die "config: execution.allowNonZeroValue must be true or false" ;; esac
selection_errors="$(jq -r --argjson a "$first" --argjson b "$last" --arg net "$network" --argjson av "$allow_value" '
  def is_set: . != null and . != false and . != 0 and . != "0" and . != "";
  to_entries[] | select(.key >= $a and .key <= $b) | .key as $i | .value as $t |
  (select($t.network != $net) | "tx \($i): network is \"\($t.network)\", environment expects \"\($net)\""),
  (select($av | not) | select($t.value | test("^0+(\\.0+)?$") | not)
    | "tx \($i): sends \($t.value) ETH; config.json allows only zero-value transactions"),
  (select($t.testOnly | is_set) | "tx \($i): testOnly (simulation-only, never executed); choose a range without it"),
  (select($t.emulateAllBatchesExecuted | is_set) | "tx \($i): emulateAllBatchesExecuted needs simulator state overrides; not executable here"),
  (select($t.timeIncrease | is_set) | "tx \($i): timeIncrease needs a simulated time jump; not executable here")
' "$norm")"
[ -z "$selection_errors" ] || die "selected transactions cannot be executed:
$selection_errors"

senders_json="$(jq -c --argjson a "$first" --argjson b "$last" \
  '[to_entries[] | select(.key >= $a and .key <= $b) | .value.from | ascii_downcase] | unique' "$norm")"
sender_count="$(jq length <<<"$senders_json")"
senders="$(jq -r 'join(", ")' <<<"$senders_json")"
if [ "$sender_count" -ne 1 ] && [ "$simulation_only" != true ]; then
  die "selected range $first-$last has $sender_count different senders ($senders); one run executes one sender's transactions, so pick a range with a single sender"
fi

# ---------------------------------------------------------------- plan
tx_lines="$plan_dir/.plan-txs.jsonl"
: >"$tx_lines"
for i in $(seq "$first" "$last"); do
  t="$(jq -c --argjson i "$i" '.[$i]' "$norm")"
  data="$(jq -r .data <<<"$t")"
  value_wei="$("$CAST" to-wei "$(jq -r .value <<<"$t")" ether)"
  data_bytes=$(((${#data} - 2) / 2))
  if [ "$data_bytes" -ge 4 ]; then selector="${data:0:10}"; else selector=""; fi
  jq -c --argjson i "$i" --arg w "$value_wei" --arg s "$selector" --argjson n "$data_bytes" \
    --arg h "$("$CAST" keccak "$data")" \
    '{index: $i, description, from, to, value, valueWei: $w, data, selector: $s, dataBytes: $n, dataKeccak: $h}' \
    <<<"$t" >>"$tx_lines"
done

sender_json=null
if [ "$sender_count" -eq 1 ]; then sender_json="$(jq -c '.from' "$tx_lines" | head -n 1)"; fi
jq -s --slurpfile src "$plan_dir/source.json" --arg env "$environment" --arg net "$network" --arg fmt "$format" \
  --argjson cid "$chain_id" --argjson so "$simulation_only" --argjson sender "$sender_json" \
  --argjson a "$first" --argjson b "$last" --argjson n "$count" \
  '{source: $src[0], format: $fmt, environment: $env, network: $net, chainId: $cid, simulationOnly: $so,
    sender: $sender, range: {first: $a, last: $b}, fileTxCount: $n, transactions: .}' \
  "$tx_lines" >"$plan_dir/plan.json"
rm -f "$tx_lines"
plan_sha="$(sha256_of "$plan_dir/plan.json")"
printf '%s\n' "$plan_sha" >"$plan_dir/plan.json.sha256"

# ---------------------------------------------------------------- summary
repo="$(jq -r .source.repo "$plan_dir/plan.json")"
commit="$(jq -r .source.commit "$plan_dir/plan.json")"
path="$(jq -r .source.path "$plan_dir/plan.json")"
{
  printf '## Transactions to execute\n\n'
  printf '| | |\n|---|---|\n'
  printf '| Source | [`%s`](https://github.com/%s/blob/%s/%s) at `%s` |\n' "$path" "$repo" "$commit" "$path" "$commit"
  printf '| File git blob / sha256 | `%s` / `%s` |\n' "$(jq -r .source.gitBlobSha "$plan_dir/plan.json")" "$(jq -r .source.sha256 "$plan_dir/plan.json")"
  printf '| Format | %s |\n' "$format"
  if [ "$format" = emergency-upgrade-board ]; then
    for k in owner emergency_upgrade_board protocol_upgrade_handler; do
      v="$(jq -r --arg k "$k" '.[$k] // ""' "$file")"
      if [ -n "$v" ]; then printf '| %s | `%s` |\n' "$k" "$v"; fi
    done
    c="$(jq -r '._comment // ""' "$file")"
    if [ -n "$c" ]; then printf '| comment (from the file) | %s |\n' "$(md_escape "$c")"; fi
  fi
  printf '| Environment | `%s` (network `%s`, chain id %s) |\n' "$environment" "$network" "$chain_id"
  if [ "$sender_count" -eq 1 ]; then
    printf '| Sender | `%s` |\n' "$(jq -r .sender "$plan_dir/plan.json")"
  else
    printf '| Sender | %s senders (simulation only) |\n' "$sender_count"
  fi
  printf '| Selected | %s..%s (%s of %s) |\n' "$first" "$last" $((last - first + 1)) "$count"
  printf '| plan.json sha256 | `%s` |\n\n' "$plan_sha"
  printf '| # | description | from | to | value (ETH) | selector | calldata bytes | keccak256(calldata) |\n'
  printf '|---|---|---|---|---|---|---|---|\n'
  while IFS= read -r line; do
    printf '| %s | %s | `%s` | `%s` | %s | `%s` | %s | `%s` |\n' \
      "$(jq -r .index <<<"$line")" "$(md_escape "$(jq -r .description <<<"$line")")" \
      "$(jq -r .from <<<"$line")" "$(jq -r .to <<<"$line")" "$(jq -r .value <<<"$line")" \
      "$(jq -r 'if .selector == "" then "-" else .selector end' <<<"$line")" \
      "$(jq -r .dataBytes <<<"$line")" "$(jq -r .dataKeccak <<<"$line")"
  done < <(jq -c '.transactions[]' "$plan_dir/plan.json")
  skipped="$(jq -r --argjson a "$first" --argjson b "$last" \
    'to_entries[] | select(.key < $a or .key > $b) | "| \(.key) | `\(.value.from)` | `\(.value.to)` |"' "$norm")"
  if [ -n "$skipped" ]; then
    printf '\n**Not in this run** (outside the selected range):\n\n| # | from | to |\n|---|---|---|\n%s\n' "$skipped"
  fi
} >"$plan_dir/summary.md"

log "plan: $plan_dir/plan.json ($format, $((last - first + 1)) txs, sha256 $plan_sha)"
