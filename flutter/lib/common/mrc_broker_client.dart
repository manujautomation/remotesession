// Mendocino Remote Connectivity — operator-side session-broker client.
//
// Deliberately written in Dart rather than Rust. The agent side MUST be Rust (it is the
// enforcement point, in src/mrc_broker.rs), but the operator side is only HTTP plus UI.
// Adding Rust FFI entry points would mean reproducing the pinned flutter_rust_bridge
// 1.80.1 codegen, whose Dart output is not even checked in — a heavy dependency for what
// amounts to four POST requests.
//
// Configuration is read from the signed custom.txt via main_get_hard_option, which is
// already exported to Flutter, so this needs no bridge changes at all.
//
// Flow, per DESIGN.md §5:
//   sign in            -> bearer token, held in memory only
//   request a session  -> one-time ticket, or 429 when a cap is hit
//   heartbeat every 15s-> keeps the slot; silence makes the broker reclaim it
//   end                -> releases the slot immediately

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/platform_model.dart';

const String kMrcBrokerUrlKey = 'mrc-broker-url';
const Duration kMrcTimeout = Duration(seconds: 12);

class MrcSessionTicket {
  MrcSessionTicket(this.sessionToken, this.deviceId, this.heartbeatSec);
  final String sessionToken;
  final String deviceId;
  final int heartbeatSec;
}

class MrcBroker {
  MrcBroker._();
  static final MrcBroker instance = MrcBroker._();

  String? _token;
  String? _actor;
  final Map<String, String> _sessions = {};
  final Map<String, Timer> _heartbeats = {};

  /// Base URL from the baked-in config. Empty means this build is unmanaged.
  String get baseUrl {
    final raw = bind.mainGetHardOption(key: kMrcBrokerUrlKey).trim();
    return raw.replaceAll(RegExp(r'/+$'), '');
  }

  bool get enabled => baseUrl.isNotEmpty;
  bool get isSignedIn => _token != null;
  String? get actor => _actor;

  void signOut() {
    _token = null;
    _actor = null;
    for (final t in _heartbeats.values) {
      t.cancel();
    }
    _heartbeats.clear();
    _sessions.clear();
  }

  Map<String, String> get _authHeaders => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  /// Returns null on success, or a human-readable error.
  Future<String?> login(String username, String password, String totp) async {
    return _authenticate('/auth/login', {
      'username': username,
      'password': password,
      'totp': totp,
    });
  }

  /// Break-glass: a short-lived superadmin token. Every use is audited server-side.
  Future<String?> breakglass(String key, String totp) async {
    return _authenticate('/auth/breakglass', {'key': key, 'totp': totp});
  }

  Future<String?> _authenticate(String path, Map<String, dynamic> body) async {
    if (!enabled) return 'No broker is configured for this build';
    try {
      final resp = await http
          .post(Uri.parse('$baseUrl$path'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(kMrcTimeout);
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _token = data['access_token'] as String?;
        _actor = data['actor'] as String?;
        return _token == null ? 'Malformed response from broker' : null;
      }
      if (resp.statusCode == 401) return 'Invalid credentials';
      return 'Sign-in failed (${resp.statusCode})';
    } on TimeoutException {
      return 'Broker did not respond';
    } catch (e) {
      return 'Cannot reach broker: $e';
    }
  }

  /// Reserve a slot before connecting.
  ///
  /// Returns a ticket on success. On failure the message is suitable for showing to the
  /// operator — a cap breach comes back from the broker already phrased for a human.
  Future<(MrcSessionTicket?, String?)> requestSession(
      String deviceId, String kind) async {
    if (!enabled) return (null, null);
    if (!isSignedIn) return (null, 'Not signed in');

    try {
      final myId = await bind.mainGetMyId();
      final resp = await http
          .post(Uri.parse('$baseUrl/session/request'),
              headers: _authHeaders,
              body: jsonEncode({
                'device_id': deviceId,
                'kind': kind,
                'from_peer_id': myId,
              }))
          .timeout(kMrcTimeout);

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final ticket = MrcSessionTicket(
          data['session_token'] as String,
          data['device_id'] as String,
          (data['heartbeat_interval_sec'] as num?)?.toInt() ?? 15,
        );
        _sessions[deviceId] = ticket.sessionToken;
        _startHeartbeat(deviceId, ticket.heartbeatSec);
        return (ticket, null);
      }

      if (resp.statusCode == 429) {
        return (null, _detail(resp.body) ?? 'Session limit reached');
      }
      if (resp.statusCode == 401) {
        signOut();
        return (null, 'Session expired — sign in again');
      }
      if (resp.statusCode == 404) {
        return (null, 'That machine is not enrolled with the broker');
      }
      return (null, 'Broker refused the session (${resp.statusCode})');
    } on TimeoutException {
      // Fail closed: an unreachable policy engine denies rather than waives.
      return (null, 'Broker did not respond — connection refused');
    } catch (e) {
      return (null, 'Cannot reach broker: $e');
    }
  }

  String? _detail(String body) {
    try {
      return (jsonDecode(body) as Map<String, dynamic>)['detail'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Keeps the slot alive. The broker reclaims it after its TTL of silence, so a client
  /// that dies cannot wedge a user at their session limit.
  void _startHeartbeat(String deviceId, int everySec) {
    _heartbeats.remove(deviceId)?.cancel();
    _heartbeats[deviceId] =
        Timer.periodic(Duration(seconds: everySec), (timer) async {
      final token = _sessions[deviceId];
      if (token == null) {
        timer.cancel();
        return;
      }
      try {
        final resp = await http
            .post(Uri.parse('$baseUrl/session/heartbeat'),
                headers: _authHeaders,
                body: jsonEncode({'session_token': token}))
            .timeout(kMrcTimeout);
        // 410 means the slot is already gone; stop rather than spin.
        if (resp.statusCode == 410 || resp.statusCode == 401) {
          timer.cancel();
          _sessions.remove(deviceId);
          _heartbeats.remove(deviceId);
        }
      } catch (_) {
        // A transient network blip should not drop the slot; the TTL is the backstop.
      }
    });
  }

  /// Release the slot. Best-effort — the broker reclaims it on timeout anyway.
  Future<void> endSession(String deviceId) async {
    _heartbeats.remove(deviceId)?.cancel();
    final token = _sessions.remove(deviceId);
    if (token == null || !enabled || !isSignedIn) return;
    try {
      await http
          .post(Uri.parse('$baseUrl/session/end'),
              headers: _authHeaders,
              body: jsonEncode({'session_token': token}))
          .timeout(kMrcTimeout);
    } catch (_) {
      // Nothing useful to do; the slot frees itself when heartbeats stop.
    }
  }
}
