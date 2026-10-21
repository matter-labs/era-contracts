# Upgrade scheduling preconditions

`ServerNotifier.setUpgradeTimestamp` lets a chain admin schedule an available upgrade. A release can
add scheduling prerequisites by registering an `IUpgradePreconditionChecker` for the protocol
version the chain upgrades **from**.

The notifier owner calls `setUpgradePreconditionChecker(oldProtocolVersion, checker)`. Setting zero
removes the checker; versions without a checker retain their existing scheduling behavior.

Scheduling validates the caller, non-zero timestamp and upgrade cut, then calls the checker's
`checkUpgradePreconditions(chainId, zkChain)`. The checker is selected using the chain's current
version, and its DiamondProxy address comes from the CTM. The typed view call must succeed before the notifier
stores the timestamp and emits `UpgradeTimestampUpdated`. Checker reverts propagate to the caller.
The test stub in `ServerNotifier.t.sol` demonstrates the interface.

Register a checker before opening scheduling for the release. Registration does not invalidate
previously stored timestamps, and prerequisites may change after scheduling. Upgrade execution
must retain its own checks. The owner is responsible for selecting the correct checker; registration
does not validate its implementation. A broken checker can block scheduling until the owner replaces
or removes it.

The per-version registry lets future releases add prerequisites without embedding release logic
in the notifier. This change does not register a checker for any existing upgrade; release-specific
implementation, deployment and end-to-end validation belong to the release that adopts it.
