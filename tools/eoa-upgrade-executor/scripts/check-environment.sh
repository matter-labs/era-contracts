#!/usr/bin/env bash
# Preflight for the broadcast job: the GitHub environment that holds the key
# must be protected as README.md says.
#
#   - it exists
#   - its required reviewers are exactly config.json's approvers (users, no teams)
#   - "Prevent self-review" is on, so the approver is not the person who started the run
#   - administrators cannot bypass it
#   - its deployment branch policy is exactly the default branch
#
# The environment's own protection rules are what enforce this; the check turns
# a misconfiguration into a clear failure before any job names the environment.
# (GitHub creates a missing environment, unprotected, the first time a job names
# it, so the broadcast job must never start if it is missing.)
#
# Env: GH_TOKEN (the job's GITHUB_TOKEN with actions:read), REPO, ENVIRONMENT
#      (stage|testnet), GITHUB_ENVIRONMENT_NAME (the name the workflow's broadcast
#      job uses), DEFAULT_BRANCH. Writes a short Markdown report to stdout.

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd gh jq

for v in REPO ENVIRONMENT GITHUB_ENVIRONMENT_NAME DEFAULT_BRANCH; do
  [ -n "${!v:-}" ] || die "$v is not set"
done
network_of_env "$ENVIRONMENT" >/dev/null
name="$(cfg --arg e "$ENVIRONMENT" '.environments[$e].githubEnvironment')"
[ "$name" = "$GITHUB_ENVIRONMENT_NAME" ] ||
  die "the workflow uses GitHub environment '$GITHUB_ENVIRONMENT_NAME' but config.json says '$name' for $ENVIRONMENT"

env_json="$(gh api "repos/$REPO/environments/$name" 2>/dev/null)" ||
  die "GitHub environment '$name' does not exist in $REPO or cannot be read (devops TODO: create it as tools/eoa-upgrade-executor/README.md describes)"

problems="$(jq -r --slurpfile cfg "$CONFIG_FILE" '
  ($cfg[0].approvers | map(ascii_downcase) | sort) as $want
  | ([.protection_rules[]? | select(.type == "required_reviewers")] | first) as $r
  | (if $r == null then "no required reviewers"
     else
       ([$r.reviewers[]? | if .type == "User" then (.reviewer.login | ascii_downcase) else "team:\(.reviewer.slug // .reviewer.name)" end] | sort) as $have
       | (if $have != $want then "required reviewers are [\($have | join(", "))], expected exactly [\($want | join(", "))]" else empty end),
         (if $r.prevent_self_review != true then "\"Prevent self-review\" is off, so whoever starts a run could approve it" else empty end)
     end),
    (if .can_admins_bypass != false then "administrators can bypass the protection rules" else empty end),
    (if .deployment_branch_policy == null then "no deployment branch policy, so any branch could use the secrets"
     elif .deployment_branch_policy.custom_branch_policies != true
     then "the deployment branch policy must be a custom list holding only the default branch"
     else empty end)
' <<<"$env_json")"

if [ "$(jq -r '.deployment_branch_policy.custom_branch_policies // false' <<<"$env_json")" = true ]; then
  policies="$(gh api "repos/$REPO/environments/$name/deployment-branch-policies" \
    --jq '[.branch_policies[] | "\(.type // "branch"):\(.name)"] | sort | join(",")')" ||
    die "cannot read the deployment branch policies of '$name'"
  if [ "$policies" != "branch:$DEFAULT_BRANCH" ]; then
    problems="${problems:+$problems
}the deployment branch policy allows '$policies'; it must be exactly 'branch:$DEFAULT_BRANCH'"
  fi
fi

[ -z "$problems" ] || die "GitHub environment '$name' is not protected as required:
$problems"

printf '## GitHub environment `%s`\n\nApprovers: %s (self-review prevented, no admin bypass). Deployments only from `%s`.\n' \
  "$name" "$(jq -r '.approvers | join(", ")' "$CONFIG_FILE")" "$DEFAULT_BRANCH"
