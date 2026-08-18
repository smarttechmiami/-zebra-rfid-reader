# zebra_rfid_reader

Flutter plugin wrapping Zebra's RFID API3 SDK for continuous multi-tag
inventory reads from a Zebra sled (e.g. RFD40 Premium) over Bluetooth.
Android-only.

## Setup (required before this plugin will build)

1. Download the Zebra RFID API3 SDK for Android from your Zebra developer
   account and copy the AAR into `android/libs/` in **this** plugin, named
   to match `android/build.gradle`'s dependency line, e.g.:

   ```
   android/libs/rfidapi3lib-2.0.5.292.aar
   ```

   The AAR is not published on Maven and is not committed to this repo
   (Zebra's SDK license does not permit redistribution) — you must place it
   yourself, from your own Zebra partner account.

2. Any **consuming app** (including a FlutterFlow-exported project) also
   needs the same `flatDir` repository declared in its own root
   `android/build.gradle`, pointing at this plugin's `android/libs/`
   directory, and the AAR copied there too — Gradle's `flatDir` repo is not
   visible across project boundaries automatically.

## API

See `lib/zebra_rfid_reader.dart` — `ZebraRfidReader.instance`:

- `availableReaders()` — list nearby/paired readers by name.
- `connect(name)` — connect to a reader (name, not address — Zebra's
  `ReaderDevice` doesn't expose one).
- `startInventory()` / `stopInventory()` — continuous multi-tag reads.
- `readAllTagsOnce({timeout})` — one inventory pass, deduplicated.
- `tagStream` — live tag reads while inventory is active.
- `connectionState` / `triggerState` — reader connection and physical
  trigger (handle button) state.

The physical trigger auto-starts/stops inventory on press/release; the app
doesn't need to call `startInventory`/`stopInventory` itself when the user
is using the sled's handle.
