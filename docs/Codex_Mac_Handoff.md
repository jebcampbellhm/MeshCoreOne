# Continue LoRa OTA work on the Mac

Updated October 28, 2026. Repository: https://github.com/jebcampbellhm/MeshCoreOne
Branch and GitHub default: `lora-ota`. Implementation validated at `370df4e1`;
validation documentation recorded at `9f9cb494`.

## Upstream tracking policy (October 28, 2026)

Use `upstream/main` (stable releases) for future upstream merges. Keep our
application work on `lora-ota`, tracking `origin/lora-ota` for pushes and pulls.
Do not merge `upstream/dev` unless explicitly requested. Preserve the already
merged development changes through `f1bdec0f` (1.6.2); do not downgrade to stable
1.6.1 or discard MC1OTA features while waiting for stable to catch up.

For the next upstream update, fetch upstream and inspect/merge `upstream/main`,
then run relevant tests and build before installing. The October 28 fetch found
no newer development changes; a fresh signed generic-iOS build passed.

## User intent and current scope

Build MeshCore One for the user's iPhone, then validate signed full application,
in-place delta, and bootloader MOTA transfers to Heltec MeshTower V2 SD repeaters.
The phone connects by Bluetooth to an nRF52 Full Companion. The companion serves
the file over LoRa to the repeater; there is no Bluetooth connection to the repeater.
The implemented screen stages files only. Installation remains a separate command.

Read [the OTA usage guide](LoRa_OTA_Usage.md) first for signing commands, firmware
prerequisites, the exact command sequence, Python comparison, and validation evidence.
Read [the investigation](LoRa_OTA_Investigation.md) for the wider roadmap; planned
features there must not be mistaken for implemented features.

## Resume on the Mac

```sh
git clone --branch lora-ota https://github.com/jebcampbellhm/MeshCoreOne.git
cd MeshCoreOne
```

Open this checkout as a Codex project and ask:

> Read docs/Codex_Mac_Handoff.md and docs/LoRa_OTA_Usage.md. Continue the LoRa OTA
> project: inspect my Mac's Xcode setup, build the app, help configure local Apple
> signing and run it on my iPhone, then prepare hardware validation for full,
> delta, and bootloader MOTA staging. Preserve the existing transfer-only scope.

Follow [Development.md](Development.md) and the Makefile for project generation.
The project uses XcodeGen and SwiftGen; `make generate` creates a gitignored
`dev.yml` for the user's local Apple team ID. Signing credentials and private OTA
keys are not in this repository and must stay out of commits.

Check the installed SDK before building: upstream currently contains an iOS 27
`swipeActionsContainer()` call. The passing CI build used Xcode 26.6 and substituted
the existing older-OS fallback only in the disposable CI checkout. Do not claim
that the unmodified app has already passed a full Xcode 27 or signed-device build.
The local Mac compatibility fix now guards that call with `#if compiler(>=6.4)`
(the Apple toolchain shipped with Xcode 27), while retaining the runtime iOS 27
availability check. Xcode 26 uses the existing fallback. CI now builds the source
directly without rewriting the helper. This guard assumes the SDK and compiler
shipped together in Xcode; a custom newer toolchain with an older SDK is not covered.

### Local Mac validation, October 16, 2026

- Xcode 26.6 (17F113), Swift 6.3.3, iOS 26.5 SDK and simulator runtime.
- Original swipe helper reproduced the missing-symbol compiler error; the guarded
  helper passed direct simulator SDK type-checking.
- Full Debug build passed for `generic/platform=iOS Simulator`, with
  `CODE_SIGNING_ALLOWED=NO`, using the generated `MC1.xcodeproj`.
- Existing actor-isolation warnings remain in chat UI code. No test suite or
  signed-device/hardware validation was run as part of this build check.
