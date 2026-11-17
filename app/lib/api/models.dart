// Errors and response types of the FamChat API.

/// The server answered with an error status. [code] is the `{error}` value, `unknown` when the
/// body had none, or `bad_response` when a success body didn't have the expected shape.
class ApiException implements Exception {
  const ApiException(this.status, this.code, {this.familyId, this.familyName});
  final int status;
  final String code;

  /// For `last_admin`: the family whose only admin can't leave (or delete their account) yet.
  final int? familyId;
  final String? familyName;

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
  const Me({
    required this.userId,
    required this.deviceId,
    required this.name,
    required this.isAdmin,
    this.recoveryCodeSet = false,
    this.reviewer = false,
    this.operator = false,
    this.gifKey,
  });
  final String userId, deviceId, name;

  /// The KLIPY app key for GIF search, or null when the server has none (no GIF button).
  final String? gifKey;
  final bool isAdmin;

  /// An admin recovery code was saved (its key is registered).
  final bool recoveryCodeSet;

  /// A reviewer account (docs/protocol.md "Reviewer accounts"): sees only other reviewers.
  final bool reviewer;

  /// The family's operator: the only one who removes people or manages reviewer accounts.
  final bool operator;
}

/// `GET /admin/reviewers` (docs/protocol.md "Reviewer accounts"): the active reviewer invite's
/// link, if any, and the reviewer accounts, which the family directory never lists.
class Reviewers {
  const Reviewers({required this.inviteUrl, required this.users});

  /// The reusable `/join#review.<token>` link, or null when there is none (never made, or revoked).
  final String? inviteUrl;
  final List<ReviewerAccount> users;
}

class ReviewerAccount {
  const ReviewerAccount({required this.id, required this.name, required this.createdAt, required this.devices});
  final String id, name;
  final DateTime createdAt;

  /// Live devices.
  final int devices;
}

/// `POST /admin/users/:id/reset`: the one-time link that signs the user in again. [url] already
/// carries the claim key seed after the token (`/join#<token>.<seed>`); it never went to the server.
class ResetLink {
  const ResetLink({required this.resetId, required this.url, required this.expiresAt});
  final String resetId, url;
  final DateTime expiresAt;
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

/// `POST /devices/pair/start`: the session the new device polls, and the server's lookup code.
class PairStartResult {
  const PairStartResult({
    required this.sessionId,
    required this.lookup,
    required this.secret,
    required this.deviceId,
    required this.expiresIn,
  });
  final String sessionId, lookup, deviceId;

  /// The claim secret (not the pairing secret shown in the code).
  final String secret;
  final Duration expiresIn;
}

/// `POST /devices/pair/claim`.
sealed class PairClaim {
  const PairClaim();
}

class PairWaiting extends PairClaim {
  const PairWaiting();
}

class PairApproved extends PairClaim {
  const PairApproved(this.result, this.bundle);
  final RedeemResult result;

  /// The sealed bundle, base64url.
  final String bundle;
}

/// `GET /devices/pair/:code`: the new device as the server describes it (unverified until the MAC checks).
class PairSessionInfo {
  const PairSessionInfo({
    required this.lookup,
    required this.deviceId,
    required this.ephPub,
    required this.encPub,
    required this.signPub,
    required this.keysMac,
    required this.deviceName,
    required this.platform,
  });
  final String lookup, deviceId, ephPub, encPub, signPub, keysMac, deviceName, platform;
}

/// `POST /devices/pair/offer`: an offer a new device can take (reverse pairing).
class PairOffer {
  const PairOffer({required this.offerId, required this.lookup, required this.expiresIn});
  final String offerId, lookup;
  final Duration expiresIn;
}

/// `GET /devices/pair/offer/:id`.
sealed class PairOfferStatus {
  const PairOfferStatus();
}

/// No device has taken the offer yet.
class OfferWaiting extends PairOfferStatus {
  const OfferWaiting();
}

/// A new device took the offer; [session] is unverified until the MAC checks.
class OfferTaken extends PairOfferStatus {
  const OfferTaken(this.session);
  final PairSessionInfo session;
}

/// Already approved.
class OfferApproved extends PairOfferStatus {
  const OfferApproved();
}

class Invite {
  const Invite({required this.inviteToken, required this.inviteUrl, required this.expiresAt});
  final String inviteToken, inviteUrl;
  final DateTime expiresAt;
}

/// `GET /families`: one of this user's families (docs/protocol.md "Families").
class Family {
  const Family({
    required this.id,
    required this.name,
    required this.status,
    required this.admin,
    required this.owner,
    required this.memberCount,
  });
  final int id;
  final String name;

  /// `pending`, `approved` or `declined`. Only an approved family can invite or be joined.
  final String status;

  /// This user is an admin of it.
  final bool admin;

  /// This user created it (or it passed to them).
  final bool owner;

  /// Live members.
  final int memberCount;
}

/// `GET /operator/families`: a family request as the operator sees it.
class FamilyRequest {
  const FamilyRequest({
    required this.id,
    required this.name,
    required this.status,
    required this.createdAt,
    required this.creatorName,
    required this.memberCount,
  });
  final int id;
  final String name, status;
  final DateTime createdAt;

  /// Null once the creator's account is gone.
  final String? creatorName;
  final int memberCount;
}

/// `POST /families/invite-lookup`: the family a member invite is for.
class InviteLookup {
  const InviteLookup({
    required this.familyId,
    required this.familyName,
    required this.invitedName,
    required this.alreadyMember,
  });
  final int familyId;
  final String familyName, invitedName;

  /// This user is already in the family (joining would be `409 conflict`).
  final bool alreadyMember;
}
