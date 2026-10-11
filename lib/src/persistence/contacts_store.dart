import '../domain/models.dart';
import '../domain/records.dart';

enum ContactMutationKind { create, update, delete, photo, providerAction }

enum ContactMutationState {
  queued,
  executing,
  confirmed,
  failed,
  unknown,
  conflict,
}

final class ContactMutation {
  const ContactMutation({
    required this.id,
    required this.accountId,
    required this.sourceKey,
    required this.kind,
    required this.state,
    required this.createdAt,
    this.identity,
    this.base,
    this.patch,
    this.result,
    this.remote,
    this.payload = const {},
    this.errorCode,
  });
  final String id, accountId, sourceKey;
  final ContactMutationKind kind;
  final ContactMutationState state;
  final DateTime createdAt;
  final ContactIdentity? identity;
  final ContactRecord? base, result, remote;
  final ContactPatch? patch;

  /// Serialized typed command for crash recovery; not a public provider feature map.
  final Map<String, Object?> payload;
  final String? errorCode;
  ContactMutation copy({
    ContactMutationState? state,
    ContactRecord? result,
    ContactRecord? remote,
    String? errorCode,
  }) => ContactMutation(
    id: id,
    accountId: accountId,
    sourceKey: sourceKey,
    kind: kind,
    state: state ?? this.state,
    createdAt: createdAt,
    identity: identity,
    base: base,
    patch: patch,
    result: result ?? this.result,
    remote: remote ?? this.remote,
    payload: payload,
    errorCode: errorCode ?? this.errorCode,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'account': accountId,
    'sourceKey': sourceKey,
    'kind': kind.name,
    'state': state.name,
    'created': createdAt.toUtc().toIso8601String(),
    'identity': identity?.toJson(),
    'base': base?.toJson(),
    'patch': patch?.toJson(),
    'result': result?.toJson(),
    'remote': remote?.toJson(),
    'payload': payload,
    'error': errorCode,
  };
  factory ContactMutation.fromJson(Map<String, dynamic> j) => ContactMutation(
    id: j['id'] as String,
    accountId: j['account'] as String,
    sourceKey: j['sourceKey'] as String,
    kind: ContactMutationKind.values.byName(j['kind'] as String),
    state: ContactMutationState.values.byName(j['state'] as String),
    createdAt: DateTime.parse(j['created'] as String),
    identity: j['identity'] == null
        ? null
        : ContactIdentity.fromJson((j['identity'] as Map).cast()),
    base: j['base'] == null
        ? null
        : contactRecordFromJson((j['base'] as Map).cast()),
    patch: j['patch'] == null
        ? null
        : ContactPatch.fromJson((j['patch'] as Map).cast()),
    result: j['result'] == null
        ? null
        : contactRecordFromJson((j['result'] as Map).cast()),
    remote: j['remote'] == null
        ? null
        : contactRecordFromJson((j['remote'] as Map).cast()),
    payload: (j['payload'] as Map? ?? {}).cast(),
    errorCode: j['error'] as String?,
  );
}

final class ContactAccount {
  const ContactAccount({
    required this.id,
    required this.provider,
    required this.displayName,
    required this.subject,
    required this.grantedScopes,
    this.enabled = true,
    this.generation = 0,
    this.errorCode,
  });
  final String id, displayName, subject;
  final ContactProviderKind provider;
  final Set<String> grantedScopes;
  final bool enabled;
  final int generation;
  final String? errorCode;
  ContactAccount copy({bool? enabled, int? generation, String? errorCode}) =>
      ContactAccount(
        id: id,
        provider: provider,
        displayName: displayName,
        subject: subject,
        grantedScopes: grantedScopes,
        enabled: enabled ?? this.enabled,
        generation: generation ?? this.generation,
        errorCode: errorCode,
      );
  Map<String, Object?> toJson() => {
    'id': id,
    'provider': provider.name,
    'name': displayName,
    'subject': subject,
    'scopes': grantedScopes.toList(),
    'enabled': enabled,
    'generation': generation,
    'error': errorCode,
  };
  factory ContactAccount.fromJson(Map<String, dynamic> j) => ContactAccount(
    id: j['id'] as String,
    provider: ContactProviderKind.values.byName(j['provider'] as String),
    displayName: j['name'] as String,
    subject: j['subject'] as String,
    grantedScopes: (j['scopes'] as List).cast<String>().toSet(),
    enabled: j['enabled'] as bool? ?? true,
    generation: j['generation'] as int? ?? 0,
    errorCode: j['error'] as String?,
  );
}

