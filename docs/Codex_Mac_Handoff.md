# Continue LoRa OTA work on the Mac

Prepared October 16, 2026. Repository: https://github.com/jebcampbellhm/MeshCoreOne
Branch and GitHub default: `lora-ota`. Implementation validated at `370df4e1`;
validation documentation recorded at `9f9cb494`.

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
Inspect `.github/workflows/lora-ota-validation.yml` for the exact compatibility step.

## Validation and next work

[Run 38788407077](https://github.com/jebcampbellhm/MeshCoreOne/actions/runs/38788407077)
passed both Swift test suites (504 core tests, 2,146 service tests), the iOS simulator
compatibility build, and pinned Python/Rust package checks. The delta fixture was
reconstructed with detools and compared with the expected image. All three types
have matching reference Bluetooth descriptors and complete file readback.
Fixtures are synthetic test inputs, never firmware to flash.

No physical Bluetooth/LoRa transfer or installation has been performed. Next:

1. Build and run on the user's iPhone with local signing.
2. Confirm actual companion/repeater firmware, trusted signing key, SD staging,
   and the installed bootloader's capabilities using the usage guide.
3. Exercise full, delta, and bootloader staging on the direct link, including
   cancellation, loss of Bluetooth, and radio restoration. Record observed results.
4. Keep installation separate. Bootloader staging requires the exact SD self-update
   profile already installed; an arbitrary legacy bootloader needs local provisioning.

Not implemented: relay orchestration, radio rehearsal/RX power-saving negotiation,
persistent recovery/resume, installation UI, or post-reboot verification.

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