- Full Xcode is now selected with `xcode-select`; required Homebrew tools are
  installed. Use `gmake generate` (or add Homebrew Make's `gnubin` to PATH).

Signing and device installation are now configured through the gitignored
`dev.yml`; subsequent signed iPhone builds passed. The simulator build alone
does not validate Bluetooth or LoRa transfers.

## Validation and next work

### Upstream sync, October 27, 2026

- Merged `Avi0n/MeshCoreOne` development branch at `f1bdec0f` (version 1.6.2)
  into local `lora-ota`, merge commit `56eaa135`. Included in the October 28 GitHub push.
- Resolved remote CLI and serialized event-wait conflicts, retaining upstream
  cancellation/Radio CLI handling and OTA reply routing/no-replay behavior.
- Preserved local Xcode 26 compatibility changes. Added the same compiler guard
  for iOS 27 toolbar visibility priority and an explicit weak capture in the
  chat scroll cancellation task to satisfy Swift 6.3.3 concurrency checking.
- Full unsigned Debug simulator build passed with Xcode 26.6 / iOS 26.5 SDK.
- Targeted existing tests passed: 26 MeshCore tests (OTA and serialization) and
  26 MC1Services tests (OTA workflow and remote CLI). Full suites and hardware
  validation were not run.
- Pre-sync changes were restored and remain backed up in the named pre-upstream
  Git stash. The restored fixes are included in the October 28 GitHub push.

[Run 38788407077](https://github.com/jebcampbellhm/MeshCoreOne/actions/runs/38788407077)
passed both Swift test suites (504 core tests, 2,146 service tests), the iOS simulator
compatibility build, and pinned Python/Rust package checks. The delta fixture was
reconstructed with detools and compared with the expected image. All three types
have matching reference Bluetooth descriptors and complete file readback.
Fixtures are synthetic test inputs, never firmware to flash.

Historical pre-device checklist (subsequent direct-link bootloader and firmware
installation succeeded, as recorded below):

1. Build and run on the user's iPhone with local signing.
2. Confirm actual companion/repeater firmware, trusted signing key, SD staging,
   and the installed bootloader's capabilities using the usage guide.
3. Exercise full, delta, and bootloader staging on the direct link, including
   cancellation, loss of Bluetooth, and radio restoration. Record observed results.
4. Keep installation separate. Bootloader staging requires the exact SD self-update
   profile already installed; an arbitrary legacy bootloader needs local provisioning.

Still not implemented: radio rehearsal/RX power-saving negotiation, automatic
installation, or post-reboot verification. Relay distribution and durable recovery
are now implemented as described below; hardware multihop testing is ongoing.

## Connected-phone OTA logs

### Distribution and setup-command implementation

Repeater settings now includes **Distribute OTA packages through relays** and
**Setup commands**. See the distribution section in `LoRa_OTA_Usage.md` for the
operating procedure and limitations. The original transfer remains separate.

Distribution manages at most two relays plus a destination, up to eight signed
packages, and a `tempradio2` window. It requires idle secondary profiles/schedules
and full companion general local CLI support; the older 0x4A OTA-control bridge
does not permit radio2 commands. Remote SD archives capture/serve; explicitly
unsupported internal/QSPI archives are forward-only. Exact MID/target served
entries are used for readiness; missing/truncated/unreachable results remain
unconfirmed. It does not enforce an exclusive RF path or install packages.

Recovery and the bounded package copies live in Application Support under
`MC1OTA-Distribution/job.json` and `<MID>.mota`. Every mutation is journaled
before sending, originals are restored only when ownership is still confirmed,
and the job is retained until cleanup succeeds and the user closes it. The
original single-file transfer is blocked while a saved job exists. Leaving the
screen stops the phone source; node archives can continue during their windows.
Polling is foreground-only, approximately once per minute, plus manual refresh.

The batch CLI sends up to 50 lines sequentially, stops on errors/timeouts, and
uses `sendSingleCLICommand` to avoid mutation replay. Inputs/results are view
memory, not saved presets. General command audit behavior still applies.

Validation: 41 MC1Services focused tests in 8 suites, 18 MeshCore focused tests
in 4 suites, and the signed iPhone build passed. Hardware multi-hop distribution
and radio2 handoff are not yet validated; do not infer them from prior successful
single-file bootloader/firmware uploads.

October 28 phone logs confirmed that busy-login retry and temporary-channel
authentication work. The next abort was unrelated SD archive downloads
(`A99EF3E6` / `FA209272`) occupying the slot while preparing bootloader `57CBECA2`.
The receiver reported `cache=on/0` despite `autofetch=off`; cancelling an archive
retained its partial and allowed automatic capture to restart. The workflow now
pauses archive capture, verifies it is off, and restores the original setting
in cleanup. The user subsequently confirmed successful bootloader transfer and
manual copy/paste installation, then successful firmware installation (roughly
one hour at BW250).

Latest update defaults to direct link on, BW500, and OTA speed 2×. Each device's
prior speed is read and restored independently during cleanup, including after
lost acknowledgments. Speed has no firmware expiry; recovery commands appear
if restoration is unconfirmed. The entry button now performs non-mutating
Bluetooth MOTA/status/speed/radio capability checks and links to the required
full companion firmware at https://mikecarper.github.io/MeshCore/.

The transfer screen now provides a copyable manual install command after
successful staging, plus a read-only status refresh for reopening the screen.
Bootloader commands require matching download/staged IDs and the full 16-hex
staged hash. Firmware uses `ota install`. Neither action automatically installs.

MC1OTA retains only two transfer logs of at most 128 KiB each, excluding passwords
and firmware bytes. Read these directly while the paired phone is connected and
unlocked; no manual phone export is needed:

```sh
bash scripts/fetch-ota-logs.sh YOUR_DEVICE_ID /tmp/MC1OTA-logs
```

This fetches only `Library/Caches/MC1OTA-SessionLogs` from the
`com.jebcampbellhm.mc1ota` development app container. Logs begin with the next
transfer attempt; they are also shareable from the transfer screen. Inspect the
timestamp and latest stage before diagnosing a failure. Do not initiate an OTA
transfer merely to produce a log.

## Source pointers

- `MeshCore/Sources/MeshCore/OTA`: container validation, bootloader contract,
  Bluetooth protocol, seeder and source lifecycle.
- `MC1Services/Sources/MC1Services/Services/LoRaOTAWorkflow.swift`: login,
  preflight, temporary radios, seeding, catalog/pull, monitoring and cleanup.
- `MC1Services/Sources/MC1Services/Services/OTAPackageCompatibility.swift`:
  live board/ABI/codec/base and staged bootloader checks.
- `MC1/Views/RemoteNodes/Repeaters/LoRaOTAView.swift`: Files import and transfer UI.
- `ci/generate_mota_packages.py` and `ci/check_mota_packages.py`: reproducible
  public test-key fixtures and independent reference checks.

Reference revisions are pinned in the usage guide and CI. The actual Python runner
is `tools/lora_ota/lora_ota.py` in mikecarper/MeshCore's `keymindCascade` branch.
Reference checkouts from the Windows machine are not required: CI fetches them,
and they can be cloned separately on the Mac if deeper comparison is needed.

This file preserves task context in GitHub; it does not migrate the original
Codex chat or create a Codex Cloud environment.

### Mixed distribution radio modes

The distribution screen now offers **Older destination: use tempradio**.
Companion/relays keep tempradio2; the final node uses primary tempradio.
`legacyDestinationID` is optional in the durable journal for backward decoding.
Per-contact tx.user routing is journaled before the destination switch, then set
to both and verified. All secondary paths are prepared first. Primary switch
timeouts reconcile via a read instead of replay. Recovery retains relay windows
when destination restoration fails, and restores the original contact routing
after the destination. Tests simulate unsupported destination radio2 commands,
reachability through contact routing, lost primary ACK and failed normalradio.
Physical mixed-profile propagation remains to be tested.

Mixed-mode validation: 24 focused MC1Services tests in 3 suites passed, including
parameterized recovery cases; signed iPhone Debug build and codesign verification passed.

### Relay selection and saved paths

Distribution now reuses SavedPathsSheet, imports the destination contact path,
and offers searchable repeater contacts plus NodeAuthenticationSheet admin login.
Relay menus exclude the other slot. OTADistributionRoute resolves hashes strictly,
removes mirrored trace returns and a terminal destination, rejects collisions,
unknowns, repeats and more than two relays. Import updates participants only;
it does not set firmware routing paths. Nine focused tests across the route and
distribution suites passed; the signed iPhone build and signature verification passed.

### OTA timeout correction

The phone log at 2026-10-28 18:20:44Z showed relay 2 timing out on
`get radio2` after exactly 15 seconds, before any preparation mutations.
RemoteOperationTimeoutPolicy was clamping the requested 30-second budget to 15.
It now honors explicitly extended CLI budgets up to 30 seconds; firmware
suggestions alone still use the normal 15-second cap. Both one-shot distribution
and direct OTA commands request 30 seconds. Mutation replay behavior is unchanged.

### October 28 publication validation

The 30-second CLI timeout correction passed 38 focused service tests and a
signed iPhone build; the updated application was installed successfully.
No signing credentials, development provisioning files, or downloaded phone logs
are included in Git. `scripts/fetch-ota-logs.sh` is tracked for connected-phone diagnostics.

Final pre-push regression run: 49 MC1Services tests in 8 suites and 5 MeshCore
source/seeder tests in 2 suites passed. The most recent source build was signed
and installed on the iPhone successfully; subsequent edits were documentation
and the ignore rule for the log retrieval script.
