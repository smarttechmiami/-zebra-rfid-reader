import 'package:flutter/material.dart';
import 'package:zebra_rfid_reader/zebra_rfid_reader.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    home: RFIDoraExampleApp(),
    debugShowCheckedModeBanner: false,
  ));
}

class RFIDoraExampleApp extends StatefulWidget {
  const RFIDoraExampleApp({super.key});

  @override
  State<RFIDoraExampleApp> createState() => _RFIDoraExampleAppState();
}

class _RFIDoraExampleAppState extends State<RFIDoraExampleApp> {
  final TextEditingController _printerIpController =
      TextEditingController(text: '192.168.0.252');
  final TextEditingController _tagEpcController =
      TextEditingController(text: 'E2801191A000001000000');
  final TextEditingController _itemLabelController =
      TextEditingController(text: 'Inventory Item #1042');

  ZebraConnectionState _readerState = ZebraConnectionState.disconnected;
  ZebraTriggerState _triggerState = ZebraTriggerState.released;

  final List<ZebraTagRead> _scannedTags = [];
  List<ZebraReaderInfo> _availableReaders = [];
  String? _connectedReaderName;

  bool _isScanning = false;
  String _printerStatus = 'Ready to test';

  @override
  void initState() {
    super.initState();
    _loadSavedPrinterIp();
    _listenToReaderStreams();
    _fetchReaders();
  }

  Future<void> _loadSavedPrinterIp() async {
    final savedIp = await ZebraNetworkPrinter.instance.getSavedIp();
    setState(() {
      _printerIpController.text = savedIp;
    });
  }

  void _listenToReaderStreams() {
    ZebraRfidReader.instance.connectionState.listen((state) {
      setState(() {
        _readerState = state;
      });
    });

    ZebraRfidReader.instance.triggerState.listen((state) {
      setState(() {
        _triggerState = state;
      });
    });

    ZebraRfidReader.instance.tagStream.listen((tag) {
      setState(() {
        if (!_scannedTags.any((t) => t.tagId == tag.tagId)) {
          _scannedTags.insert(0, tag);
        }
      });
    });
  }

  Future<void> _fetchReaders() async {
    final readers = await ZebraRfidReader.instance.availableReaders();
    setState(() {
      _availableReaders = readers;
    });
  }

  Future<void> _connectReader(String name) async {
    try {
      await ZebraRfidReader.instance.connect(name);
      setState(() {
        _connectedReaderName = name;
      });
    } catch (e) {
      _showSnackBar('Reader Connect Error: $e');
    }
  }

  Future<void> _toggleInventory() async {
    if (_isScanning) {
      await ZebraRfidReader.instance.stopInventory();
      setState(() => _isScanning = false);
    } else {
      await ZebraRfidReader.instance.startInventory();
      setState(() => _isScanning = true);
    }
  }

  Future<void> _testPrinterConnection() async {
    final ip = _printerIpController.text.trim();
    setState(() => _printerStatus = 'Testing TCP connection to $ip:9100...');

    // Save IP permanently to SharedPreferences
    await ZebraNetworkPrinter.instance.savePrinterConfig(ip: ip);

    final success = await ZebraNetworkPrinter.instance.testConnection(ip: ip);
    setState(() {
      _printerStatus = success
          ? '✅ Connected! ZD500R Printer Online at $ip:9100'
          : '❌ Connection Failed to $ip:9100';
    });
  }

