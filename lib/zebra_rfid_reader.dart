import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
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
/// Supports Android-native Zebra RFID API3 SDK as well as Web/Simulator mode
/// for web previews (e.g. RFIDora) and testing without physical hardware.
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

  // Web/Simulation Controllers & State
  final _webConnectionController =
      StreamController<ZebraConnectionState>.broadcast();
  final _webTagController = StreamController<ZebraTagRead>.broadcast();
  final _webTriggerController =
      StreamController<ZebraTriggerState>.broadcast();

  ZebraConnectionState _webCurrentState = ZebraConnectionState.disconnected;
  Timer? _webInventoryTimer;
  bool _webIsInventoryActive = false;

  /// Lists Zebra readers currently reachable (paired Bluetooth, USB, serial).
  Future<List<ZebraReaderInfo>> availableReaders() async {
    if (kIsWeb) {
      return const [
        ZebraReaderInfo(name: 'RFD40-Simulated (Web Preview)'),
        ZebraReaderInfo(name: 'RFD8500-Simulated (Web Preview)'),
      ];
    }
    final result = await _methods.invokeMethod<List<dynamic>>(
      'availableReaders',
    );
    return (result ?? const [])
        .cast<Map<dynamic, dynamic>>()
        .map(ZebraReaderInfo.fromMap)
        .toList();
  }

  /// Connects to the reader with the given [name] (from [availableReaders]).
  Future<void> connect(String name) async {
    if (kIsWeb) {
      _webCurrentState = ZebraConnectionState.connecting;
      _webConnectionController.add(ZebraConnectionState.connecting);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      _webCurrentState = ZebraConnectionState.connected;
      _webConnectionController.add(ZebraConnectionState.connected);
      return;
    }
    return _methods.invokeMethod('connect', {'name': name});
  }

  Future<void> disconnect() async {
    if (kIsWeb) {
      await stopInventory();
      _webCurrentState = ZebraConnectionState.disconnected;
      _webConnectionController.add(ZebraConnectionState.disconnected);
      return;
    }
    return _methods.invokeMethod('disconnect');
  }

  /// Starts continuous inventory (multi-tag) reads. Tags stream via
  /// [tagStream] as they're read.
  Future<void> startInventory() async {
    if (kIsWeb) {
      if (_webCurrentState != ZebraConnectionState.connected) {
        throw StateError(
          'Cannot start inventory: No simulated reader connected',
        );
      }
      _webIsInventoryActive = true;
      _webTriggerController.add(ZebraTriggerState.pressed);
      _webInventoryTimer?.cancel();

      final random = math.Random();
      final mockEpcs = List.generate(
        15,
        (i) => 'E2801191A${(i + 1).toString().padLeft(6, '0')}000000',
      );

      _webInventoryTimer = Timer.periodic(
        const Duration(milliseconds: 300),
        (_) {
          if (!_webIsInventoryActive) return;
          final selectedEpc = mockEpcs[random.nextInt(mockEpcs.length)];
          final rssi = -40 - random.nextInt(35);
          final antennaId = 1 + random.nextInt(2);

          _webTagController.add(
            ZebraTagRead(tagId: selectedEpc, rssi: rssi, antennaId: antennaId),
          );
        },
      );
      return;
    }
    return _methods.invokeMethod('startInventory');
  }

  Future<void> stopInventory() async {
    if (kIsWeb) {
      _webIsInventoryActive = false;
      _webInventoryTimer?.cancel();
      _webInventoryTimer = null;
      _webTriggerController.add(ZebraTriggerState.released);
      return;
    }
    return _methods.invokeMethod('stopInventory');
  }

  /// Runs a single inventory pass and returns everything read within
  /// [timeout], deduplicated by tag ID.
  Future<List<ZebraTagRead>> readAllTagsOnce({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (kIsWeb) {
      if (_webCurrentState != ZebraConnectionState.connected) {
        throw StateError('Cannot read tags: No simulated reader connected');
      }
      await startInventory();
      await Future<void>.delayed(timeout);
      await stopInventory();

      final mockTags = [
        const ZebraTagRead(
          tagId: 'E2801191A000001000000',
          rssi: -52,
          antennaId: 1,
        ),
        const ZebraTagRead(
          tagId: 'E2801191A000002000000',
          rssi: -61,
          antennaId: 1,
        ),
        const ZebraTagRead(
          tagId: 'E2801191A000003000000',
          rssi: -48,
          antennaId: 2,
        ),
      ];
      return mockTags;
    }
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
  Stream<ZebraTagRead> get tagStream {
    if (kIsWeb) {
      return _webTagController.stream;
    }
    return _tagStream ??= _tagEvents
        .receiveBroadcastStream()
        .map((event) => ZebraTagRead.fromMap(event as Map<dynamic, dynamic>));
  }

  /// Emits reader connection state changes.
  Stream<ZebraConnectionState> get connectionState {
    if (kIsWeb) {
      return _webConnectionController.stream;
    }
    return _connectionState ??= _connectionEvents.receiveBroadcastStream().map((
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
  }

  /// Emits physical trigger press/release events from the sled's handle.
  /// The native side auto-starts/stops inventory on these, but the app can
  /// also observe them to drive UI (e.g. a "scanning..." indicator).
  Stream<ZebraTriggerState> get triggerState {
    if (kIsWeb) {
      return _webTriggerController.stream;
    }
    return _triggerState ??= _triggerEvents.receiveBroadcastStream().map(
      (event) =>
          event == 'pressed'
              ? ZebraTriggerState.pressed
              : ZebraTriggerState.released,
    );
  }
}

/// Utility for sending ZPL print and RFID encoding jobs to Zebra network printers
/// (such as ZD500R) over TCP/IP (Port 9100).
class ZebraNetworkPrinter {
  ZebraNetworkPrinter._();

  static final ZebraNetworkPrinter instance = ZebraNetworkPrinter._();

  static const MethodChannel _methods = MethodChannel(
    'zebra_rfid_reader/methods',
  );

  /// Tests TCP connection to Zebra printer at [ip]:[port].
  Future<bool> testConnection({
    String ip = '192.168.0.252',
    int port = 9100,
  }) async {
    if (kIsWeb) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return true;
    }
    try {
      final bool? result = await _methods.invokeMethod<bool>(
        'testPrinterConnection',
        {'ip': ip, 'port': port},
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Sends raw ZPL data to Zebra network printer at [ip]:[port].
  Future<bool> sendZpl({
    required String zpl,
    String ip = '192.168.0.252',
    int port = 9100,
  }) async {
    if (kIsWeb) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      return true;
    }
    try {
      final bool? result = await _methods.invokeMethod<bool>(
        'sendZplToPrinter',
        {'ip': ip, 'port': port, 'zpl': zpl},
      );
      return result ?? false;
    } catch (e) {
      throw StateError('Failed to print ZPL to $ip:$port: $e');
    }
  }

  /// Helper method to format and send a standard RFID tag encoding and label print job.
  Future<bool> printAndEncodeRfidLabel({
    required String epcTagData,
    required String itemTitle,
    String ip = '192.168.0.252',
    int port = 9100,
  }) async {
    final String zpl = '''
^XA
^FO50,50^A0N,40,40^FD$itemTitle^FS
^FO50,110^A0N,30,30^FDEPC: $epcTagData^FS
^RFW,H^FD$epcTagData^FS
^XZ
''';
    return sendZpl(zpl: zpl, ip: ip, port: port);
  }
}