final class ContactSyncState {
  const ContactSyncState({
    required this.sourceKey,
    this.cursor,
    this.page,
    this.scanCursor,
    this.scanId,
    this.full = true,
    this.lastSync,
    this.errorCode,
  });
  final String sourceKey;
  final String? cursor, page, scanCursor, scanId, errorCode;
  final bool full;
  final DateTime? lastSync;
  Map<String, Object?> toJson() => {
    'source': sourceKey,
    'cursor': cursor,
    'page': page,
    'scanCursor': scanCursor,
    'scanId': scanId,
    'full': full,
    'lastSync': lastSync?.toUtc().toIso8601String(),
    'error': errorCode,
  };
  factory ContactSyncState.fromJson(Map<String, dynamic> j) => ContactSyncState(
    sourceKey: j['source'] as String,
    cursor: j['cursor'] as String?,
    page: j['page'] as String?,
    scanCursor: j['scanCursor'] as String?,
    scanId: j['scanId'] as String?,
    full: j['full'] as bool? ?? true,
    errorCode: j['error'] as String?,
    lastSync: j['lastSync'] == null
        ? null
        : DateTime.parse(j['lastSync'] as String),
  );
}

final class ContactDraft {
  const ContactDraft({
    required this.id,
    required this.sourceKey,
    required this.patch,
    this.identity,
  });
  final String id, sourceKey;
  final ContactIdentity? identity;
  final ContactPatch patch;
  Map<String, Object?> toJson() => {
    'id': id,
    'source': sourceKey,
    'identity': identity?.toJson(),
    'patch': patch.toJson(),
  };
  factory ContactDraft.fromJson(Map<String, dynamic> j) => ContactDraft(
    id: j['id'] as String,
    sourceKey: j['source'] as String,
    identity: j['identity'] == null
        ? null
        : ContactIdentity.fromJson((j['identity'] as Map).cast()),
    patch: ContactPatch.fromJson((j['patch'] as Map).cast()),
  );
}

abstract interface class ContactsReadTransaction {
  Future<List<ContactAccount>> accounts();
  Future<ContactAccount?> account(String id);
  Future<List<ContactSource>> sources({String? accountId});
  Future<ContactSource?> source(String key);
  Future<ContactRecord?> contact(ContactIdentity identity);
  Future<List<ContactRecord>> contacts({
    String? accountId,
    String? sourceKey,
    String query = '',
    int limit = 100,
    int offset = 0,
  });
  Future<List<ContactProjection>> projections({
    String? accountId,
    String? sourceKey,
    String query = '',
    int limit = 100,
    int offset = 0,
  });
  Future<int> count({String? accountId, String? sourceKey, String query = ''});
  Future<List<ContactMutation>> mutations({
    String? accountId,
    String? sourceKey,
  });
  Future<ContactSyncState?> syncState(String sourceKey);
  Future<List<ContactDraft>> drafts();
}

abstract interface class ContactsWriteTransaction
    implements ContactsReadTransaction {
  Future<void> putAccount(ContactAccount account);
  Future<void> putSource(ContactSource source);
  Future<void> putContact(ContactRecord contact, {String? seenScan});
  Future<void> deleteContact(ContactIdentity identity);
  Future<void> pruneUnseen(
    String sourceKey,
    String scanId,
    Set<String> protectedIdentities,
  );
  Future<void> putMutation(ContactMutation mutation);
  Future<void> deleteMutation(String id);
  Future<void> putSyncState(ContactSyncState state);
  Future<void> putDraft(ContactDraft draft);
  Future<void> deleteDraft(String id);

  /// Account-scoped cascade only. Credentials remain app-owned.
  Future<void> removeAccount(String id);
  Future<void> removeSource(String key);
}

/// Implementations await callbacks and every operation before commit, provide
/// atomic durable transactions across asynchronous gaps, and notify only after
/// commit. Transaction objects must reject access after their callback closes.
abstract interface class ContactsStore {
  Future<T> read<T>(
    Future<T> Function(ContactsReadTransaction transaction) action,
  );
  Future<T> write<T>(
    Future<T> Function(ContactsWriteTransaction transaction) action,
  );
  Stream<void> get changes;
  Future<void> close();
}
