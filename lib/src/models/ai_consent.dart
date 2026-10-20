/// The in-app AI consent (review 2026-10-19, P1): a versioned decision per
/// account, logged append-only in `public.ai_consents` and cached per account
/// on the device.
library;

/// Version of the consent text the sheet shows. Raise it when what the AI
/// features send, or to whom, changes: every account is asked again on its
/// next AI use.
const int kAiConsentVersion = 1;

/// One consent decision: a grant (with the explicit health data consent,
/// GDPR art. 9(2)(a)) or a withdrawal.
class AiConsentRecord {
  const AiConsentRecord({
    required this.version,
    required this.granted,
    required this.healthData,
    required this.decidedAt,
    this.pendingUpload = false,
  });

  /// A withdrawal decided at [decidedAt], not yet in the server log.
  const AiConsentRecord.withdrawal(DateTime decidedAt, {bool pending = true})
    : this(
        version: kAiConsentVersion,
        granted: false,
        healthData: false,
        decidedAt: decidedAt,
        pendingUpload: pending,
      );

  final int version;
  final bool granted;
  final bool healthData;

  /// Server timestamp of the logged row; the device time for a withdrawal
  /// that is still [pendingUpload].
  final DateTime decidedAt;

  /// A withdrawal the server log has not recorded yet. It is effective on the
  /// device at once; the app retries the upload, and a server read never
  /// turns it back into a grant meanwhile. Grants are never pending: one
  /// counts only after the server logged it.
  final bool pendingUpload;

  /// Whether AI features may run: a grant of the current text including the
  /// health data consent.
  bool get allowsAi =>
      granted && healthData && version >= kAiConsentVersion && !pendingUpload;

  /// Local cache shape (encrypted account slot `ai_consent`).
  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': version,
    'granted': granted,
    'healthData': healthData,
    'decidedAt': decidedAt.toUtc().toIso8601String(),
    if (pendingUpload) 'pendingUpload': true,
  };

  /// Null for anything that is not a complete record: an unreadable slot is
  /// no consent.
  static AiConsentRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final version = json['version'];
    final granted = json['granted'];
    final healthData = json['healthData'];
    final decidedAt = json['decidedAt'];
    if (version is! int ||
        granted is! bool ||
        healthData is! bool ||
        decidedAt is! String) {
      return null;
    }
    final at = DateTime.tryParse(decidedAt);
    if (at == null) return null;
    final pending = json['pendingUpload'] == true;
    // Same rule as the server check: health data only with a grant, and only
    // a withdrawal can be pending.
    if (healthData && !granted) return null;
    if (pending && granted) return null;
    return AiConsentRecord(
      version: version,
      granted: granted,
      healthData: healthData,
      decidedAt: at,
      pendingUpload: pending,
    );
  }

  /// A row of `public.ai_consents` (select of version, granted, health_data,
  /// created_at). Null when a field is missing or off the contract.
  static AiConsentRecord? fromRow(Map<String, dynamic> row) {
    final version = row['version'];
    final granted = row['granted'];
    final healthData = row['health_data'];
    final createdAt = row['created_at'];
    if (version is! int ||
        granted is! bool ||
        healthData is! bool ||
        createdAt is! String) {
      return null;
    }
    final at = DateTime.tryParse(createdAt);
    if (at == null || (healthData && !granted)) return null;
    return AiConsentRecord(
      version: version,
      granted: granted,
      healthData: healthData,
      decidedAt: at,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AiConsentRecord &&
      other.version == version &&
      other.granted == granted &&
      other.healthData == healthData &&
      other.decidedAt.isAtSameMomentAs(decidedAt) &&
      other.pendingUpload == pendingUpload;

  @override
  int get hashCode => Object.hash(
    version,
    granted,
    healthData,
    decidedAt.microsecondsSinceEpoch,
    pendingUpload,
  );
}

/// Why a Coach output is reported. The wire codes are the closed list of
/// `ai_reports_reason_check`.
enum AiReportReason {
  incorrect('incorrect'),
  harmful('harmful'),
  inappropriate('inappropriate'),
  other('other');

  const AiReportReason(this.code);

  final String code;
}

/// What was reported: the answer text or the generated recipe picture.
/// Wire codes of `ai_reports_target_check`.
enum AiReportTarget {
  answer('answer'),
  recipeImage('recipe_image');

  const AiReportTarget(this.code);

  final String code;
}
