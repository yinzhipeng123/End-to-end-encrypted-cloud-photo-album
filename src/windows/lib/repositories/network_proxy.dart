import 'dart:ffi';
import 'dart:io';

enum ProxyConfigurationProblem { invalid, unsupported, system }

final class ProxyConfigurationException implements Exception {
  const ProxyConfigurationException(this.problem);
  final ProxyConfigurationProblem problem;
  @override
  String toString() => 'ProxyConfigurationException(${problem.name})';
}

final class SystemProxySettings {
  const SystemProxySettings({this.server, this.bypass, this.hasPac = false});
  final String? server;
  final String? bypass;
  final bool hasPac;
}

final class ProxyRoute {
  const ProxyRoute(this.source, {this.host, this.port});
  final String source;
  final String? host;
  final int? port;
  bool get proxied => host != null;
  String get address => host!.contains(':') ? '[$host]:$port' : '$host:$port';
  String get directive => proxied ? 'PROXY $address' : 'DIRECT';
  String get description => proxied ? '$source · HTTP 代理 $address' : source;
}

/// Selects one route per request. Configured proxies never silently fall back
/// to DIRECT on failure. Only parsed host/port are exposed to the UI.
final class NetworkProxyResolver {
  NetworkProxyResolver({
    Map<String, String> Function()? environment,
    SystemProxySettings Function()? systemSettings,
  }) : _environment = environment ?? (() => Platform.environment),
       _systemSettings = systemSettings ?? WindowsProxySettings.read;

  final Map<String, String> Function() _environment;
  final SystemProxySettings Function() _systemSettings;

  ProxyRoute resolve(Uri destination) {
    final environment = _environment();
    String? variable(String name) {
      for (final key in [name, name.toUpperCase()]) {
        final value = environment[key]?.trim();
        if (value != null && value.isNotEmpty) return value;
      }
      return null;
    }

    final explicit =
        variable('${destination.scheme}_proxy') ??
        (destination.scheme == 'https' ? variable('http_proxy') : null) ??
        variable('all_proxy');
    if (explicit != null) {
      if (_bypassed(destination, variable('no_proxy'), system: false)) {
        return const ProxyRoute('直连（环境变量 NO_PROXY 例外）');
      }
      return _parse(explicit, '环境变量');
    }
    // Re-read current-user Windows settings for every new request. A GUI
    // process does not inherit `set` commands executed in an unrelated shell.
    final settings = _systemSettings();
    final server = settings.server?.trim();
    if (server != null && server.isNotEmpty) {
      if (_bypassed(destination, settings.bypass, system: true)) {
        return const ProxyRoute('直连（Windows 系统代理例外）');
      }
      if (!server.contains('=')) return _parse(server, 'Windows 系统设置');
      final protocols = <String, String>{};
      for (final part in server.split(';')) {
        final split = part.indexOf('=');
        if (split < 1)
          throw const ProxyConfigurationException(
            ProxyConfigurationProblem.invalid,
          );
        final protocol = part.substring(0, split).trim().toLowerCase();
        if (protocols.containsKey(protocol)) {
          throw const ProxyConfigurationException(
            ProxyConfigurationProblem.invalid,
          );
        }
        protocols[protocol] = part.substring(split + 1).trim();
      }
      final selected = protocols[destination.scheme];
      if (selected != null) return _parse(selected, 'Windows 系统设置');
      if (protocols.containsKey('socks')) {
        throw const ProxyConfigurationException(
          ProxyConfigurationProblem.unsupported,
        );
      }
      // Windows may explicitly proxy only HTTP and leave HTTPS direct.
      return const ProxyRoute('直连（系统未为 HTTPS 配置代理）');
    }
    if (settings.hasPac) {
      throw const ProxyConfigurationException(
        ProxyConfigurationProblem.unsupported,
      );
    }
    return const ProxyRoute('直连（未检测到环境变量或系统手动代理）');
  }

