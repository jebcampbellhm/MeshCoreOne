# MeshTower full, delta, and bootloader packages over LoRa

Open the repeater's admin settings → **Firmware → LoRa firmware transfer**.
Load the signed `.mota` from Files, enter the temporary radio options, confirm a
direct radio link, and select **Seed and pull to repeater SD**. Bluetooth connects
the phone only to the nRF52 Full Companion. The companion serves the firmware to
the MeshTower V2 over LoRa; the repeater writes it to SD.

The temporary frequency defaults to **909.5 MHz** and remains editable. Enable
**Clear existing download before transfer** to discard a partial or staged
download on the repeater before starting. The toggle is off by default and resets
after each attempt. Clearing requires successful preflight, an acknowledged
`ota cancel`, and an idle status readback; a failed or ambiguous clear stops the
new transfer without retrying the cancel command.

## Build and sign on your computer

Use [mikecarper/motatool](https://github.com/mikecarper/motatool), reference revision
`5d9646cb08105245fb96c28450669c58763224bb`. Build it with `cargo build --release`,
then put its executable on your PATH. These commands also work in PowerShell:

```sh
# Once per signing identity; preserve this private key securely.
motatool keygen --out signer.key

# Package the EndF-bearing application firmware, sign it, and save the .mota.
motatool build --fw firmware.bin --sign signer.key --out-dir ./motas

# Delta: the base must be the exact EndF-bearing image running on the repeater.
motatool build --base running-firmware.bin --fw firmware.bin --patch-type in-place --sign signer.key --out-dir ./motas

# Bootloader: use the exact MeshTower V2 SD OTAFIX Intel HEX release artifact.
motatool build-bootloader --fw tower-sd-otafix.hex --board heltec_mesh_tower_v2_sdcard --sign signer.key --out-dir ./motas

# Substitute the generated filename printed by build.
motatool verify ./motas/GENERATED_FILENAME.mota --pub signer.key.pub
motatool inspect ./motas/GENERATED_FILENAME.mota
```

`keygen` writes the private key and `signer.key.pub`. Reuse the private key when
signing later releases; copy only the generated `.mota` to the phone. `build`
creates and signs the container in one operation. The screen identifies the
package type from the authenticated manifest, not its filename. It requires
signed, unapproved distribution packages for all three types.

Build the application for
`Heltec_tower_v2_sdcard_repeater_lora_ota_no_external_sensors`, target `0A9DBBF0`,
hardware `Heltec_tower_v2`. The image must include its correct EndF identity.
The app verifies the signature, hashes, target, size, and embedded identity;
the receiver independently checks whether the signer is trusted. Deltas use
format 2, codec 2 (in-place), and the exact running EndF body hash as their base.
The phone authenticates the patch bytes and signed result hash; it cannot verify
the reconstructed image without the base image. The receiver performs that check.

Bootloaders use format 3, target `1150F50E`, hardware
`NRF_BL_239A0071_TOWER_V2_OTA`. They are exactly 41,330-byte containers with a
40-KiB image and 40 blocks of 1,024 bytes. The app validates vectors, embedded
identity/CRC, exact BLM2 envelope location, signed version, S140 6.1.1 continuity,
application base `0x26000`, layout ABI 1, and SD capability flags `0x09`.
The internal-storage MeshTower bootloader is not interchangeable with the SD
profile, even though both share the same target/hardware identity.

The installed bootloader must already report an ABI-3+ SD self-update capability.
This cannot bootstrap an arbitrary legacy bootloader over LoRa. The reference
MeshTower SD path requires local provisioning with a compatible BLM2 bootloader
first; installed-version, upgrade-only, signer, and live continuity checks remain
enforced by the repeater. No phone-side bypass is provided.

Provision the public key through a trusted repeater admin connection before
transferring. Paste the complete 64-character hex contents of `signer.key.pub`:

```text
ota key add PUBLIC_KEY_HEX
ota config autoinstall off
ota config autofetch off
ota storage
```

Expect **SD staging**, with a compatible SD-aware OTAFIX bootloader. An SD card
alone is insufficient. The screen refuses internal delta fallback and preserves
existing downloads unless clearing is explicitly enabled. It does not change
trusted keys or installation policy. Fixed SD firmware may report
`ERR this build does not use a QSPI OTA store` for `ota storage`; the app accepts
that specific reply only when `ota status` reports `bl:SD` and `ota self` confirms
SD apply support and compatible ABI/codecs. The receiver checks media availability
when opening the receive slot. Other storage errors remain failures.

## Transfer sequence

1. Check the companion is not already in temporary radio and its clock is within
   ten minutes of the phone; log into the repeater with its administrator password.
2. Read `ota status`, `ota self`, `ota storage`, and `ota config`. Require matching
   target, supported block size/ABI/codec, idle download, SD staging, and both
   autofetch and autoinstall off. Deltas require the exact base hash. Bootloaders
   additionally require matching `ota bootloader status` board/name/target/SD caps.
3. Send `tempradio frequencyMHz,bandwidthKHz,sf,cr,minutes` to the repeater.
4. Send the same command to the companion through Bluetooth local OTA control.
5. Subscribe to the companion's Bluetooth mOTA requests and start serving the file.
6. Log into the repeater again on the temporary channel and repeat compatibility
   checks. Wait for the file's ID in the paginated `ota ls` catalog; recheck that
   no other download appeared before issuing the pull.
7. Send `ota pull MANIFEST_ID flash`. On this firmware, `flash` selects the
   configured staging backend, which preflight required to be SD.
8. Leave 30 seconds between status queries while Bluetooth seeding continues.
   Poll compact `ota stats` until the selected download ID is done (the longer
   `ota status` can truncate the ID). For bootloaders, require `ota bootloader status`
   to report `staged:ready` with the exact target, manifest ID, and first eight
   image-hash bytes. Then stop serving and request
   `normalradio` on the repeater followed by the companion.

Radio changes and pulls are sent once. Lost acknowledgements trigger observation,
not automatic mutation retries. Restoration failures are shown explicitly; the
bounded temporary windows provide fallback. Stopping seeding does not erase a
partially downloaded file. Resolve an existing download in the terminal before
starting another transfer, or enable the clear-download toggle for the next
attempt. Installation is a separate operation.

After successful bootloader staging the screen displays the exact manual command:

```text
ota bootloader status
ota bootloader install MID8 HASH16
```

Review the status immediately before sending that command through the repeater
admin terminal. `MID8` and `HASH16` must be the verified values from the selected
package. Do not substitute the application command `ota install` for a bootloader.
The app does not automatically run either install command.

The **Manual installation** section fills in the verified command after a
successful transfer. Tap **Copy install command**, open this repeater's CLI,
and paste it when ready. Bootloaders use `ota bootloader install MID8 HASH16`;
full and delta firmware use `ota install`.

If you reopen the screen, **Read OTA status for install command** checks
`ota status`, the compact `ota stats` download ID, and `ota bootloader status`.
The compact replies avoid the status line's 160-byte truncation. Incomplete,
mismatched, or missing bootloader hashes do not produce a command. This read
does not upload, change radio settings, or install anything.

During transfers, automatic SD archive capture (`cache=on`) is paused with
`ota cache off` and confirmed before changing radios. This is independent of
`autofetch`; otherwise unrelated archive downloads can occupy the receive slot.
Cleanup restores `ota cache on` only if it was originally on, including on
failure/cancellation. Cached files are preserved. A restoration failure is shown
with the manual recovery command. Explicit clearing of an install download still
requires the transfer's clear toggle; archive partials may be retained by firmware.

## Comparison with the reference Python runner

Reviewed against MeshCore `keymindCascade` commit
`656cb6924f01acaa1285c75aa3eda1e0151bcb80`, particularly
`tools/lora_ota/lora_ota.py` (`compatible_mota`, `query_bootloader_target`,
`find_and_start_pull`, `monitor_download`, `report_staged_update`, `request_install`).

| Operation | Python runner | MeshCore One |
|---|---|---|
| Full/delta/boot classification | Separate package families | Same; strict signature required for all |
| Delta eligibility | Exact live base hash, nRF52 in-place codec, ABI/codec mask | Same checks for MeshTower SD, repeated after channel change |
| Boot eligibility | Exact live board/name/target, ABI 3+, codecs 5, matching SD caps | Same required capabilities; strict fixed MeshTower SD payload profile |
| Source connection | Runner launches host seeder | Native Bluetooth request worker starts before companion START |
| Radio ordering | Far nodes, relays, source/controller | Repeater then shared source/controller companion; direct link only |
| Clock protection | Forward-only correction with active/scheduled-radio checks and readback | Read-only companion clock bound and inactive-temp check; no automatic clock mutation |
| Radio rehearsal / RX power saving | Short-lease path rehearsal, RXPS/preamble negotiation and recovery journal | Not yet ported; selected settings must already work on this direct path |
| Discovery / pull | Paginated catalog; exact MID; retained-session recovery | Paginated catalog; exact MID; refuses existing downloads; no automatic replacement |
| Lost mutation ACK | Reconcile state before considering retry | Never replay temp-radio or pull; retain authentication and read selected download |
| Transfer monitoring | Passive source progress, airtime-dependent quiet windows, bounded reads | 30-second quiet intervals and up to three attempts for timeout/busy read-only queries |
| Boot completion | Exact staged target/MID/hash, manual install command | Same; generic `fetch done` alone is insufficient |
| Installation | Optional app install plus reboot/version checks; bootloader staging only | Staging only for all types; no automatic reboot/install |
| Cleanup | Readback/recovery journal, shortened leases, relay and RXPS restoration | One-shot normalradio requests, report unconfirmed results, bounded original leases |

This is not a full port of every runner recovery feature. Relay orchestration,
path rehearsal, RXPS negotiation, persistent resume, and post-install verification
remain separate work. Software interoperability tests do not establish RF link
reliability or qualify an installed bootloader on a physical device.

Keep the app in the foreground and the phone connected. Backgrounding cancels
the workflow and attempts cleanup. A killed app or lost Bluetooth connection
cannot guarantee cleanup; wait for the radio windows to expire. This first
version supports a direct companion-to-repeater link, not automated relay radio
changes or resume after app restart. Hardware validation is still required.

## Multi-package distribution (initial implementation)

Repeater settings now has **Distribute OTA packages through relays** and
**Setup commands**, alongside the original single-file transfer.

Distribution accepts up to eight signed packages (each at most 2 MiB), a
destination, and up to two repeater sessions in nearest-to-farthest order.
**Choose saved path** reuses the app's saved trace-path screen; **Use destination’s
current path** imports its contact route. Mirrored trace return hops are removed,
and a final destination entry is not counted as a relay. Unknown or ambiguous
hashes, duplicate nodes, and paths exceeding two relays are rejected. Imports
fill the participant list; they do not rewrite the companion's routing paths.
The two relay menus exclude each other's selection. **Choose relay from known
repeaters** searches repeater contacts by name/key and creates a management
session if needed. **Admin login** opens the existing authentication screen for
each selected contact; credentials are handled by the usual keychain flow. The phone retains one bounded job and its package files until
that job is restored and closed. Archive import verifies signatures and container
integrity across hardware targets; it does not approve installation. The original
single-file install-staging checks remain exact-board checks.

Distribution uses `tempradio2`, an unused secondary profile with no schedules
on participants using that mode, and a companion with
the general local CLI interface in addition to Bluetooth MOTA support. The old
0x4A local OTA-control interface cannot configure secondary profiles. Capability
queries must succeed on all participants before settings are changed. The
primary radio is retained except on an older destination using the option below.
This manages a selected group of participants; it
does not pin an exclusive RF route or prove link quality before seeding.

Enable **Older destination: use tempradio** when the final node lacks secondary
profiles. Companion and relays still use `tempradio2`; only the destination
switches its primary radio. It must support reading `tempradio`, `normalradio`,
and the OTA capability queries. The companion must support per-contact
`get/set tx.user key:<public key>` routing. The app saves the destination's
original contact policy and temporarily uses `both`, so administration can
reach it before and after its primary-radio switch without global crossing.
A lost switch acknowledgment is reconciled by reading state, never by replaying
the switch. Recovery restores the destination first. If that cannot be confirmed,
relay windows and the saved route remain available until expiry; retry recovery.
The saved job also supports recovery after restarting the app. This mode still
uses the archive behavior below; it does not automatically stage or install the
destination's firmware.

At least one selected remote node must report an SD archive. SD nodes capture
and serve; explicit no-SD responses become forward-only nodes. Unavailable or
ambiguous storage errors block preparation. QSPI/internal install staging is
never treated as persistent multi-file archive storage. Existing install
downloads and external host sources are not overwritten. Autofetch and
autoinstall must already be off; this screen manages archive capture separately.
Automatic capture can collect other advertised files, not only the selected set.

Preparation snapshots speed, hop limits, crossing, and archive policy; it saves
each recovery entry before sending its one-shot mutation. The secondary profile
is enabled farthest first and verified by tuple and live status. Lost replies
lead to recovery, not blind retransmission. Settings changed by another operator
are left untouched and shown as pending recovery commands. A saved distribution
blocks the original single-file transfer until restored and closed.

Use **Start phone seeding**, then **Refresh node status**. The visible screen
also refreshes approximately once a minute without overlapping requests.
**Cached · serving** requires the node's SD capability and an exact, non-self
MID/target entry in its own served catalog, with no external host attached.
Truncated catalogs and failed reads remain unconfirmed; they are never inferred
from counts. A handoff indication requires a fresh successful read showing one
archive offers every selected package. Check downstream progress after stopping
the phone source; actual multi-hop propagation still requires hardware testing.

Leaving the screen/backgrounding stops phone seeding but leaves the journal and
node windows intact. Verified archives can continue serving independently until
the window expires. Reopen and refresh for progress; iOS background polling is
not implemented. **Finish and restore settings** restores owned policies and
closes the secondary windows. **Close completed distribution** deletes the phone
job/package copies after all recovery entries are cleared. Node archives remain.
Cached packages are not automatically staged or installed; use the original
single-file workflow for supported MeshTower installation staging.

Setup commands is a separate per-repeater multiline panel (up to 50 commands,
120 UTF-8 bytes per line). Blank lines and full-line `#` comments are ignored.
It uses one-shot commands in order, waits for each reply, stops on errors/timeouts
or known connection-changing commands, and offers Stop after current command.
Input and results stay in view memory, not saved presets or OTA log files.

## Session diagnostics

Opening **LoRa firmware transfer** checks the connected companion's MOTA source
status, OTA speed command, and inactive temporary-radio state before showing the
screen. This probes capabilities, not firmware provenance. The required full
companion firmware is available at https://mikecarper.github.io/MeshCore/;
this app currently requires its Bluetooth MOTA transport. The check runs again
before transfer to catch a changed companion or busy source.

Defaults are direct link enabled, 909.5 MHz, 500 kHz bandwidth, SF5, CR4/5,
and OTA speed 2×. Bandwidth +/- steps are 62.5, 125, 250, and 500 kHz.
OTA speed is applied to both devices after reading each original value. Cleanup
restores each changed value before restoring the radios, including after an
error or cancellation. A lost setter acknowledgment is not retried; cleanup
still attempts restoration. Unconfirmed restoration displays the exact command.
Unlike temporary radio, firmware persists speed changes without an expiry: if
the app is killed or the link is lost, check `ota speed` on both devices and
restore the prior values recorded in the session log.

Each transfer records timestamped stages, commands, replies, waits, errors, and
cleanup. Passwords and firmware contents are omitted. Only the two most recent
sessions are retained, each capped at 128 KiB, in
`Library/Caches/MC1OTA-SessionLogs` inside the app container. iOS may purge caches.
Use **Share latest session log** or **Share previous session log** on the transfer
screen after the transfer ends.

With the development phone paired, unlocked, and connected to the Mac, retrieve
only these logs with:

```sh
bash scripts/fetch-ota-logs.sh DEVICE_ID /tmp/MC1OTA-logs
```

The script uses `devicectl` app-container access; no manual export from the phone
is needed. It does not fetch messages, keys, or the rest of the app database.

Authentication is retained across the radio change, matching the Python runner.
The workflow waits five seconds after retuning and another five seconds after
starting the seeder. Initial login retries explicit companion busy errors up to
four attempts; read-only queries retry busy/timeouts up to three attempts, with
five-second pauses. Mutating commands remain one-shot.

## Three-package software validation

[Validation run 38788407077](https://github.com/jebcampbellhm/MeshCoreOne/actions/runs/38788407077)
passed for implementation commit `370df4e1`: 504 MeshCore tests across 58 suites,
2,146 MC1Services tests across 176 suites, and the hosted iOS simulator
compatibility build. Tests cover all three signed package families, complete
Bluetooth file readback, command ordering, read timeouts, delta base mismatches,
bootloader profile mismatches, and exact staged bootloader ID/hash confirmation.

The pinned upstream Python validator and Rust motatool both accepted the full,
delta, and bootloader fixtures. Python also reconstructed the delta with detools
and matched the expected image; the upstream Bluetooth seeder matched each
descriptor and complete file readback. Fixtures are synthetic test images,
not firmware to flash. Physical transfer and installation remain untested.

## Previous software validation (application-only milestone)

[Validation run 38782615394](https://github.com/jebcampbellhm/MeshCoreOne/actions/runs/38782615394)
passed for commit `479c8fa4`: both Swift package test suites and the hosted iOS
simulator compatibility build. The unchanged application/service implementation
also passed 500 MeshCore tests and 2,144 MC1Services tests in the preceding run.
New workflow tests cover command order, catalog pagination, lost acknowledgements,
SD and installation-policy rejection, source failure, mismatched download IDs,
receiver failure, and cancellation cleanup.

The hosted runner has Xcode 26.6, while upstream uses an iOS 27-only
`swipeActionsContainer` API. For the compatibility build only, CI substitutes
that existing helper's older-OS fallback in its temporary checkout. OTA source
is unchanged. This is not a full Xcode 27 validation or a hardware transfer test.
