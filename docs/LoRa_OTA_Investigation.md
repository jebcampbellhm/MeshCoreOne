# LoRa OTA over Bluetooth: investigation and implementation plan

Investigated 2026-10-15. The protocol/seeder foundation, optional Bluetooth channel,
and first foreground repeater transfer screen are implemented. Hardware validation remains pending.

## Implementation status

Implemented in `MeshCore/Sources/MeshCore/OTA`, `MeshCoreSession+OTA.swift`, and the MC1Services BLE transport:

- Strict signed format-2 full-application verification, including geometry, leaves, mountain-range Merkle root, SHA-256 image hash, Ed25519 signature, unapproved distribution marker, and optional MeshTower V2 embedded EndF identity validation.
- A single immutable firmware catalog implementing COUNT, DESCRIBE, and bounded READ. No delta, bootloader, or compression capability is advertised.
  This original application-only milestone is superseded by the three-package
  extension below; compression remains unadvertised.
- Typed companion local control and source status/start/stop commands, retaining complete OTA response payloads and accepting legacy/current status formats.
- On-demand discovery and subscription of the companion's separate mOTA GATT service, bounded request queue, MTU-sized acknowledged writes, ordered response fragments, and disconnect cleanup.
- A source lifecycle API which starts answering requests before requesting catalog attachment and releases ownership when stopped or failed.
- Signed reference fixtures, corruption/bounds/protocol/session tests, and a macOS GitHub Actions job running both Swift package test suites.

