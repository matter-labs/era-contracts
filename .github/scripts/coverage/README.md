# Coverage regression check

`coverage-non-decreasing` in `l1-contracts-ci.yaml` compares the filtered, combined
Foundry + Anvil **line coverage** of a PR's tested merge commit with its exact base
commit. The existing 75% Foundry-only floor remains a separate check.

Both revisions use the same workflow steps, a fixed Foundry coverage seed, and
separate artifacts within the same run. Each checkout supplies its own contracts,
tests, pinned toolchain, and coverage exclusions. Anvil specs are discovered per
revision and distributed across two groups; the report still verifies that every
spec actually ran.

The base is measured on every PR run. This adds one build and one coverage pass,
but needs no stored baseline, token for another workflow, or initial seeding.
Reports from a different commit are never substituted. Missing reports and failed
or skipped coverage jobs fail the comparison.

## Comparison

The script sums covered and instrumented lines across the report. It compares
their ratios with integer arithmetic, so equal coverage passes and even a decrease
hidden by rounded percentages fails. Empty, truncated, and inconsistent reports
are rejected. The job summary shows both commit SHAs, counts, percentages, and the
delta in percentage points.

Run it locally with two filtered combined LCOV reports and their full commit SHAs:

```sh
node .github/scripts/coverage/compare-lcov.js base.info pr.info "$BASE_SHA" "$PR_SHA"
node --test .github/scripts/coverage/compare-lcov.test.js
```

## Merge policy

Make `coverage-non-decreasing` a required check and require PRs to be up to date
with their target branch to enforce the rule at merge time. The workflow currently
runs on `pull_request`; a merge queue would also need `merge_group` support.

Changes to the measurement itself (toolchain, exclusions, or contract structure)
can change the ratio without removing tests. Review these changes explicitly;
rare exceptions follow the coverage policy in [AGENTS.md](../../../AGENTS.md#coverage-requirements).
