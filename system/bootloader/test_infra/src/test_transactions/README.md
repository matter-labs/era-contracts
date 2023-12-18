# Test Transactions

This directory contains JSON serialized 'Transaction' objects that are inserted into bootloader memory during
unittesting.

Please add files with consecutive numbers (0.json, 1.json) - and insert into bootloader in the same order.

Then, they can be accessed in the unittest, by calling `testing_txDataOffset(x)`.
