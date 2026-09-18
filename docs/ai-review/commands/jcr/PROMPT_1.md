# jcr

Context:

- My codebase of solidity smart contracts for a zksync based L2 can be found in ./era-contracts, the branch should be draft-v31 (verify it)
- The diff from the new branch to the main one can be found in 1947.diff.
- Some additional documentation can be found in ./zksync-era/docs. Don't parse it in full since the beginning, just the bits that are related to each scope during the proposed tasks.

Task:

- Perform a thorough security audit of the current codebase. Put special attention on the files modified in the given PR, but also check the complete codebase.
- The results report MUST ONLY include the following fields: ID (R1-xx), title, confidence level, severity, issue description, impact, affected file and lines, and whether they were introduced in the new PR.
- The output file should be named results-r1.json.

Rules - HAVE TO follow:

- NEVER edit files in the codebase directory, the docs directory, the previous reports or the PR diff.
- The results should be written a JSON output file, to facilitate parsing from other agents. This is the only file that you should write to without explicit permission from the user.
- Do not give excessive on-screen feedback during the task. Just a brief line from time to time to know that you are still working suffice.
- The results report MUST ONLY include the following fields: ID (e.g. A1-01), title, confidence level, severity, issue description, impact, affected file and lines, and whether they were introduced in the new PR.
- Each time you find an issue, spawn an additional subagent to validate the issue and confirm that the lines and files are correct and actually point to the affected code section.

---

Context:

- My codebase of solidity smart contracts for a zksync based L2 can be found in ./era-contracts, the branch should be draft-v31 (verify it)
- The diff from the new branch to the main one can be found in 1947.diff.
- Some additional documentation can be found in ./zksync-era/docs. Don't parse it in full since the beginning, just the bits that are related to each scope during the proposed tasks.
- The results of two other security reviews done by competitor agents can be found in results-r1.json and results-r2.json

Task:

- Validate the findings from previous audits. Feel free to correct or improve their contents, but only if necessary.
- After that, perform a thorough security audit of the current codebase yourself as I think the other models left out important issues. Put special attention on the files modified in the given PR, but also check the complete codebase.
- The output file should be named results-r3.json, and it should include all the valid findings from previous rounds and the new ones that you will find.

Rules - HAVE TO follow:

- NEVER edit files in the codebase directory, the docs directory, the previous reports or the PR diff.
- The results should be written a JSON output file, to facilitate parsing from other agents. This is the only file that you should write to without explicit permission from the user.
- Do not give excessive on-screen feedback during the task. Just a brief line from time to time to know that you are still working suffice.
- The results report MUST ONLY include the following fields: ID (e.g. A1-01), title, confidence level, severity, issue description, impact, affected file and lines, and whether they were introduced in the new PR.
- Each time you find an issue, spawn an additional subagent to validate the issue and confirm that the lines and files are correct and actually point to the affected code section.
