# Testing infrastructure for bootloader

This crate allows you to run the unittests against the bootloader code.

You should put your tests in `../tests/bootloader/bootloader_test.yul`, then compile the yul with:

```shell
yarn build
```

And afterwards run the testing infrastructure:

```shell
cargo run
```