  Future<void> _printAndEncodeLabel() async {
    final ip = _printerIpController.text.trim();
    final epc = _tagEpcController.text.trim();
    final label = _itemLabelController.text.trim();

    setState(() => _printerStatus = 'Sending ZPL Print & Encode Job...');

    await ZebraNetworkPrinter.instance.savePrinterConfig(ip: ip);

    try {
      final success = await ZebraNetworkPrinter.instance.printAndEncodeRfidLabel(
        ip: ip,
        port: 9100,
        epcTagData: epc,
        itemTitle: label,
      );
      setState(() {
        _printerStatus = success
            ? '✅ Label Printed & Tag Encoded on ZD500R!'
            : '❌ Print Failed';
      });
    } catch (e) {
      setState(() {
        _printerStatus = '❌ Print Error: $e';
      });
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RFIDora — Zebra Control Panel'),
        backgroundColor: Colors.indigo,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchReaders,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Section 1: Zebra RFID Reader
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.nfc, color: Colors.indigo, size: 28),
                        const SizedBox(width: 8),
                        const Text(
                          'Zebra RFID Reader Sled',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        Chip(
                          label: Text(_readerState.name.toUpperCase()),
                          backgroundColor:
                              _readerState == ZebraConnectionState.connected
                                  ? Colors.green.shade100
                                  : Colors.grey.shade200,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _connectedReaderName != null
                          ? 'Connected to: $_connectedReaderName'
                          : 'No reader connected',
                      style: TextStyle(color: Colors.grey.shade700),
                    ),
                    if (_availableReaders.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      DropdownButton<String>(
                        isExpanded: true,
                        hint: const Text('Select Zebra Reader'),
                        value: _connectedReaderName,
                        items: _availableReaders.map((r) {
                          return DropdownMenuItem(
                            value: r.name,
                            child: Text(r.name),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) _connectReader(val);
                        },
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            icon: Icon(_isScanning
                                ? Icons.stop
                                : Icons.play_arrow),
                            label: Text(_isScanning
                                ? 'Stop Scanning'
                                : 'Start Scan'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _isScanning
                                  ? Colors.red
                                  : Colors.indigo,
                            ),
                            onPressed: _readerState ==
                                    ZebraConnectionState.connected
                                ? _toggleInventory
                                : null,
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: () {
                            setState(() => _scannedTags.clear());
                          },
                          child: const Text('Clear Tags'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Section 2: Scanned RFID Tags List
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Scanned RFID Tags',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Badge(
                          label: Text('${_scannedTags.length}'),
                          backgroundColor: Colors.indigo,
                        ),
                      ],
                    ),
                    const Divider(),
                    _scannedTags.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Text('No RFID tags scanned yet.'),
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _scannedTags.length,
                            itemBuilder: (ctx, idx) {
                              final tag = _scannedTags[idx];
                              return ListTile(
                                leading: const Icon(Icons.qr_code_2),
                                title: Text(
                                  tag.tagId,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text(
                                  'RSSI: ${tag.rssi} dBm | Antenna: ${tag.antennaId}',
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.print),
                                  onPressed: () {
                                    _tagEpcController.text = tag.tagId;
                                    _printAndEncodeLabel();
                                  },
                                ),
                              );
                            },
                          ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Section 3: Zebra ZD500R Network Printer
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.print, color: Colors.indigo, size: 28),
                        SizedBox(width: 8),
                        Text(
                          'Zebra ZD500R Network Printer',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _printerIpController,
                      decoration: const InputDecoration(
                        labelText: 'Printer IP Address (Port 9100)',
                        prefixIcon: Icon(Icons.network_ping),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _itemLabelController,
                      decoration: const InputDecoration(
                        labelText: 'Item Title / Label Text',
                        prefixIcon: Icon(Icons.label),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _tagEpcController,
                      decoration: const InputDecoration(
                        labelText: 'RFID EPC Data to Encode',
                        prefixIcon: Icon(Icons.nfc),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _printerStatus,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _printerStatus.startsWith('✅')
                            ? Colors.green
                            : _printerStatus.startsWith('❌')
                                ? Colors.red
                                : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.network_check),
                            label: const Text('Test Connection'),
                            onPressed: _testPrinterConnection,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.print),
                            label: const Text('Print & Encode'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.indigo,
                            ),
                            onPressed: _printAndEncodeLabel,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
