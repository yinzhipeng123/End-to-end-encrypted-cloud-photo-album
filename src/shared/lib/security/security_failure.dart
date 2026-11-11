/// Public failures deliberately omit passwords, key bytes and filesystem paths.
enum SecurityFailureCode {
  invalidPassword,
  passwordMismatch,
  backendUnavailable,
  backendFailure,
  busy,
  cancelled,
  alreadyExists,
  notFound,
  storageFailure,
  incompleteMaterial,
  unsupportedFormat,
  invalidLength,
  identityMismatch,
  authenticationFailed,
  invalidPin,
  pinSetupRequired,
  retryLater,
  photoPasswordRequired,
  accessDenied,
}

final class SecurityFailure implements Exception {
  const SecurityFailure(this.code);

  final SecurityFailureCode code;

  @override
  String toString() => 'SecurityFailure(${code.name})';
}
