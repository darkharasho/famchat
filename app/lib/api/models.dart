// Errors and response types of the FamChat API.

/// The server answered with an error status. [code] is the `{error}` value, `unknown` when the
/// body had none, or `bad_response` when a success body didn't have the expected shape.
class ApiException implements Exception {
  const ApiException(this.status, this.code);
  final int status;
  final String code;

  @override
  String toString() => 'ApiException($status, $code)';
}

/// The request never got an answer (offline, timeout, connection reset).
class NetworkException implements Exception {
  const NetworkException(this.cause);
  final Object cause;

  @override
  String toString() => 'NetworkException($cause)';
}

/// The server refused this device's refresh token: the device was revoked and its session wiped.
class SignedOutException implements Exception {
  const SignedOutException();

  @override
  String toString() => 'SignedOutException';
}

class TokenPair {
  const TokenPair(this.accessToken, this.refreshToken);
  final String accessToken, refreshToken;
}

class RedeemResult {
  const RedeemResult({
    required this.userId,
    required this.deviceId,
    required this.isAdmin,
    required this.accessToken,
    required this.refreshToken,
  });
  final String userId, deviceId, accessToken, refreshToken;
  final bool isAdmin;
}

class Me {
  const Me({required this.userId, required this.deviceId, required this.name, required this.isAdmin});
  final String userId, deviceId, name;
  final bool isAdmin;
}

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
    required this.createdAt,
    required this.lastSeen,
    required this.current,
  });
  final String id, name, platform;
  final DateTime createdAt, lastSeen;
  final bool current;
}

class Invite {
  const Invite({required this.inviteToken, required this.inviteUrl, required this.expiresAt});
  final String inviteToken, inviteUrl;
  final DateTime expiresAt;
}
