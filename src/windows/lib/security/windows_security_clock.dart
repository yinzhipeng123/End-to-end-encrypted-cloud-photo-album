import 'package:encrypted_photo_shared/security/reverification_gate.dart';
import 'package:encrypted_photo_app/security/windows_data_protection.dart';

final class WindowsSecurityClock implements SecurityClock {
  WindowsSecurityClock(this.platform);
  final WindowsDataProtection platform;
  @override
  int utcMilliseconds() => DateTime.now().toUtc().millisecondsSinceEpoch;
  @override
  int monotonicMilliseconds() => platform.monotonicMilliseconds();
}