The Python reference check passes against the pinned upstream BLE seeder, including descriptor comparison (with compression capability intentionally disabled), complete file readback, invalid request checks, and positive/negative OpenSSL signature verification. The [macOS validation run](https://github.com/jebcampbellhm/MeshCoreOne/actions/runs/38762705735) passed on implementation commit `b55d4d61c9705b62778475b06d9737110739f992`: 500 MeshCore tests across 57 suites and 2,141 MC1Services tests across 175 suites. The initial CI run caught an inaccessible serializer initializer; the tested commit fixes its access level. The local Windows workspace has no Swift/Xcode toolchain.

The repeater settings now include signed Files import and temporary-radio options.
`LoRaOTAWorkflow` authenticates, checks target/block geometry/SD/installation policy,
moves the repeater and companion, starts seeding, authenticates again, discovers
the selected manifest and requests a full pull. It monitors compact download stats
and attempts radio restoration on completion, failure, or cancellation. Mutation
commands bypass automatic path recovery retries. See [usage and signing commands](LoRa_OTA_Usage.md).

Not yet implemented: persistent recovery journal, restart/resume UI, installation UI,
or post-reboot verification. This version is direct-link and foreground-only. No
hardware transfer or installation has been performed. The later sections retain
the wider investigation and roadmap; they do not imply every item is implemented.

### Three-package extension

The importer and catalog now distinguish signed full applications, in-place
application deltas, and exact MeshTower V2 SD format-3 bootloaders. Seeder descriptors
carry each package's real codec and flags. Delta preflight checks the running base
hash; bootloader preflight checks the separate live boot identity and SD self-update
capabilities, then verifies exact staged MID/hash before reporting completion.
All three paths stage only. See the [usage guide](LoRa_OTA_Usage.md) for build/sign
commands and an explicit comparison with the Python runner, including unported
radio rehearsal and recovery features.

### Foundation API for bench integration

```swift
// Validate off the UI thread; the receiver still enforces signer trust.
let image = try MotaContainer(data: fileData)
try image.validateMeshTowerV2()
let source = try await session.startMotaSource(container: image)
// Keep the source alive while the companion serves requests over LoRa.
// Remote administration and temporary-radio coordination belong to the next stage.
await source.stop()
```

This is developer integration guidance, not a complete update procedure. Do not expose installation until the staged-transfer milestone has passed on the chosen companion and SD-equipped MeshTower.

## Conclusion

MeshCore One can plausibly act as both remote administrator and firmware seeder through one Bluetooth connection to a compatible nRF52 Full Companion. The reference firmware already provides the required Bluetooth data service. The app needs to implement that service and orchestrate the existing remote OTA commands; it does not need to implement the LoRa packet protocol itself.

Topology: MeshCore One holds a verified `.mota` file → Bluetooth → Full Companion → LoRa → OTA-capable repeater. Firmware bytes are served on demand when the companion requests them, rather than uploaded as an unsolicited file stream. The companion remains the radio source. This is not an update of the connected companion itself.

The confirmed initial scope is full application `.mota` images sent through an nRF52 Full Companion to Heltec MeshTower V2 repeaters with SD cards. Bluetooth connects the phone to the companion ONLY; all companion-to-repeater administration and firmware traffic travels over LoRa. Begin with one directly reachable repeater per update session. ESP32 Bluetooth seeding, relay orchestration, delta packages, bootloader updates, ZIP conversion, and automatic release selection are outside the initial scope. Exact installed firmware and bootloader versions remain to be checked on the bench.

## Reviewed references

- MeshCore One: `8b141a48e0645c9b9602ec826f49ba8749d949f6`, local `lora-ota` branch.
- [MeshCore keymindCascade](https://github.com/mikecarper/MeshCore/tree/656cb6924f01acaa1285c75aa3eda1e0151bcb80): fetched upstream branch without changing the existing MeshCore working tree.
- [motatool](https://github.com/mikecarper/motatool/tree/5d9646cb08105245fb96c28450669c58763224bb): local checkout matches fetched `origin/main`.
- The automation script is currently at [`tools/lora_ota/lora_ota.py`](https://github.com/mikecarper/MeshCore/blob/656cb6924f01acaa1285c75aa3eda1e0151bcb80/tools/lora_ota/lora_ota.py), not `tools/ota/lora_ota.py`.
- Most directly applicable: [`tools/ble_mota/ble_mota_seeder.py`](https://github.com/mikecarper/MeshCore/blob/656cb6924f01acaa1285c75aa3eda1e0151bcb80/tools/ble_mota/ble_mota_seeder.py), `docs/companion_protocol.md`, `docs/companion_radio_full.md`, `src/helpers/BleMotaProtocol.h`, and `src/helpers/CompanionMotaControl.h`.
- motatool `src/serve.rs` separates the transport-independent `SeederCore` from serial/TCP transport. `src/format.rs` and `src/verify.rs` define container interpretation and verification.

## Existing wire contract

Normal Nordic UART Service (NUS) continues to carry login, remote CLI, and local source control. A separate encrypted, MITM-authenticated GATT service carries firmware requests and replies. Subscription must be active before starting the source.

| Item | Value |
| --- | --- |
| mOTA service | `14518fc2-7e7a-4d84-8cae-6664b0234cf2` |
| Device Request, notifications | `2bfaa1ee-7030-459a-b65a-e7cfd5b09735` |
| Host Response, acknowledged writes | `acf38a51-dd58-4dce-917f-0b1135e41b1a` |
| Local OTA control on NUS | `0x4A` followed by 1–174 permitted ASCII bytes |
| Source control on NUS | `0x4B action`, where 0=status, 1=start, 2=stop |
| Local control success | `00 text_length text...` |
| Source success | `00 action flags offered_le16 advertised_le16 [packets_sent_le32]` |

Accept both seven-byte legacy source replies and eleven-byte current replies. Flags report channel readiness, source attachment, and another active source owner. Protocol version alone is insufficient: detect service presence and actual command support. The reviewed firmware documents Bluetooth source support specifically for nRF52 Full Companion; ordinary companions and ESP32 sources must not be assumed compatible.

Seeder requests are `MS op args... xor(op || args)`, at most 11 bytes. Replies are `ms op status payload... xor(all prior bytes)`, at most 197 bytes. Baseline operations are COUNT (0x01), DESCRIBE (0x02), and READ (0x03). A descriptor is 38 bytes; a read payload is at most 192 bytes. DEFLATE_BLOCK (0x09) supports independent compressed blocks with at most 190 compressed bytes per response plus the length field. Do not advertise its capability until implemented and tested.

Use acknowledged writes bounded by CoreBluetooth's negotiated maximum write length and the protocol limit. Serialize every fragment of a response; never interleave responses. The reference supports a 20-byte ATT payload fallback. USB and Bluetooth folder ownership are exclusive. Disconnect, unsubscribe, malformed data, or overflow detach the firmware catalog.

## MeshCore One integration points

1. **Bluetooth transport:** `MC1Services/Sources/MC1Services/Transport/BLEServiceUUID.swift`, `BLEStateMachine.swift`, and its callback/delegate extensions currently discover NUS and retain a NUS TX/RX pair. Add optional mOTA discovery on the same peripheral, separate request delivery, and response-characteristic writes. Missing mOTA support must not prevent ordinary connections.
2. **Notification and write routing:** `BLEStateMachine+CBDelegate.swift` currently yields characteristic values into one stream without selecting by UUID. It also consumes one FIFO of write completion sequence IDs. Adding a second characteristic requires explicit routing and coordinated write ownership; otherwise seeder notifications reach the Companion parser or acknowledgments can complete the wrong operation. Preserve the existing ordered callback delivery and reconnect generation protection.
3. **Companion commands:** add builders and typed session operations for 0x4A and 0x4B in the `MeshCore` package. Its command table currently ends at 0x41. Existing `PacketParser.parseSimpleResponse` reduces OK payloads to an optional UInt32, losing the text/status bytes needed here. Introduce a backward-compatible raw-payload or request-context decoding path, including bounded response assembly if BLE notifications fragment a control reply. Do not infer response type merely from a leading zero.
4. **Remote administration:** reuse `MeshCoreSession.sendLogin`, `sendCommand`, and `RemoteNodeService` login/CLI flows, including target identity, permission checks, response matching, timeout handling, and password storage. Do not launch Python, meshcli, or a motatool executable from the iOS app.
5. **Seeder:** a pure, testable component should own an immutable validated file/catalog and generate replies. Keep serving active while START waits for its response: attaching the source enumerates the catalog, so waiting for START before answering requests can deadlock.
6. **Coordinator/UI:** add a service for the update state machine and expose it from repeater administration. Show preparation, transfer, target verification, installation, reboot verification, and recovery states. Packet counts are activity indicators, not completion percentages; target OTA status is the source of transfer progress.

## Proposed first supported workflow

1. Import one prepared full-application `.mota` into app-owned storage. Validate before touching radios. Record a file digest and pin the catalog for the session.
2. Discover source support and authenticate the target administrator. Read target identity, firmware, OTA capability/storage/bootloader requirements, source state, radio settings, and relevant power-saving settings. Check compatibility before enabling transfer.
3. Establish a bounded, compatible temporary-radio window on the target and then the companion, preserving the ordinary configuration. Use local 0x4A for the companion; avoid persisting a temporary tuple through normal radio setters. Reuse the automation's preflight principles, including clock/replay checks where required.
4. Subscribe and start the seeder response worker, then send source START. Confirm attachment and advertised entries. Do not use the serial-only `ota folder on` command over BLE.
5. Send remote `ota ls` and identify the intended manifest, then `ota pull <manifest_id> flash`. Poll remote `ota status` with pacing that leaves room for transfer traffic.
6. Require confirmed target verification and compatibility before offering installation. Send `ota install` only for the approved application image; loss of its acknowledgment is an uncertain outcome, not permission to blindly repeat installation.
7. Verify the target returns with the expected identity/version. Detach the source and restore radio and any changed settings. On cancellation or loss of connection, report unfinished cleanup and rely on bounded remote leases; do not report success just because Bluetooth writes completed.

The reference runner handles substantially more than login and starting motatool: routing, temporary-channel transitions, receiver power saving, preflight, retry ambiguity, install checks, and cleanup. Port the necessary behavior deliberately rather than treating the BLE seeder example as a complete updater.

## Verification and implementation stages

**Stage 1 — protocol and package core:** implement typed codecs and a single-file, uncompressed seeder. Match Python/Rust byte fixtures for COUNT/DESCRIBE/READ, malformed lengths, checksum failures, out-of-range reads, and truncated files. Validate geometry, block leaves, Merkle root, full-image hash, and signatures where applicable. An embedded signing key validates signature integrity, not trusted provenance; keep signer policy explicit and preserve the receiver's enforcement. Reject unsupported formats/package types. Decide between a native Swift implementation and a narrowly wrapped Rust library before implementation; Swift avoids adding a cross-compilation/FFI build requirement, while Rust may reduce verification drift.

**Stage 2 — BLE bench integration:** test optional service discovery, pairing, subscribe/start ordering, 20-byte and larger write fragmentation, simultaneous NUS traffic, callback correlation, cancel/disconnect/reconnect, and busy USB source rejection. Run against an actual supported nRF52 Full Companion before building automatic installation.

**Stage 3 — one-hop staged transfer:** integrate administration and temporary-radio cleanup, stopping after target verification. Test wrong hardware, invalid containers, absent OTA support, link loss, repeated block requests, partial-transfer recovery, and foreground/background transitions. Start with a foreground workflow; uninterrupted iOS background execution is not established by this source review.

**Stage 4 — installation:** add explicit install and post-reboot checks, then hardware-test lost acknowledgments, failed reboot verification, and cleanup failures. Add compression only after the baseline works; cache deterministic compressed blocks off the Bluetooth callback path so each slice belongs to the same stream.

The initial investigation did not run builds or radio tests. Subsequent implementation is validated by the fork's macOS package-test workflow; simulator/app builds and physical radio validation remain separate acceptance gates. No radio settings or firmware have been changed on hardware.

## Implementation plan for the confirmed hardware

### User flow

Add **Firmware Update** to the existing repeater administration screen. The user selects a full application `.mota` from Files, reviews the destination and image version, and starts transfer. Show preflight results before changing radio settings. During transfer show target-reported downloaded/total blocks, elapsed time, recent activity, and the remaining temporary-radio window. Offer **Install and reboot** only after the target reports the selected package ready. Finish with observed post-reboot version and cleanup status.

The app never connects to the repeater over Bluetooth. It uses the already paired companion for both remote administration and firmware transport. The phone remains the file source throughout the transfer; this is not an upload of the entire file into companion storage followed by an autonomous send.

Use **Stop transfer** to stop serving and clean up while retaining a potentially resumable SD download. Treat **Discard staged update** as a separate destructive operation, not automatic cancellation behavior. After installation begins, show verification/recovery rather than claiming it can be cancelled.

### Components to add or extend

Proposed type/file names below are implementation targets, not existing APIs.

| Component | Location | Responsibility |
| --- | --- | --- |
| `MotaContainer`, `MotaValidator`, `MotaSeeder` | `MeshCore` package, new OTA area | Parse and verify full application containers; immutable catalog; bounded COUNT/DESCRIBE/READ replies; reject deltas and bootloader packages. |
| `MeshCoreSession+OTA`, OTA command/status models | `MeshCore` session/protocol areas | Typed 0x4A/0x4B exchanges; retain complete OK payloads; serialize replies alongside existing commands. |
| Optional mOTA channel | `MC1Services` Bluetooth transport | Discover extra GATT service on the existing companion peripheral; route notifications by characteristic; ordered acknowledged writes and disconnect handling. |
| `LoRaOTAService` | `MC1Services` services | Own preflight, target admin commands, source attachment, temporary-radio leases, transfer monitoring, installation and cleanup. |
| `LoRaOTARecoveryStore` | App-owned persistent storage, outside connection service lifetime | Store selected target/companion identities, immutable file digest/path, phase, original settings, leases and uncertain operations. No admin passwords in the journal. |
| `RepeaterFirmwareUpdateView` and view model | `MC1/Views/RemoteNodes/Repeaters` | Import/review, readiness results, transfer progress, install action, actionable errors and recovery. Add localized strings through the existing localization workflow. |

Prefer native Swift for the first implementation, using reference-generated golden fixtures to establish equivalence with motatool. Keep validation and seeder logic independent of CoreBluetooth and UI. If full verification cannot be reproduced confidently, reconsider a small Rust library bridge before shipping rather than weakening validation.

### MeshTower SD preflight

The reviewed `docs/ota_meshtower_v2_sdcard.md` identifies the canonical target as `Heltec_tower_v2_sdcard_repeater_lora_ota_no_external_sensors`, target ID `0A9DBBF0`, hardware ID `Heltec_tower_v2`. Match actual reported identity and package metadata; do not trust filenames or assume an older internal-only image has this identity.

Require a usable SD staging backend, sufficient capacity and successful firmware allocation, an OTA-capable running application, and a compatible SD-aware retained-auth OTAFIX bootloader. Full-image transfers must stop if the node reports internal fallback; do not silently choose a delta or format the SD card. The board name and presence of a card alone do not prove readiness. Keep the card inserted through installation.

SD application installation requires a valid signature trusted by the receiver. Validate the imported full package's geometry, block hashes, Merkle root, image hash, and signature locally. Check whatever signer/capability information the firmware exposes, and retain the receiver's final trust and install checks. Surface unknown compatibility as a preflight failure needing inspection, not as a green check. Do not provision signing keys or replace the bootloader in this flow.

The CLI destination remains `ota pull <manifest_id> flash`: in this firmware, the selected install backend can be SD despite the command's `flash` argument. Do not invent a separate `sd` destination. Distinguish the selected install staging file from the repeater's automatic archive/cache; an archive entry alone is not proof that installation is ready.

### Session ownership and recovery

Use explicit states: idle → validating → preflight → preparing radio → attaching source → transferring → ready to install → installing → verifying reboot → restoring → complete. Every active state can enter failed/interrupted with recovery details. Persist intent before radio changes and before sending install, because a lost acknowledgment does not establish whether the operation ran.

`ServiceContainer` is per connection and is torn down on disconnect. Cancel live seeder tasks during teardown, but retain the recovery journal and imported file outside it. On reconnect, confirm both identities, restore subscriptions, query source and remote state, and reconcile with the journal before offering resume. Never blindly replay install or reuse stale characteristic references. Resume must re-serve the exact same package and let target-reported state determine progress.

Route OTA CLI through the existing per-node command serialization and add operation-specific reply validation. Avoid accepting an arbitrary delayed CLI message as an OTA status or installation result. Coordinate maintenance with periodic polling, user CLI commands, radio edits and device switching; suspend conflicting work while retaining useful connection health behavior. Keep normal asynchronous push notifications working throughout.

Persist original settings only for values the operation actually changes. Use bounded temporary-radio leases and report unconfirmed cleanup distinctly. A lost phone connection must not leave an indefinite temporary-channel configuration. Keep target settings and the companion's local settings separate.

### Delivery order and acceptance gates

1. **Core protocol and validation:** fixtures shared with Python/Rust for valid full images, bad signatures/hashes, wrong target, unsupported package types, truncated frames and bounds. Done when identical requests produce identical responses and invalid files cannot enter a catalog.
2. **Companion BLE seeding:** connect an actual nRF52 Full Companion, enumerate the catalog, serve reads while NUS commands continue, and test small MTU, source busy, disconnect and reconnect. Done when no data enters the wrong parser and every write completion belongs to the correct channel/session.
3. **MeshTower staged transfer:** authenticate over LoRa, pass SD/identity checks, enter the temporary channel, transfer a full image and observe ready state. Done when hardware proves full transfer, interruption/resume and radio cleanup. This milestone intentionally stops before installation.
4. **Install and verify:** add the install action, final readiness recheck, reboot observation and recovery journal reconciliation. Done when normal installation, lost install replies and unavailable post-reboot targets produce accurate results without duplicate blind install requests.
5. **UI and regression completion:** finish localized screens and foreground lifecycle behavior; test ordinary non-OTA companions still connect, chat/admin operations recover after maintenance, and backgrounding or device switching never creates a false success. Keep automatic screen sleep disabled only during active foreground transfer and restore it afterward. Do not promise background transfer until device tests establish it.

Start with uncompressed seeder responses to establish correctness. Full `.mota` images can still use per-block transport compression later: that optimization does not make them delta packages. Add DEFLATE_BLOCK and deterministic caching after the baseline, measuring end-to-end LoRa transfer improvement on this exact hardware.

No exact duration or throughput estimate is justified until a full-size signed image is tested with the selected radio settings. Initial implementation can proceed before the installed versions are known, but physical preflight and installation qualification cannot.
