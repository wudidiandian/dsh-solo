import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../protocol/envelope.dart';

const e2eeDomain = 'dsh-solo/e2ee/1';
List<int> _encode(Object value) => utf8.encode(jsonEncode(value));
String _url64(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');
List<int> decodePairingKey(String text) {
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(text))
    throw const FormatException('Invalid encryption pairing key');
  final bytes = base64Url.decode(base64Url.normalize(text));
  if (bytes.length != 32 || _url64(bytes) != text)
    throw const FormatException('Invalid encryption pairing key');
  return bytes;
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// QR-authenticated ephemeral X25519 exchange. The pairing secret never goes to the relay.
class SecureMobile {
  SecureMobile(this.token, String pairingKey)
    : _psk = decodePairingKey(pairingKey);
  final String token;
  final List<int> _psk;
  final String id = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  SimpleKeyPair? _pair;
  String? _public;
  SecureSession? session;
  List<int> _context([String? agent]) =>
      _encode([e2eeDomain, token, id, _public!, if (agent != null) agent]);
  Future<List<int>> _proof(String label, List<int> context) async =>
      (await Hmac.sha256().calculateMac([
        ...utf8.encode(label),
        ...context,
      ], secretKey: SecretKey(_psk))).bytes;
  Future<Map<String, Object>> hello() async {
    _pair ??= await X25519().newKeyPair();
    _public ??= _url64((await _pair!.extractPublicKey()).bytes);
    return {
      'id': id,
      'publicKey': _public!,
      'proof': _url64(await _proof('mobile:', _context())),
    };
  }

  Future<SecureSession> accept(Map<String, dynamic> welcome) async {
    if (_pair == null || session != null || welcome['id'] != id)
      throw StateError('Invalid encrypted handshake');
    final agent = welcome['publicKey'];
    if (agent is! String || welcome['proof'] is! String)
      throw const FormatException('Invalid encrypted handshake');
    final public = decodePairingKey(agent);
    final context = _context(agent);
    if (!_equal(
      decodePairingKey(welcome['proof'] as String),
      await _proof('agent:', context),
    )) {
      throw StateError('Desktop encryption identity verification failed');
    }
    final shared = await X25519().sharedSecretKey(
      keyPair: _pair!,
      remotePublicKey: SimplePublicKey(public, type: KeyPairType.x25519),
    );
    if ((await shared.extractBytes()).every((b) => b == 0))
      throw StateError('Invalid desktop public key');
    final material = await Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 64,
    ).deriveKey(secretKey: shared, nonce: _psk, info: context);
    final keys = await material.extractBytes();
    final established = SecureSession(
      id,
      keys.sublist(0, 32),
      keys.sublist(32, 64),
    );
    session = established;
    _pair = null;
    return established;
  }
}

class SecureSession {
  SecureSession(this.id, List<int> sendKey, List<int> receiveKey)
    : _sendKey = SecretKey(sendKey),
      _receiveKey = SecretKey(receiveKey);
  final String id;
  final SecretKey _sendKey, _receiveKey;
  final _cipher = AesGcm.with256bits();
  int _sent = 0, _received = 0;
  List<int> _nonce(int counter) {
    final bytes = ByteData(12)..setUint32(8, counter, Endian.big);
    return bytes.buffer.asUint8List();
  }

  Future<Map<String, Object>> seal(Envelope value) async {
    if (_sent >= 0xffffffff)
      throw StateError('Encryption session exhausted; reconnect required');
    final counter = ++_sent;
    final box = await _cipher.encrypt(
      _encode(value.toJson()),
      secretKey: _sendKey,
      nonce: _nonce(counter),
      aad: _encode([e2eeDomain, id, 'm2a', counter]),
    );
    return {
      'counter': counter,
      'ciphertext': base64Encode([...box.cipherText, ...box.mac.bytes]),
    };
  }

  Future<Envelope> open(Map<String, dynamic> packet) async {
    final counter = packet['counter'], encoded = packet['ciphertext'];
    if (counter is! int || counter != _received + 1 || counter > 0xffffffff)
      throw StateError('Replay or out-of-order encrypted message');
    if (encoded is! String || encoded.length > 6 * 1024 * 1024)
      throw const FormatException('Invalid encrypted message');
    final bytes = base64Decode(encoded);
    if (bytes.length < 16 || base64Encode(bytes) != encoded)
      throw const FormatException('Invalid encrypted message');
    final plain = await _cipher.decrypt(
      SecretBox(
        bytes.sublist(0, bytes.length - 16),
        nonce: _nonce(counter),
        mac: Mac(bytes.sublist(bytes.length - 16)),
      ),
      secretKey: _receiveKey,
      aad: _encode([e2eeDomain, id, 'a2m', counter]),
    );
    final env = Envelope.fromJson(
      (jsonDecode(utf8.decode(plain)) as Map).cast<String, dynamic>(),
    );
    if (env.v != 1)
      throw const FormatException('Unsupported encrypted message');
    _received = counter;
    return env;
  }
}
