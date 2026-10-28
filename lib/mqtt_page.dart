import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

const kelompok = 'kel5';
const host = 'broker.emqx.io';
const tSensor = 'polnes/oit/$kelompok/sensor';
const tLed = 'polnes/oit/$kelompok/led';
const tLedState = 'polnes/oit/$kelompok/led/state';
const tStatus = 'polnes/oit/$kelompok/status';

class MqttPage extends StatefulWidget {
  const MqttPage({super.key});

  @override
  State<MqttPage> createState() => _MqttPageState();
}

class _MqttPageState extends State<MqttPage> {
  MqttServerClient? _client;
  bool _connected = false;
  bool _ledon = false;
  String _suhu = '-', _hum = '-', _device = 'tidak diketahui';
  String _status = 'Belum terhubung';
  String _latMqtt = '-';
  Completer<void>? _waiting;
  String _expect = '';

  Future<void> _connect() async {
    final id = 'flutter-$kelompok-${DateTime.now().millisecondsSinceEpoch}';
    final c = MqttServerClient(host, id);
    c.port = 1883;
    c.keepAlivePeriod = 30;
    c.logging(on: false);
    c.onDisconnected = _onDisconnected;
    c.connectionMessage = MqttConnectMessage().withClientIdentifier(id).startClean();

    setState(() => _status = 'Menghubungkan ke broker...');

    try {
      await c.connect();
    } catch (e) {
      c.disconnect();
      setState(() => _status = 'Gagal: $e');
      return;
    }

    c.updates!.listen(_onMessage);
    c.subscribe(tSensor, MqttQos.atMostOnce);
    c.subscribe(tLedState, MqttQos.atLeastOnce);
    c.subscribe(tStatus, MqttQos.atLeastOnce);

    setState(() {
      _client = c;
      _connected = true;
      _status = 'Terhubung ke $host';
    });
  }

  void _onMessage(List<MqttReceivedMessage<MqttMessage>> events) {
    final msg = events[0].payload as MqttPublishMessage;
    final text = MqttPublishPayload.bytesToStringAsString(msg.payload.message);
    final topic = events[0].topic;
    if (!mounted) return;

    setState(() {
      if (topic == tSensor) {
        final j = jsonDecode(text);
        _suhu = j['suhu'].toString();
        _hum = j['hum'].toString();
      } else if (topic == tLedState) {
        _ledon = text == 'ON';
        if (_waiting != null && !_waiting!.isCompleted && text == _expect) {
          _waiting!.complete();
        }
      } else if (topic == tStatus) {
        _device = text;
      }
    });
  }

  void _onDisconnected() {
    if (!mounted) return;
    setState(() {
      _connected = false;
      _status = 'Terputus dari broker';
    });
  }

  void _publish(String topic, String text) {
    final b = MqttClientPayloadBuilder()..addString(text);
    _client?.publishMessage(topic, MqttQos.atLeastOnce, b.payload!);
  }

  Future<void> _measureLatency() async {
    final samples = <int>[];
    for (var i = 0; i < 10; i++) {
      final cmd = i.isEven ? 'ON' : 'OFF';
      _expect = cmd;
      _waiting = Completer<void>();
      final sw = Stopwatch()..start();
      _publish(tLed, cmd);
      try {
        await _waiting!.future.timeout(const Duration(seconds: 3));
        sw.stop();
        samples.add(sw.elapsedMilliseconds);
      } on TimeoutException {
        // Sampel dibuang jika timeout
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }

    if (samples.isEmpty) {
      setState(() => _latMqtt = 'tidak ada respons');
      return;
    }

    final avg = samples.reduce((a, b) => a + b) / samples.length;
    setState(() => _latMqtt =
        'rata-rata ${avg.toStringAsFixed(0)} ms (min ${samples.reduce(min)}, maks ${samples.reduce(max)}, ${samples.length}/10)');
  }

  @override
  void dispose() {
    _client?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('MQTT Controller (Amber Theme)',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
          const SizedBox(height: 8),
          Text(_status, style: const TextStyle(color: Colors.black87)),
          const SizedBox(height: 12),
          if (!_connected)
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange.shade800,
                foregroundColor: Colors.white,
              ),
              onPressed: _connect,
              icon: const Icon(Icons.cloud_upload),
              label: const Text('Hubungkan ke MQTT'),
            )
          else ...[
            Chip(
              avatar: const Icon(Icons.info, color: Colors.white),
              backgroundColor: Colors.orange.shade700,
              label: Text('Status Perangkat: $_device', style: const TextStyle(color: Colors.white)),
            ),
            SwitchListTile(
              activeColor: Colors.orange.shade800,
              title: const Text('LED (Kondisi Nyata ESP32)', style: TextStyle(fontWeight: FontWeight.w600)),
              value: _ledon,
              onChanged: (v) => _publish(tLed, v ? 'ON' : 'OFF'),
            ),
            Card(
              color: Colors.orange.shade50,
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: ListTile(
                  leading: const Icon(Icons.cloud_sync, color: Colors.orange, size: 40),
                  title: Text('Suhu: $_suhu °C', style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('Kelembapan: $_hum %'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white),
              onPressed: _measureLatency,
              icon: const Icon(Icons.speed),
              label: const Text('Ukur Latensi MQTT (10x)'),
            ),
            const SizedBox(height: 6),
            Text('Latensi: $_latMqtt', style: const TextStyle(fontSize: 13, color: Colors.grey)),
            const Spacer(),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () => _client?.disconnect(),
              icon: const Icon(Icons.power_off),
              label: const Text('Putuskan Koneksi MQTT'),
            ),
          ],
        ],
      ),
    );
  }
}