import 'package:test/test.dart';
import 'package:tlw_control_plane/src/auth.dart';

void main() {
  group('AuthService', () {
    test('sha256Hex: vettore noto ("abc")', () {
      expect(
        AuthService.sha256Hex('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('randomHex32: 64 hex, valori distinti', () {
      final a = AuthService.randomHex32();
      final b = AuthService.randomHex32();
      expect(a, hasLength(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(a), isTrue);
      expect(a == b, isFalse);
    });

    test('randomHex16: 32 hex', () {
      final id = AuthService.randomHex16();
      expect(id, hasLength(32));
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(id), isTrue);
    });

    test('constantTimeEquals: uguali, case-insensitive, diverse, lunghezze', () {
      expect(AuthService.constantTimeEquals('aabb', 'aabb'), isTrue);
      expect(AuthService.constantTimeEquals('AABB', 'aabb'), isTrue);
      expect(AuthService.constantTimeEquals('aabb', 'aabc'), isFalse);
      expect(AuthService.constantTimeEquals('aabb', 'aab'), isFalse);
    });

    test('isHex64 / isHex32: lunghezze e caratteri', () {
      expect(AuthService.isHex64('a' * 64), isTrue);
      expect(AuthService.isHex64('a' * 63), isFalse);
      expect(AuthService.isHex64('g' * 64), isFalse);
      expect(AuthService.isHex32('f' * 32), isTrue);
      expect(AuthService.isHex32('f' * 31), isFalse);
    });
  });
}