  static ProxyRoute _parse(String raw, String source) {
    try {
      if (raw.runes.any((r) => r <= 32 || r == 127) || raw.contains(';')) {
        throw const FormatException();
      }
      final uri = Uri.parse(raw.contains('://') ? raw : 'http://$raw');
      if (uri.scheme != 'http') {
        throw const ProxyConfigurationException(
          ProxyConfigurationProblem.unsupported,
        );
      }
      if (uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.path.isNotEmpty && uri.path != '/') ||
          uri.port < 1 ||
          uri.port > 65535 ||
          !RegExp(r'^[a-zA-Z0-9.:-]+$').hasMatch(uri.host)) {
        throw const FormatException();
      }
      return ProxyRoute(source, host: uri.host, port: uri.port);
    } on ProxyConfigurationException {
      rethrow;
    } catch (_) {
      // Never include a raw proxy URL (it may contain credentials).
      throw const ProxyConfigurationException(
        ProxyConfigurationProblem.invalid,
      );
    }
  }

  static bool _bypassed(Uri uri, String? rules, {required bool system}) {
    if (rules == null) return false;
    final host = uri.host.toLowerCase();
    for (var rule in rules.split(system ? ';' : ',')) {
      rule = rule.trim().toLowerCase();
      if (rule.isEmpty) continue;
      if (rule == '*') return true;
      if (system &&
          rule == '<local>' &&
          !host.contains('.') &&
          !host.contains(':'))
        return true;
      if (rule.startsWith('[')) {
        final end = rule.indexOf(']');
        if (end < 0) continue;
        final tail = rule.substring(end + 1);
        if (tail.isNotEmpty && tail != ':${uri.port}') continue;
        if (rule.substring(1, end) == host) return true;
        continue;
      }
      if (':'.allMatches(rule).length == 1) {
        final split = rule.lastIndexOf(':');
        if (int.tryParse(rule.substring(split + 1)) != uri.port) continue;
        rule = rule.substring(0, split);
      }
      if (system) {
        final pattern = rule.split('*').map(RegExp.escape).join('.*');
        if (RegExp('^$pattern\$').hasMatch(host)) return true;
      } else {
        if (rule.startsWith('.')) rule = rule.substring(1);
        if (host == rule || host.endsWith('.$rule')) return true;
      }
    }
    return false;
  }
}

final class _IeProxyConfig extends Struct {
  @Int32()
  external int autoDetect;
  external Pointer<Uint16> autoConfigUrl;
  external Pointer<Uint16> proxy;
  external Pointer<Uint16> proxyBypass;
}

/// Read-only WinHTTP API; no registry mutation, port scan, or subprocess.
abstract final class WindowsProxySettings {
  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static final _winhttp = DynamicLibrary.open('winhttp.dll');
  static final _alloc = _kernel
      .lookupFunction<
        Pointer<Void> Function(Uint32, IntPtr),
        Pointer<Void> Function(int, int)
      >('GlobalAlloc');
  static final _free = _kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('GlobalFree');
  static final _error = _kernel
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  static final _read = _winhttp
      .lookupFunction<
        Int32 Function(Pointer<_IeProxyConfig>),
        int Function(Pointer<_IeProxyConfig>)
      >('WinHttpGetIEProxyConfigForCurrentUser');

  static SystemProxySettings read() {
    if (!Platform.isWindows) return const SystemProxySettings();
    try {
      return _readWindows();
    } on ProxyConfigurationException {
      rethrow;
    } catch (_) {
      throw const ProxyConfigurationException(ProxyConfigurationProblem.system);
    }
  }

  static SystemProxySettings _readWindows() {
    final config = _alloc(
      0x40,
      sizeOf<_IeProxyConfig>(),
    ).cast<_IeProxyConfig>();
    if (config == nullptr)
      throw const ProxyConfigurationException(ProxyConfigurationProblem.system);
    try {
      if (_read(config) == 0) {
        if (_error() == 2) return const SystemProxySettings();
        throw const ProxyConfigurationException(
          ProxyConfigurationProblem.system,
        );
      }
      return SystemProxySettings(
        server: _string(config.ref.proxy),
        bypass: _string(config.ref.proxyBypass),
        hasPac:
            config.ref.autoConfigUrl != nullptr || config.ref.autoDetect != 0,
      );
    } finally {
      for (final pointer in [
        config.ref.proxy,
        config.ref.proxyBypass,
        config.ref.autoConfigUrl,
      ]) {
        if (pointer != nullptr) _free(pointer.cast());
      }
      _free(config.cast());
    }
  }

  static String? _string(Pointer<Uint16> pointer) {
    if (pointer == nullptr) return null;
    for (var length = 0; length < 32768; length++) {
      if (pointer[length] == 0)
        return String.fromCharCodes(pointer.asTypedList(length));
    }
    throw const ProxyConfigurationException(ProxyConfigurationProblem.invalid);
  }
}
