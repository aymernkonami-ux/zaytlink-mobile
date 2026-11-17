import 'dart:async';
import 'dart:convert';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const int companionVersion = 2;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final SupabaseClient _client = Supabase.instance.client;
  final TextEditingController _code = TextEditingController();
  String? _deviceId;
  String? _error;
  String? _lastAction;
  bool _loading = true;
  bool _busy = false;
  bool _polling = false;
  bool _locationAllowed = false;
  DateTime? _lastSync;
  String _model = '-';
  String _android = '-';
  String _network = '-';
  String _storage = '-';
  int? _battery;
  Timer? _syncTimer;
  Timer? _commandTimer;

  String get _prefKey => 'device_id_${_client.auth.currentUser?.id}';
  String get _locationKey => 'location_allowed_${_client.auth.currentUser?.id}';

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _commandTimer?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _deviceId = prefs.getString(_prefKey);
    _locationAllowed = prefs.getBool(_locationKey) ?? false;
    if (mounted) setState(() => _loading = false);
    if (_deviceId != null) {
      _startTimers();
      await _sync();
      try {
        await _uploadApps();
      } catch (_) {}
    }
  }

  void _startTimers() {
    _syncTimer?.cancel();
    _commandTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 60), (_) => _sync());
    _commandTimer = Timer.periodic(const Duration(seconds: 5), (_) => _pollCommands());
  }

  Future<void> _setLocationAllowed(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_locationKey, value);
    if (mounted) setState(() => _locationAllowed = value);
  }

  Future<void> _pair() async {
    final raw = _code.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (raw.length != 8) {
      setState(() => _error = 'Enter the 8-character code from the website.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final hash = sha256.convert(utf8.encode(raw)).toString();
      final result = await _client.rpc('redeem_pairing_code', params: {'p_code_hash': hash});
      final id = result as String;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, id);
      await _client.from('activity_logs').insert({
        'user_id': _client.auth.currentUser!.id,
        'device_id': id,
        'action': 'Device paired from the companion app',
      });
      _deviceId = id;
      _code.clear();
      _startTimers();
      await _sync();
      try {
        await _uploadApps();
      } catch (_) {}
    } on PostgrestException catch (e) {
      _error = e.message.contains('Invalid')
          ? 'That code is invalid or has expired. Create a new one on the website.'
          : e.message;
    } catch (_) {
      _error = 'Pairing failed. Check your connection and try again.';
    }
    if (mounted) setState(() => _busy = false);
  }

  String _gb(num bytes) => (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1);

  Future<void> _sync() async {
    final id = _deviceId;
    if (id == null) return;
    try {
      final android = await DeviceInfoPlugin().androidInfo;
      final battery = await Battery().batteryLevel;
      final net = await Connectivity().checkConnectivity();
      final network = net.contains(ConnectivityResult.wifi)
          ? 'Wi-Fi'
          : net.contains(ConnectivityResult.mobile)
              ? 'Mobile data'
              : net.contains(ConnectivityResult.none)
                  ? 'Offline'
                  : 'Other';
      final disk = DiskSpacePlus();
      final freeMb = await disk.getFreeDiskSpace;
      final totalMb = await disk.getTotalDiskSpace;
      final freeBytes = freeMb == null ? null : (freeMb * 1024 * 1024).round();
      final totalBytes = totalMb == null ? null : (totalMb * 1024 * 1024).round();
      final now = DateTime.now();
      final rows = await _client.from('devices').update({
        'model': android.model,
        'android_version': android.version.release,
        'battery_level': battery,
        'network_type': network,
        'storage_free_bytes': freeBytes,
        'storage_total_bytes': totalBytes,
        'companion_version': companionVersion,
        'connection_status': 'CONNECTED',
        'last_seen': now.toUtc().toIso8601String(),
      }).eq('id', id).select('id');
      if (rows.isEmpty) {
        await _clearPairing('This phone was revoked from ZAYTLINK. Pair it again with a new code.');
        return;
      }
      if (!mounted) return;
      setState(() {
        _model = android.model;
        _android = android.version.release;
        _battery = battery;
        _network = network;
        _storage = (freeBytes == null || totalBytes == null) ? '-' : '${_gb(freeBytes)} GB free of ${_gb(totalBytes)} GB';
        _lastSync = now;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not sync. Check your internet connection.');
    }
  }

  Future<int> _uploadApps() async {
    final id = _deviceId;
    if (id == null) return 0;
    final apps = await InstalledApps.getInstalledApps();
    final userId = _client.auth.currentUser!.id;
    final rows = apps
        .map((a) => {'user_id': userId, 'device_id': id, 'package_name': a.packageName, 'app_name': a.name})
        .toList();
    await _client.from('device_apps').delete().eq('device_id', id);
    if (rows.isNotEmpty) await _client.from('device_apps').insert(rows);
    return rows.length;
  }

  Future<Map<String, dynamic>> _locate() async {
    if (!_locationAllowed) throw Exception('Location requests are turned off in the phone app.');
    if (!await Geolocator.isLocationServiceEnabled()) throw Exception('Turn on Location on the phone.');
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      throw Exception('Location permission was denied on the phone.');
    }
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)),
    );
    return {
      'lat': pos.latitude,
      'lng': pos.longitude,
      'accuracy': pos.accuracy,
      'at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<void> _handle(Map<String, dynamic> cmd) async {
    final id = cmd['id'] as String;
    final name = cmd['command'] as String;
    final payload = cmd['payload'] is Map ? Map<String, dynamic>.from(cmd['payload'] as Map) : <String, dynamic>{};
    try {
      Map<String, dynamic> result = {};
      if (name == 'launch_app') {
        final pkg = payload['package'] as String?;
        if (pkg == null || pkg.isEmpty) throw Exception('No app was selected.');
        final ok = await InstalledApps.startApp(pkg);
        if (ok != true) throw Exception('The phone could not open that app.');
        result = {'package': pkg};
        if (mounted) setState(() => _lastAction = 'Opened an app requested from the website');
      } else if (name == 'refresh_apps') {
        result = {'count': await _uploadApps()};
        if (mounted) setState(() => _lastAction = 'Sent your app list to the website');
      } else if (name == 'get_location') {
        result = await _locate();
        if (mounted) setState(() => _lastAction = 'Sent your location to the website');
      } else {
        throw Exception('Unknown request.');
      }
      await _client.from('device_commands').update({'status': 'done', 'result': result}).eq('id', id);
    } catch (e) {
      final text = e.toString().replaceFirst('Exception: ', '');
      await _client.from('device_commands').update({'status': 'failed', 'error': text}).eq('id', id);
    }
  }

  Future<void> _pollCommands() async {
    final id = _deviceId;
    if (id == null || _polling) return;
    _polling = true;
    try {
      final since = DateTime.now().toUtc().subtract(const Duration(minutes: 2)).toIso8601String();
      final rows = await _client
          .from('device_commands')
          .select()
          .eq('device_id', id)
          .eq('status', 'pending')
          .gt('created_at', since)
          .order('created_at')
          .limit(5);
      for (final row in rows) {
        await _handle(Map<String, dynamic>.from(row as Map));
      }
    } catch (_) {
      // Ignore: the next poll will try again.
    } finally {
      _polling = false;
    }
  }

  Future<void> _clearPairing(String? message) async {
    _syncTimer?.cancel();
    _commandTimer?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
    if (!mounted) return;
    setState(() {
      _deviceId = null;
      _lastSync = null;
      _error = message;
    });
  }

  Future<void> _unpair() async {
    final id = _deviceId;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Unpair this phone?'),
        content: const Text('It will show as Disconnected on the website until you pair it again with a new code.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Unpair')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _client.from('devices').update({'connection_status': 'DISCONNECTED'}).eq('id', id);
    } catch (_) {}
    await _clearPairing(null);
  }

  Widget _card(Widget child) => Card(
        color: const Color(0xFF14211B),
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      );

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Color(0xFF91A49A))),
            Flexible(child: Text(value, textAlign: TextAlign.end)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(
        title: const Text('ZAYTLINK', style: TextStyle(letterSpacing: 4, fontSize: 16)),
        backgroundColor: const Color(0xFF101915),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              _syncTimer?.cancel();
              _commandTimer?.cancel();
              await _client.auth.signOut();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) _card(Text(_error!, style: const TextStyle(color: Color(0xFFE8AE48)))),
          if (_deviceId == null)
            _card(Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Pair this phone', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                const SizedBox(height: 8),
                const Text(
                  'On the ZAYTLINK website open My Device, tap Pair a device, and enter the one-time code here.',
                  style: TextStyle(color: Color(0xFF91A49A)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _code,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Pairing code (XXXX-XXXX)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                FilledButton(onPressed: _busy ? null : _pair, child: Text(_busy ? 'Pairing...' : 'Pair this phone')),
              ],
            ))
          else ...[
            _card(Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Connected to ZAYTLINK', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: Color(0xFF35C98B))),
                const SizedBox(height: 8),
                _row('Model', _model),
                _row('Android version', _android),
                _row('Battery', _battery == null ? '-' : '$_battery%'),
                _row('Network', _network),
                _row('Storage', _storage),
                _row('Last sync', _lastSync == null ? 'Not yet' : TimeOfDay.fromDateTime(_lastSync!).format(context)),
                if (_lastAction != null) _row('Last request', _lastAction!),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: _sync, child: const Text('Sync now')),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: _unpair, child: const Text('Unpair this phone')),
                const SizedBox(height: 8),
                const Text(
                  'Keep this app open. It syncs every minute and checks for website requests every few seconds. Background running is not built yet.',
                  style: TextStyle(color: Color(0xFF91A49A), fontSize: 12),
                ),
              ],
            )),
            _card(SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow location requests'),
              subtitle: const Text('Off by default. When on, the website can ask for your location once per request.'),
              value: _locationAllowed,
              onChanged: _setLocationAllowed,
            )),
          ],
          _card(const Text(
            'Shared with your account: model, Android version, battery, network, storage, the list of installed apps, and your location only when you allow it. Camera, files and messages are never accessed.',
            style: TextStyle(color: Color(0xFF91A49A), fontSize: 12),
          )),
        ],
      ),
    );
  }
}
