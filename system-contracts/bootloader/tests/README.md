# Testing

## Full tests

`dummy.yul` and `transfer_tests.yul` are full Yul files, which are replacing the bootloader, and are used in
`zksync-era` crate.

## Unittests

Please put bootloader unittests in `bootloader/bootloader_test.yul` file, and any testing utility functions in
`utils/test_utils.yul`.

To execute tests, you should first run yarn to prepare the source code:

```shell
yarn preprocess && yarn compile-yul
```

And then run the test framework:

```shell
cd test_infa && cargo run
```
