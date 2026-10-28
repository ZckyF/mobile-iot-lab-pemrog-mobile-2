import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

const serviceUuid = '12345678-1234-5678-1234-56789abcdef0';
const ledUuid = '12345678-1234-5678-1234-56789abcdef1';
const sensorUuid = '12345678-1234-5678-1234-56789abcdef2';

class BlePage extends StatefulWidget {
  const BlePage({super.key});

  @override
  State<BlePage> createState() => BlePageState();
}

class BlePageState extends State<BlePage> {
  List<ScanResult> results = [];
  BluetoothDevice? _device;
  BluetoothCharacteristic? _ledChar;
  StreamSubscription? _scanSub, _notifySub, _connSub;
  bool _scanning = false;
  bool _ledon = false;
  String _suhu = '-', _hum = '-';
  String _status = 'Belum terhubung';
  String _latBle = '-';

  Future<void> _scan() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final adapter = await FlutterBluePlus.adapterState.first;
    if (adapter != BluetoothAdapterState.on) {
      setState(() => _status = 'Aktifkan Bluetooth terlebih dahulu');
      return;
    }

    setState(() {
      results = [];
      _scanning = true;
      _status = 'Memindai perangkat...';
    });

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((r) {
      if (mounted) setState(() => results = r);
    });

    await FlutterBluePlus.startScan(
      withServices: [Guid(serviceUuid)],
      timeout: const Duration(seconds: 6),
    );

    if (mounted) {
      setState(() {
        _scanning = false;
        _status = 'Pemindaian selesai';
      });
    }
  }

  Future<void> _connect(BluetoothDevice d) async {
    await FlutterBluePlus.stopScan();
    try {
      await d.connect(timeout: const Duration(seconds: 10));
    } catch (e) {
      setState(() => _status = 'Gagal terhubung: $e');
      return;
    }

    _connSub = d.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected && mounted) {
        setState(() {
          _status = 'Terputus';
          _device = null;
          _ledChar = null;
        });
      }
    });

    final services = await d.discoverServices();
    for (final s in services) {
      if (s.uuid != Guid(serviceUuid)) continue;
      for (final c in s.characteristics) {
        if (c.uuid == Guid(ledUuid)) _ledChar = c;
        if (c.uuid == Guid(sensorUuid)) {
          await c.setNotifyValue(true);
          _notifySub = c.onValueReceived.listen((v) {
            final p = utf8.decode(v).split(';');
            if (p.length == 2 && mounted) {
              setState(() {
                _suhu = p[0];
                _hum = p[1];
              });
            }
          });
        }
      }
    }

    setState(() {
      _device = d;
      _status = 'Terhubung ke ${d.platformName.isEmpty ? d.remoteId : d.platformName}';
    });
  }

  Future<void> _setLed(bool on) async {
    await _ledChar?.write([on ? 1 : 0]);
    setState(() => _ledon = on);
  }

  Future<void> _disconnect() async {
    await _device?.disconnect();
  }

  Future<void> _measureLatency() async {
    if (_ledChar == null) return;
    final samples = <int>[];
    for (var i = 0; i < 10; i++) {
      final sw = Stopwatch()..start();
      await _ledChar!.write([i.isEven ? 1 : 0]);
      sw.stop();
      samples.add(sw.elapsedMilliseconds);
      await Future.delayed(const Duration(milliseconds: 500));
    }
    final avg = samples.reduce((a, b) => a + b) / samples.length;
    setState(() => _latBle =
        'rata-rata ${avg.toStringAsFixed(0)} ms (min ${samples.reduce(min)}, maks ${samples.reduce(max)})');
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _notifySub?.cancel();
    _connSub?.cancel();
    _device?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _device != null;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('BLE Controller (Teal Theme)',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.teal)),
          const SizedBox(height: 8),
          Text(_status, style: const TextStyle(color: Colors.black87)),
          const SizedBox(height: 12),
          if (!connected) ...[
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.teal,
                foregroundColor: Colors.white,
              ),
              onPressed: _scanning ? null : _scan,
              icon: const Icon(Icons.search),
              label: Text(_scanning ? 'Memindai...' : 'Scan perangkat'),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView(
                children: results.map((r) {
                  final name = r.device.platformName.isEmpty
                      ? r.device.remoteId.str
                      : r.device.platformName;
                  return Card(
                    elevation: 2,
                    child: ListTile(
                      leading: const Icon(Icons.bluetooth, color: Colors.teal),
                      title: Text(name),
                      subtitle: Text('RSSI ${r.rssi} dBm'),
                      onTap: () => _connect(r.device),
                    ),
                  );
                }).toList(),
              ),
            ),
          ] else ...[
            SwitchListTile(
              activeColor: Colors.teal,
              title: const Text('Kontrol LED (BLE)', style: TextStyle(fontWeight: FontWeight.w600)),
              value: _ledon,
              onChanged: _setLed,
            ),
            Card(
              color: Colors.teal.shade50,
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: ListTile(
                  leading: const Icon(Icons.thermostat, color: Colors.teal, size: 40),
                  title: Text('Suhu: $_suhu °C', style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('Kelembapan: $_hum %'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.amber.shade700, foregroundColor: Colors.white),
              onPressed: _measureLatency,
              icon: const Icon(Icons.timer),
              label: const Text('Ukur Latensi BLE (10x)'),
            ),
            const SizedBox(height: 6),
            Text('Latensi: $_latBle', style: const TextStyle(fontSize: 13, color: Colors.grey)),
            const Spacer(),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
              onPressed: _disconnect,
              icon: const Icon(Icons.logout),
              label: const Text('Putuskan Koneksi BLE'),
            ),
          ],
        ],
      ),
    );
  }
}