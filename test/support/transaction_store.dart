import 'dart:async';
import 'dart:convert';

import 'package:busystack_contacts/busystack_contacts.dart';

/// Contract fixture only. BusyCards production uses its SQLCipher adapter.
final class TransactionStore implements ContactsStore {
  Map<String, dynamic> data = {
    'accounts': {},
    'sources': {},
    'contacts': {},
    'seen': {},
    'mutations': {},
    'sync': {},
    'drafts': {},
  };
  final notifications = StreamController<void>.broadcast(sync: true);
  bool failCommit = false;
  Future<void> _tail = Future<void>.value();
  bool _closed = false;
  @override
  Stream<void> get changes => notifications.stream;
  @override
  Future<T> read<T>(Future<T> Function(ContactsReadTransaction) action) =>
      _enqueue(() async {
        final tx = _Tx(data);
        try {
          return await action(tx);
        } finally {
          tx.active = false;
        }
      });
  @override
  Future<T> write<T>(Future<T> Function(ContactsWriteTransaction) action) =>
      _enqueue(() async {
        final staged = (jsonDecode(jsonEncode(data)) as Map)
            .cast<String, dynamic>();
        final tx = _Tx(staged);
        try {
          final result = await action(tx);
          if (failCommit) {
            failCommit = false;
            throw StateError('Injected commit failure');
          }
          data = staged;
          notifications.add(null);
          return result;
        } finally {
          tx.active = false;
        }
      });

  Future<T> _enqueue<T>(Future<T> Function() action) {
    if (_closed) return Future<T>.error(StateError('Store closed'));
    final result = Completer<T>();
    final done = Completer<void>();
    final previous = _tail;
    _tail = done.future;
    unawaited(() async {
      await previous;
      try {
        result.complete(await action());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      } finally {
        done.complete();
      }
    }());
    return result.future;
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _tail;
    await notifications.close();
  }
}

final class _Tx implements ContactsWriteTransaction {
  _Tx(this.data);
  final Map<String, dynamic> data;
  bool active = true;
  void check() {
    if (!active) throw StateError('Transaction closed');
  }

  Map<String, dynamic> table(String name) {
    check();
    return (data[name] as Map).cast<String, dynamic>();
  }

  List<T> values<T>(String name, T Function(Map<String, dynamic>) decode) =>
      table(name).values.map((v) => decode((v as Map).cast())).toList();
  T? one<T>(String name, String id, T Function(Map<String, dynamic>) decode) =>
      table(name)[id] == null ? null : decode((table(name)[id] as Map).cast());
  @override
  Future<List<ContactAccount>> accounts() async =>
      values('accounts', ContactAccount.fromJson);
  @override
  Future<ContactAccount?> account(String id) async =>
      one('accounts', id, ContactAccount.fromJson);
  @override
  Future<List<ContactSource>> sources({String? accountId}) async => values(
    'sources',
    ContactSource.fromJson,
  ).where((v) => accountId == null || v.accountId == accountId).toList();
  @override
  Future<ContactSource?> source(String key) async =>
      one('sources', key, ContactSource.fromJson);
  @override
  Future<ContactRecord?> contact(ContactIdentity id) async =>
      one('contacts', id.key, contactRecordFromJson);
  List<ContactRecord> matching(String? account, String? source, String query) =>
      values('contacts', contactRecordFromJson)
          .where(
            (v) =>
                (account == null || v.identity.accountId == account) &&
                (source == null || source == sourceFor(v.identity)) &&
                v.projection.searchText.contains(query.toLowerCase()),
          )
          .toList()
        ..sort(
          (a, b) =>
              a.projection.displayName.compareTo(b.projection.displayName),
        );
  String sourceFor(ContactIdentity id) =>
      jsonEncode([id.accountId, id.provider.name, id.sourceId]);
  @override
  Future<List<ContactRecord>> contacts({
    String? accountId,
    String? sourceKey,
    String query = '',
    int limit = 100,
    int offset = 0,
  }) async =>
      matching(accountId, sourceKey, query).skip(offset).take(limit).toList();
  @override
  Future<List<ContactProjection>> projections({
    String? accountId,
    String? sourceKey,
    String query = '',
    int limit = 100,
    int offset = 0,
  }) async => (await contacts(
    accountId: accountId,
    sourceKey: sourceKey,
    query: query,
    limit: limit,
    offset: offset,
  )).map((v) => v.projection).toList();
  @override
  Future<int> count({
    String? accountId,
    String? sourceKey,
    String query = '',
  }) async => matching(accountId, sourceKey, query).length;
  @override
  Future<List<ContactMutation>> mutations({
    String? accountId,
    String? sourceKey,
  }) async => values('mutations', ContactMutation.fromJson)
      .where(
        (v) =>
            (accountId == null || v.accountId == accountId) &&
            (sourceKey == null || v.sourceKey == sourceKey),
      )
      .toList();
  @override
  Future<ContactSyncState?> syncState(String key) async =>
      one('sync', key, ContactSyncState.fromJson);
  @override
  Future<List<ContactDraft>> drafts() async =>
      values('drafts', ContactDraft.fromJson);
  @override
  Future<void> putAccount(ContactAccount v) async =>
      table('accounts')[v.id] = v.toJson();
  @override
  Future<void> putSource(ContactSource v) async =>
      table('sources')[v.key] = v.toJson();
  @override
  Future<void> putContact(ContactRecord v, {String? seenScan}) async {
    table('contacts')[v.identity.key] = v.toJson();
    table('seen')[v.identity.key] = seenScan;
  }

  @override
  Future<void> deleteContact(ContactIdentity id) async {
    table('contacts').remove(id.key);
    table('seen').remove(id.key);
  }

  @override
  Future<void> pruneUnseen(
    String sourceKey,
    String scanId,
    Set<String> protectedIdentities,
  ) async {
    for (final v in await contacts(sourceKey: sourceKey, limit: 100000)) {
      if (table('seen')[v.identity.key] != scanId &&
          !protectedIdentities.contains(v.identity.key)) {
        await deleteContact(v.identity);
      }
    }
  }

  @override
  Future<void> putMutation(ContactMutation v) async =>
      table('mutations')[v.id] = v.toJson();
  @override
  Future<void> deleteMutation(String id) async => table('mutations').remove(id);
  @override
  Future<void> putSyncState(ContactSyncState v) async =>
      table('sync')[v.sourceKey] = v.toJson();
  @override
  Future<void> putDraft(ContactDraft v) async =>
      table('drafts')[v.id] = v.toJson();
  @override
  Future<void> deleteDraft(String id) async => table('drafts').remove(id);
  @override
  Future<void> removeSource(String key) async {
    for (final v in await contacts(sourceKey: key)) {
      await deleteContact(v.identity);
    }
    for (final v in await mutations(sourceKey: key)) {
      await deleteMutation(v.id);
    }
    for (final v in (await drafts()).where((v) => v.sourceKey == key)) {
      await deleteDraft(v.id);
    }
    table('sources').remove(key);
    table('sync').remove(key);
  }

  @override
  Future<void> removeAccount(String id) async {
    for (final s in await sources(accountId: id)) {
      await removeSource(s.key);
    }
    for (final v in await mutations(accountId: id)) {
      await deleteMutation(v.id);
    }
    table('accounts').remove(id);
  }
}
