#!/usr/bin/env bash
# Preflight for the broadcast job: the GitHub environment that holds the key
# must be protected as README.md says (terraform-configurations creates it).
#
#   - it exists
#   - its only required reviewer is config.json's approverTeam
#   - "Prevent self-review" is on, so the approver is not the person who started the run
#   - administrators cannot bypass it
#   - its deployment branch policy is "protected branches", or a custom list
#     holding exactly the default branch. With "protected branches" the default
#     branch must be protected, and every other protected branch is reported,
#     because it may deploy too.
#
# The environment's own protection rules are what enforce this; the check turns
# a misconfiguration into a clear failure before any job names the environment.
# (GitHub creates a missing environment, unprotected, the first time a job names
# it, so the broadcast job must never start if it is missing.) Team membership
# cannot be read with GITHUB_TOKEN, so it is not checked here.
#
# Env: GH_TOKEN (the job's GITHUB_TOKEN with actions:read), REPO, ENVIRONMENT
#      (stage|testnet), GITHUB_ENVIRONMENT_NAME (the name the workflow's broadcast
#      job uses), DEFAULT_BRANCH. Appends a short report to $GITHUB_STEP_SUMMARY
#      (stdout when that is unset).

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
team="$(cfg .approverTeam)"

env_json="$(gh api "repos/$REPO/environments/$name" 2>/dev/null)" ||
  die "GitHub environment '$name' does not exist in $REPO or cannot be read (devops TODO: create it as tools/eoa-upgrade-executor/README.md describes)"

problems="$(jq -r --arg team "$(lower "$team")" '
  ([.protection_rules[]? | select(.type == "required_reviewers")] | first) as $r
  | (if $r == null then "no required reviewers"
     else
       ([$r.reviewers[]? | if .type == "Team" then "team:\((.reviewer.slug // .reviewer.name // "?") | ascii_downcase)"
                           else "user:\(.reviewer.login // "?")" end] | sort) as $have
       | (if $have != ["team:\($team)"] then "required reviewers are [\($have | join(", "))], expected only [team:\($team)]" else empty end),
         (if $r.prevent_self_review != true then "\"Prevent self-review\" is off, so whoever starts a run could approve it" else empty end)
     end),
    (if .can_admins_bypass != false then "administrators can bypass the protection rules" else empty end),
    (.deployment_branch_policy as $p
     | if $p == null then "no deployment branch policy, so any branch could use the secrets"
       elif ($p.protected_branches == true) == ($p.custom_branch_policies == true)
       then "the deployment branch policy must be \"protected branches\" or a custom list holding only the default branch"
       else empty end)
' <<<"$env_json")"

notes=""
if [ -z "$problems" ]; then
  if [ "$(jq -r '.deployment_branch_policy.custom_branch_policies' <<<"$env_json")" = true ]; then
    policies="$(gh api "repos/$REPO/environments/$name/deployment-branch-policies" \
      --jq '[.branch_policies[] | "\(.type // "branch"):\(.name)"] | sort | join(",")')" ||
      die "cannot read the deployment branch policies of '$name'"
    if [ "$policies" != "branch:$DEFAULT_BRANCH" ]; then
      problems="the deployment branch policy allows '$policies'; it must be exactly 'branch:$DEFAULT_BRANCH'"
    fi
    policy_text="custom list: \`$DEFAULT_BRANCH\` only"
  else
    protected="$(gh api --paginate "repos/$REPO/branches?protected=true&per_page=100" --jq '.[].name')" ||
      die "cannot list the protected branches of $REPO"
    if ! grep -qxF -- "$DEFAULT_BRANCH" <<<"$protected"; then
      problems="the policy is \"protected branches\" but the default branch '$DEFAULT_BRANCH' is not protected, so it cannot deploy"
    fi
    others="$(grep -vxF -- "$DEFAULT_BRANCH" <<<"$protected" | paste -sd ',' - | sed 's/,/, /g' || true)"
    if [ -n "$others" ]; then
      warn "these protected branches can also deploy to '$name': $others"
      notes="Other protected branches that may deploy (each run still needs an approval): $others."
    fi
    policy_text="protected branches"
  fi
fi

[ -z "$problems" ] || die "GitHub environment '$name' is not protected as required:
$problems"

{
  printf '## GitHub environment `%s`\n\n' "$name"
  printf 'Approver: team `%s` (self-review prevented, no admin bypass). Deployment branches: %s.\n' "$team" "$policy_text"
  if [ -n "$notes" ]; then printf '\n%s\n' "$notes"; fi
} >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
