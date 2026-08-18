import 'dart:async';

import 'package:flutter/services.dart';

/// A single tag read event from the reader.
class ZebraTagRead {
  const ZebraTagRead({
    required this.tagId,
    required this.rssi,
    required this.antennaId,
  });

  factory ZebraTagRead.fromMap(Map<dynamic, dynamic> map) => ZebraTagRead(
    tagId: map['tagId'] as String,
    rssi: (map['rssi'] as num).toInt(),
    antennaId: (map['antennaId'] as num).toInt(),
  );

  final String tagId;
  final int rssi;
  final int antennaId;

  @override
  String toString() => 'ZebraTagRead(tagId: $tagId, rssi: $rssi)';
}

/// A reader discovered nearby, before connection.
///
/// Zebra's `ReaderDevice` only exposes a name, not a stable address — use
/// [name] to connect.
class ZebraReaderInfo {
  const ZebraReaderInfo({required this.name});

  factory ZebraReaderInfo.fromMap(Map<dynamic, dynamic> map) =>
      ZebraReaderInfo(name: map['name'] as String);

  final String name;
}

enum ZebraConnectionState { disconnected, connecting, connected }

enum ZebraTriggerState { released, pressed }

/// Dart-side API for the Zebra RFID API3 native plugin.
///
/// Android-only. Wraps a Bluetooth/USB/serial-connected Zebra RFID sled
/// (e.g. RFD40 Premium) for continuous multi-tag inventory reads, with
/// support for the sled's physical trigger.
class ZebraRfidReader {
  ZebraRfidReader._();

  static final ZebraRfidReader instance = ZebraRfidReader._();

  static const MethodChannel _methods = MethodChannel(
    'zebra_rfid_reader/methods',
  );
  static const EventChannel _tagEvents = EventChannel(
    'zebra_rfid_reader/tag_events',
  );
  static const EventChannel _connectionEvents = EventChannel(
    'zebra_rfid_reader/connection_events',
  );
  static const EventChannel _triggerEvents = EventChannel(
    'zebra_rfid_reader/trigger_events',
  );

  Stream<ZebraTagRead>? _tagStream;
  Stream<ZebraConnectionState>? _connectionState;
  Stream<ZebraTriggerState>? _triggerState;

  /// Lists Zebra readers currently reachable (paired Bluetooth, USB, serial).
  Future<List<ZebraReaderInfo>> availableReaders() async {
    final result = await _methods.invokeMethod<List<dynamic>>(
      'availableReaders',
    );
    return (result ?? const [])
        .cast<Map<dynamic, dynamic>>()
        .map(ZebraReaderInfo.fromMap)
        .toList();
  }

  /// Connects to the reader with the given [name] (from [availableReaders]).
  Future<void> connect(String name) =>
      _methods.invokeMethod('connect', {'name': name});

  Future<void> disconnect() => _methods.invokeMethod('disconnect');

  /// Starts continuous inventory (multi-tag) reads. Tags stream via
  /// [tagStream] as they're read.
  Future<void> startInventory() => _methods.invokeMethod('startInventory');

  Future<void> stopInventory() => _methods.invokeMethod('stopInventory');

  /// Runs a single inventory pass and returns everything read within
  /// [timeout], deduplicated by tag ID.
  Future<List<ZebraTagRead>> readAllTagsOnce({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final result = await _methods.invokeMethod<List<dynamic>>(
      'readAllTagsOnce',
      {'timeoutMs': timeout.inMilliseconds},
    );
    return (result ?? const [])
        .cast<Map<dynamic, dynamic>>()
        .map(ZebraTagRead.fromMap)
        .toList();
  }

  /// Emits every tag read while inventory is active.
  Stream<ZebraTagRead> get tagStream => _tagStream ??= _tagEvents
      .receiveBroadcastStream()
      .map((event) => ZebraTagRead.fromMap(event as Map<dynamic, dynamic>));

  /// Emits reader connection state changes.
  Stream<ZebraConnectionState> get connectionState =>
      _connectionState ??= _connectionEvents.receiveBroadcastStream().map((
        event,
      ) {
        switch (event as String) {
          case 'connecting':
            return ZebraConnectionState.connecting;
          case 'connected':
            return ZebraConnectionState.connected;
          default:
            return ZebraConnectionState.disconnected;
        }
      });

  /// Emits physical trigger press/release events from the sled's handle.
  /// The native side auto-starts/stops inventory on these, but the app can
  /// also observe them to drive UI (e.g. a "scanning..." indicator).
  Stream<ZebraTriggerState> get triggerState =>
      _triggerState ??= _triggerEvents.receiveBroadcastStream().map(
        (event) =>
            event == 'pressed'
                ? ZebraTriggerState.pressed
                : ZebraTriggerState.released,
      );
}
