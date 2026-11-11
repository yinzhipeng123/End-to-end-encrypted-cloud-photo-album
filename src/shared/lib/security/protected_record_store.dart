import 'dart:typed_data';

/// Platform-sealed small records. A missing record is never an unlock grant.
abstract interface class ProtectedRecordStore {
  Future<Uint8List?> read(String name, Uint8List binding);
  Future<void> write(String name, Uint8List clear, Uint8List binding);
  Future<void> remove(String name);
}
