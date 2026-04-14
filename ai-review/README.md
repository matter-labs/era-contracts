# AI review commands

The folder that allows the team to experiment with the AI code review.

The structure is the following

```
ai-review/
├── docs/
└── commands/
    ├── sb/
    ├── kl/
    └── ...
```

The rules are the following:

- `docs` are shared docs/invariants that are supposed to be shared between members. These are expected to be generally reviewed for correctness. 
- `commands` are AI review commands created by individual team members. To facilitate experimentation, the commands there are not to be reviewed except for clear security issues. This should allow team members to share prompts or commands without necessarily polishing those.

## Expected docs format

They should all start with `# <title>` and `## Relevant files` sections. This is needed so that if the impacted files dont belong to the md file, the AI does not read those. This would also allow for easier non-agentic reviews if implemented.
