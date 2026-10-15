# Full MeshTower updates over LoRa

Open the repeater's admin settings → **Firmware → LoRa firmware transfer**.
Load the signed `.mota` from Files, enter the temporary radio options, confirm a
direct radio link, and select **Seed and pull to repeater SD**. Bluetooth connects
the phone only to the nRF52 Full Companion. The companion serves the firmware to
the MeshTower V2 over LoRa; the repeater writes it to SD.

## Build and sign on your computer

Use [mikecarper/motatool](https://github.com/mikecarper/motatool), reference revision
`5d9646cb08105245fb96c28450669c58763224bb`. Build it with `cargo build --release`,
then put its executable on your PATH. These commands also work in PowerShell:

```sh
# Once per signing identity; preserve this private key securely.
motatool keygen --out signer.key

# Package the EndF-bearing application firmware, sign it, and save the .mota.
motatool build --fw firmware.bin --sign signer.key --out-dir ./motas

# Substitute the generated filename printed by build.
motatool verify ./motas/GENERATED_FILENAME.mota --pub signer.key.pub
motatool inspect ./motas/GENERATED_FILENAME.mota
```

`keygen` writes the private key and `signer.key.pub`. Reuse the private key when
signing later releases; copy only the generated `.mota` to the phone. `build`
creates and signs the container in one operation. Do not use `--base` (delta),
or `build-bootloader` for this screen.

Build the application for
`Heltec_tower_v2_sdcard_repeater_lora_ota_no_external_sensors`, target `0A9DBBF0`,
hardware `Heltec_tower_v2`. The image must include its correct EndF identity.
The app verifies the signature, hashes, target, size, and embedded identity;
the receiver independently checks whether the signer is trusted.

Provision the public key through a trusted repeater admin connection before
transferring. Paste the complete 64-character hex contents of `signer.key.pub`:

```text
ota key add PUBLIC_KEY_HEX
ota config autoinstall off
ota storage
```

Expect **SD staging**, with a compatible SD-aware OTAFIX bootloader. An SD card
alone is insufficient. The screen refuses internal delta fallback and active
downloads. It does not change trusted keys or installation policy.

## Transfer sequence

1. Log into the repeater using the supplied or saved administrator password.
2. Check target, idle download state, SD staging, and autoinstall off.
3. Send `tempradio frequencyMHz,bandwidthKHz,sf,cr,minutes` to the repeater.
4. Send the same command to the companion through Bluetooth local OTA control.
5. Subscribe to the companion's Bluetooth mOTA requests and start serving the file.
6. Log into the repeater again on the temporary channel; wait for the file's ID
   in the paginated `ota ls` catalog.
7. Send `ota pull MANIFEST_ID flash`. On this firmware, `flash` selects the
   configured staging backend, which preflight required to be SD.
8. Poll `ota status` until the selected ID is ready, then stop serving and request
   `normalradio` on the repeater followed by the companion.

Radio changes and pulls are sent once. Lost acknowledgements trigger observation,
not automatic mutation retries. Restoration failures are shown explicitly; the
bounded temporary windows provide fallback. Stopping seeding does not erase a
partially downloaded file. Resolve an existing download in the terminal before
starting another transfer. Installation is a separate operation.

Keep the app in the foreground and the phone connected. Backgrounding cancels
the workflow and attempts cleanup. A killed app or lost Bluetooth connection
cannot guarantee cleanup; wait for the radio windows to expire. This first
version supports a direct companion-to-repeater link, not automated relay radio
changes or resume after app restart. Hardware validation is still required.
