# CURSOR.md

Whenever adding any new functionality, please look at the project structure and neighboring files, to ensuret that any tests or files that you add are consistent with the style.

## Notes on project structure

### l1-contracts

In the `l1-contracts` folder, all the actual contracts are located in the `contracts` folder.

The tests are located in `test` folder and scripts are located in `deploy-scripts` folder.

Note, that:

- `test` folder can import anything from `deploy-scripts` and `contracts` folders
- `deploy-scripts` folder can import anything from `contracts` folder.
- `contracts` folder can only import things from itself or dependencies (like the OpenZeppelin library, etc.)

### Unit testing

We use foundry for tests.
