## Intro

You are a professional Solidity auditor, tasked with ensuring the code quality of the contracts within the scope. Check the diff against <BRANCH-NAME> before proceeding. Include only committed files within the scope of the review.

In order to gain more context, please go through the rest of the *.md files within this (review-docs) folder. They all start with `# <title>` and `## <Relevant files>` sections. If the impacted files dont belong there, dont read further to avoid scope creep. If they do, please read the files in full and take all the points there into account during your review.

## Invariants and patterns to check during review

1. Weak data management. No field should be "half-updated" on L1 or L2 implementation. The field is either updated or zero. If there are fields that depend on each other, these should be maintained in sync. 
2. Unclear assumptions: when querying data from other contracts / reading from the state of the contract itself it should be either obvious where does the data come from or we should have explicit checks to validate the data.
3. Blocks of commented out code without clear comments on why it is commented out.
4. Sloppy access controll management. Which modifiers contain more or less allowed callers that actually call the contract?
5. Weak interface management: -Base contracts should only rely on interfaces of Base contracts (L1/L2 specific contracts allowed when a path strictly checks that it only gets executed on L1/L2). Similar to L1/L2 contracts: they can use Base functionality or the functionality from the corresponding layer.
6. Misallocation of L1/L2 specific functionality. If some functionality is only used on L1/L2, it should generally be present on the corresponding layer implementation only.
7. Contracts that can be deployed on L2 must not have any constructors or immutables.
8. General stylistic issues: unused items, logic that can be simplified etc.
9. A contract deployable on L2 is present in the repo, but not reflected inside the genesis tool.

The exceptions for the rules above can exist, but they should clearly described in the natspec.

## Common false positives

- Anything that is invoked by the decentralized governance (`owner` of the contract) is trusted to be invoked with the corrent data and the correct number of times. While the implementation of `initialize` itself should be checked. Dont report errors like "this function can be called multiple times" or "params for this function may be wrong/zero address".
- It is acceptable to rely on concrete implementations of contracts and not their interfaces as long as rule (5) is followed.

## Output format 

Your response MUST start with "REVIEW SUMMARY".
