import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypted_photo_shared/security/security_failure.dart';

final class _Blob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> data;
}

final class _Attributes extends Struct {
  @Uint32()
  external int length;
  external Pointer<Void> descriptor;
  @Int32()
  external int inherit;
}

/// Direct Windows user-scope DPAPI. No plugin defaults or plaintext fallback.
/// Native calls never log their inputs; buffers are wiped before LocalFree.
final class WindowsDataProtection {
  WindowsDataProtection() {
    if (!Platform.isWindows) {
      throw const SecurityFailure(SecurityFailureCode.backendUnavailable);
    }
  }

  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static final _advapi = DynamicLibrary.open('advapi32.dll');
  static final _crypt = DynamicLibrary.open('crypt32.dll');
  static final _allocate = _kernel
      .lookupFunction<
        Pointer<Void> Function(Uint32, IntPtr),
        Pointer<Void> Function(int, int)
      >('LocalAlloc');
  static final _free = _kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
  static final _protect = _crypt
      .lookupFunction<
        Int32 Function(
          Pointer<_Blob>,
          Pointer<Uint16>,
          Pointer<_Blob>,
          Pointer<Void>,
          Pointer<Void>,
          Uint32,
          Pointer<_Blob>,
        ),
        int Function(
          Pointer<_Blob>,
          Pointer<Uint16>,
          Pointer<_Blob>,
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<_Blob>,
        )
      >('CryptProtectData');
  static final _unprotect = _crypt
      .lookupFunction<
        Int32 Function(
          Pointer<_Blob>,
          Pointer<Void>,
          Pointer<_Blob>,
          Pointer<Void>,
          Pointer<Void>,
          Uint32,
          Pointer<_Blob>,
        ),
        int Function(
          Pointer<_Blob>,
          Pointer<Void>,
          Pointer<_Blob>,
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<_Blob>,
        )
      >('CryptUnprotectData');
  static final _ticks = _kernel
      .lookupFunction<Uint64 Function(), int Function()>('GetTickCount64');
  static final _diskSpace = _kernel
      .lookupFunction<
        Int32 Function(
          Pointer<Uint16>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        ),
        int Function(
          Pointer<Uint16>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        )
      >('GetDiskFreeSpaceExW');
  static final _createDirectory = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Uint16>, Pointer<_Attributes>),
        int Function(Pointer<Uint16>, Pointer<_Attributes>)
      >('CreateDirectoryW');
  static final _lastError = _kernel
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  static final _driveType = _kernel
      .lookupFunction<
        Uint32 Function(Pointer<Uint16>),
        int Function(Pointer<Uint16>)
      >('GetDriveTypeW');
  static final _fileAttributes = _kernel
      .lookupFunction<
        Uint32 Function(Pointer<Uint16>),
        int Function(Pointer<Uint16>)
      >('GetFileAttributesW');
  static final _convertDescriptor = _advapi
      .lookupFunction<
        Int32 Function(
          Pointer<Uint16>,
          Uint32,
          Pointer<Pointer<Void>>,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Uint16>,
          int,
          Pointer<Pointer<Void>>,
          Pointer<Uint32>,
        )
      >('ConvertStringSecurityDescriptorToSecurityDescriptorW');
  static final _securityInfo = _advapi
      .lookupFunction<
        Uint32 Function(
          Pointer<Uint16>,
          Int32,
          Uint32,
          Pointer<Pointer<Void>>,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
        ),
        int Function(
          Pointer<Uint16>,
          int,
          int,
          Pointer<Pointer<Void>>,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
        )
      >('GetNamedSecurityInfoW');
  static final _descriptorControl = _advapi
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint16>, Pointer<Uint32>),
        int Function(Pointer<Void>, Pointer<Uint16>, Pointer<Uint32>)
      >('GetSecurityDescriptorControl');
  static final _aclInfo = _advapi
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>, Uint32, Int32),
        int Function(Pointer<Void>, Pointer<Void>, int, int)
      >('GetAclInformation');
  static final _getAce = _advapi
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      >('GetAce');
  static final _sidString = _advapi
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Uint16>>),
        int Function(Pointer<Void>, Pointer<Pointer<Uint16>>)
      >('ConvertSidToStringSidW');
  static final _process = _kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetCurrentProcess',
      );
  static final _openToken = _advapi
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      >('OpenProcessToken');
  static final _tokenInfo = _advapi
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Int32,
          Pointer<Void>,
          Uint32,
          Pointer<Uint32>,
        ),
        int Function(Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>)
      >('GetTokenInformation');
  static final _closeHandle = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  static final _moveFile = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Uint16>, Pointer<Uint16>, Uint32),
        int Function(Pointer<Uint16>, Pointer<Uint16>, int)
      >('MoveFileExW');
  String? _userSid;

  Pointer<T> _alloc<T extends NativeType>(int size) {
    final pointer = _allocate(0x40, size); // LMEM_ZEROINIT, fixed allocation.
    if (pointer == nullptr) {
      throw const SecurityFailure(SecurityFailureCode.backendFailure);
    }
    return pointer.cast<T>();
  }

  void _release(Pointer pointer, int bytes) {
    if (pointer == nullptr) return;
    if (bytes > 0)
      pointer.cast<Uint8>().asTypedList(bytes).fillRange(0, bytes, 0);
    _free(pointer.cast<Void>());
  }

  Pointer<Uint16> _wide(String value) {
    if (value.contains('\x00')) {
      throw const SecurityFailure(SecurityFailureCode.invalidLength);
    }
    final pointer = _alloc<Uint16>((value.length + 1) * 2);
    pointer.asTypedList(value.length).setAll(0, value.codeUnits);
    return pointer;
  }

  String _readWide(Pointer<Uint16> pointer, {int limit = 32768}) {
    for (var length = 0; length < limit; length++) {
      if (pointer[length] == 0)
        return String.fromCharCodes(pointer.asTypedList(length));
    }
    throw const SecurityFailure(SecurityFailureCode.backendFailure);
  }

  Uint8List seal(Uint8List clear, Uint8List binding) =>
      _cryptBytes(clear, binding, false);
  Uint8List unseal(Uint8List sealed, Uint8List binding) =>
      _cryptBytes(sealed, binding, true);

  Uint8List _cryptBytes(Uint8List input, Uint8List binding, bool opening) {
    if (input.isEmpty ||
        input.length > 1024 * 1024 ||
        binding.isEmpty ||
        binding.length > 4096) {
      throw const SecurityFailure(SecurityFailureCode.invalidLength);
    }
    final source = _alloc<_Blob>(sizeOf<_Blob>());
    final entropy = _alloc<_Blob>(sizeOf<_Blob>());
    final output = _alloc<_Blob>(sizeOf<_Blob>());
    try {
      source.ref
        ..length = input.length
        ..data = _alloc<Uint8>(input.length);
      source.ref.data.asTypedList(input.length).setAll(0, input);
      entropy.ref
        ..length = binding.length
        ..data = _alloc<Uint8>(binding.length);
      entropy.ref.data.asTypedList(binding.length).setAll(0, binding);
      // CRYPTPROTECT_UI_FORBIDDEN only. Never CRYPTPROTECT_LOCAL_MACHINE.
      final ok = opening
          ? _unprotect(source, nullptr, entropy, nullptr, nullptr, 1, output)
          : _protect(source, nullptr, entropy, nullptr, nullptr, 1, output);
      if (ok == 0) {
        throw SecurityFailure(
          opening
              ? SecurityFailureCode.authenticationFailed
              : SecurityFailureCode.backendFailure,
        );
      }
      if (output.ref.length == 0 ||
          output.ref.length > 1024 * 1024 ||
          output.ref.data == nullptr) {
        throw const SecurityFailure(SecurityFailureCode.backendFailure);
      }
      return Uint8List.fromList(output.ref.data.asTypedList(output.ref.length));
    } finally {
      _release(source.ref.data, source.ref.length);
      _release(entropy.ref.data, entropy.ref.length);
      _release(output.ref.data, output.ref.length);
      _release(source, sizeOf<_Blob>());
      _release(entropy, sizeOf<_Blob>());
      _release(output, sizeOf<_Blob>());
    }
  }

  int monotonicMilliseconds() => _ticks();

  int availableDiskBytes(String directory) {
    validatePrivatePath(directory, directory: true);
    final wide = _wide(directory);
    final available = _alloc<Uint64>(8);
    try {
      if (_diskSpace(wide, available, nullptr, nullptr) == 0 ||
          available.value < 0) {
        throw const SecurityFailure(SecurityFailureCode.storageFailure);
      }
      return available.value;
    } finally {
      _release(wide, (directory.length + 1) * 2);
      _release(available, 8);
    }
  }

  String _sid(Pointer<Void> sid) {
    final string = _alloc<Pointer<Uint16>>(sizeOf<Pointer>());
    try {
      if (_sidString(sid, string) == 0)
        throw const SecurityFailure(SecurityFailureCode.storageFailure);
      return _readWide(string.value, limit: 256);
    } finally {
      _release(string.value, 0);
      _release(string, sizeOf<Pointer>());
    }
  }

  String get currentUserSid => _userSid ??= _loadSid();
  String _loadSid() {
    final token = _alloc<Pointer<Void>>(sizeOf<Pointer>());
    final count = _alloc<Uint32>(4);
    Pointer<Void> info = nullptr;
    try {
      if (_openToken(_process(), 8, token) == 0)
        throw const SecurityFailure(SecurityFailureCode.backendFailure);
      _tokenInfo(token.value, 1, nullptr, 0, count);
      if (count.value == 0 || count.value > 65536)
        throw const SecurityFailure(SecurityFailureCode.backendFailure);
      info = _alloc<Void>(count.value);
      if (_tokenInfo(token.value, 1, info, count.value, count) == 0)
        throw const SecurityFailure(SecurityFailureCode.backendFailure);
      return _sid(info.cast<Pointer<Void>>().value);
    } finally {
      if (token.value != nullptr) _closeHandle(token.value);
      _release(info, count.value);
      _release(count, 4);
      _release(token, sizeOf<Pointer>());
    }
  }

  /// Creates only the requested App-owned directory, with a protected DACL.
  /// Existing directories are checked, never silently made less restrictive.
  void preparePrivateDirectory(String path, {bool requireNew = false}) {
    // Resolve GetLastError before CreateDirectoryW: lazy symbol lookup itself
    // can replace the thread's last-error value on the first existing path.
    final lastError = _lastError;
    final wide = _wide(path);
    final sddl = _wide('D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;$currentUserSid)');
    final descriptor = _alloc<Pointer<Void>>(sizeOf<Pointer>());
    final attributes = _alloc<_Attributes>(sizeOf<_Attributes>());
    try {
      if (_convertDescriptor(sddl, 1, descriptor, nullptr) == 0)
        throw const SecurityFailure(SecurityFailureCode.storageFailure);
      attributes.ref
        ..length = sizeOf<_Attributes>()
        ..descriptor = descriptor.value
        ..inherit = 0;
      if (_createDirectory(wide, attributes) == 0) {
        final error = lastError();
        if (error == 183 && requireNew) {
          throw const SecurityFailure(SecurityFailureCode.alreadyExists);
        }
        if (error != 183) {
          throw const SecurityFailure(SecurityFailureCode.storageFailure);
        }
      }
      validatePrivatePath(path, directory: true);
    } finally {
      _release(wide, (path.length + 1) * 2);
      _release(sddl, 0);
      _release(descriptor.value, 0);
      _release(descriptor, sizeOf<Pointer>());
      _release(attributes, sizeOf<_Attributes>());
    }
  }

  /// Custom storage must stay on a local drive and must not traverse junctions
  /// or other reparse points. Do not change permissions on user-owned parents.
  void validateLocalDirectoryChain(String path) {
    if (!RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) || path.contains('\x00')) {
      throw const SecurityFailure(SecurityFailureCode.storageFailure);
    }
    final root = '${path.substring(0, 2)}\\';
    final wideRoot = _wide(root);
    try {
      final type = _driveType(wideRoot);
      if (type != 2 && type != 3) {
        throw const SecurityFailure(SecurityFailureCode.storageFailure);
      }
    } finally {
      _release(wideRoot, (root.length + 1) * 2);
    }
    var current = Directory(path).absolute;
    while (true) {
      final wide = _wide(current.path);
      try {
        final flags = _fileAttributes(wide);
        if (flags == 0xffffffff || flags & 0x10 == 0 || flags & 0x400 != 0) {
          throw const SecurityFailure(SecurityFailureCode.storageFailure);
        }
      } finally {
        _release(wide, (current.path.length + 1) * 2);
      }
      final parent = current.parent;
      if (parent.path.toLowerCase() == current.path.toLowerCase()) break;
      current = parent;
    }
  }

  /// Rejects reparse points, unprotected root DACLs, and access for other SIDs.
  void validatePrivatePath(String path, {bool directory = false}) {
    final wide = _wide(path);
    final owner = _alloc<Pointer<Void>>(sizeOf<Pointer>());
    final dacl = _alloc<Pointer<Void>>(sizeOf<Pointer>());
    final descriptor = _alloc<Pointer<Void>>(sizeOf<Pointer>());
    final control = _alloc<Uint16>(2);
    final revision = _alloc<Uint32>(4);
    final info = _alloc<Uint32>(12);
    final ace = _alloc<Pointer<Void>>(sizeOf<Pointer>());
    try {
      final flags = _fileAttributes(wide);
      if (flags == 0xffffffff ||
          flags & 0x400 != 0 ||
          (directory && flags & 0x10 == 0)) {
        throw const SecurityFailure(SecurityFailureCode.storageFailure);
      }
      if (_securityInfo(
                wide,
                1,
                5,
                owner,
                nullptr,
                dacl,
                nullptr,
                descriptor,
              ) !=
              0 ||
          owner.value == nullptr ||
          dacl.value == nullptr ||
          _sid(owner.value) != currentUserSid ||
          _descriptorControl(descriptor.value, control, revision) == 0 ||
          (directory && control.value & 0x1000 == 0) ||
          _aclInfo(dacl.value, info.cast<Void>(), 12, 2) == 0) {
        throw const SecurityFailure(SecurityFailureCode.storageFailure);
      }
      var hasOwnerAccess = false;
      if (info[0] > 32)
        throw const SecurityFailure(SecurityFailureCode.storageFailure);
      for (var i = 0; i < info[0]; i++) {
        if (_getAce(dacl.value, i, ace) == 0)
          throw const SecurityFailure(SecurityFailureCode.storageFailure);
        final bytes = ace.value.cast<Uint8>();
        if (bytes[0] != 0)
          throw const SecurityFailure(SecurityFailureCode.storageFailure);
        final principal = _sid((bytes + 8).cast<Void>());
        if (principal != currentUserSid && principal != 'S-1-5-18') {
          throw const SecurityFailure(SecurityFailureCode.storageFailure);
        }
        if (principal == currentUserSid &&
            bytes[1] & 8 == 0 &&
            (bytes + 4).cast<Uint32>().value & 0x1f01ff == 0x1f01ff)
          hasOwnerAccess = true;
      }
      if (!hasOwnerAccess)
        throw const SecurityFailure(SecurityFailureCode.storageFailure);
    } finally {
      _release(wide, (path.length + 1) * 2);
      _release(descriptor.value, 0);
      for (final pointer in [owner, dacl, descriptor, ace]) {
        _release(pointer, sizeOf<Pointer>());
      }
      _release(control, 2);
      _release(revision, 4);
      _release(info, 12);
    }
  }

  void replacePrivateFile(String source, String destination) {
    validatePrivatePath(source);
    if (File(destination).existsSync()) validatePrivatePath(destination);
    final from = _wide(source);
    final to = _wide(destination);
    try {
      // Same-directory rename; replace the old sealed file only after flush.
      if (_moveFile(from, to, 0x9) == 0)
        throw const SecurityFailure(SecurityFailureCode.storageFailure);
      validatePrivatePath(destination);
    } finally {
      _release(from, (source.length + 1) * 2);
      _release(to, (destination.length + 1) * 2);
    }
  }
}
