import 'dart:async';
import 'dart:typed_data';

import 'package:busystack_contacts/busystack_contacts.dart';
import 'package:test/test.dart';

import 'support/transaction_store.dart';

ContactSource source(
  String account, {
  bool writable = true,
  String sourceId = 'book',
  String name = 'Book',
}) => ContactSource(
  accountId: account,
  id: sourceId,
  provider: ContactProviderKind.carddav,
  kind: ContactSourceKind.carddavAddressBook,
  name: name,
  remotePath: 'https://dav.test/$sourceId/',
  capabilities: ContactCapabilities(
    create: writable,
    update: writable,
    delete: writable,
    photoRead: true,
    photoWrite: writable,
    fields: ContactField.values.toSet(),
  ),
);
CardDavContactRecord record(
  String account,
  String id, {
  String revision = '"one"',
  String name = 'Zoë',
  String notes = 'base',
  String email = 'same@example.test',
  String sourceId = 'book',
}) {
  final identity = ContactIdentity(
    accountId: account,
    provider: ContactProviderKind.carddav,
    sourceId: sourceId,
    remoteId: id,
  );
  final card =
      newVcard(
        ContactPatch(
          name: FieldEdit.set(ContactName(display: name)),
          notes: FieldEdit.set(notes),
          emails: FieldEdit.set([ContactValue(email)]),
        ),
        uid: id,
      ).replace('X-UNKNOWN', [
        const VCardProperty(name: 'X-UNKNOWN', rawValue: 'retained'),
      ]);
  return CardDavContactRecord(
    identity: identity,
    vcard: card,
    revision: revision,
    projection: projectVcard(identity, card),
  );
}

Future<void> seed(TransactionStore store, String id, {bool writable = true}) =>
    store.write((tx) async {
      await tx.putAccount(
        ContactAccount(
          id: id,
          provider: ContactProviderKind.carddav,
          displayName: id,
          subject: id,
          grantedScopes: {},
        ),
      );
      await tx.putSource(source(id, writable: writable));
    });

final class FixtureProvider implements ContactsProvider {
  FixtureProvider(this.accountId);
  @override
  final String accountId;
  @override
  ContactProviderKind get kind => ContactProviderKind.carddav;
  final remote = <String, ContactRecord>{};
  int creates = 0, updates = 0, active = 0, maximumActive = 0, reads = 0;
  bool ambiguousCreate = false,
      closed = false,
      discoveryFails = false,
      closeFails = false;
  Future<ContactsPage> Function(String?, String?, ContactsCancellationToken)?
  onPage;
  Future<void> Function()? onWrite;
  @override
  Future<List<ContactSource>> discover(ContactsCancellationToken token) async {
    if (discoveryFails)
      throw const ContactsException(
        ContactsFailure.offline,
        'fixture-discovery',
      );
    return [source(accountId)];
  }

  @override
  Future<ContactsPage> page(
    ContactSource source, {
    String? cursor,
    String? page,
    required ContactsCancellationToken cancellation,
  }) async {
    reads++;
    if (onPage != null) return onPage!(cursor, page, cancellation);
    return ContactsPage(
      records: remote.values.toList(),
      cursor: 'next',
      fullEnumeration: cursor == null,
    );
  }

  @override
  Future<ContactRecord> get(
    ContactSource source,
    ContactIdentity id,
    ContactsCancellationToken token,
  ) async =>
      remote[id.remoteId] ??
      (throw const ContactsException(ContactsFailure.notFound, 'gone'));
  @override
  Future<ContactRecord> create(
    ContactSource source,
    ContactPatch patch,
    String mutationId,
    ContactsCancellationToken token, {
    String? fullVcard,
  }) async {
    creates++;
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      await onWrite?.call();
      final original = record(accountId, mutationId);
      final card = applyVcardPatch(original.vcard, patch);
      final result = CardDavContactRecord(
        identity: original.identity,
        vcard: card,
        revision: '"new"',
        projection: projectVcard(original.identity, card),
      );
      remote[mutationId] = result;
      if (ambiguousCreate)
        throw const ContactsException(
          ContactsFailure.unknownOutcome,
          'timeout-after-create',
        );
      return result;
    } finally {
      active--;
    }
  }

  @override
  Future<ContactRecord> update(
    ContactSource source,
    ContactRecord base,
    ContactPatch patch,
    ContactsCancellationToken token,
  ) async {
    updates++;
    final current =
        await get(source, base.identity, token) as CardDavContactRecord;
    if (current.revision != base.revision)
      throw const ContactsException(
        ContactsFailure.conflict,
        'fixture-conflict',
      );
    final card = applyVcardPatch(current.vcard, patch);
    final result = CardDavContactRecord(
      identity: base.identity,
      vcard: card,
      revision: '"updated"',
      projection: projectVcard(base.identity, card),
    );
    remote[base.identity.remoteId] = result;
    return result;
  }

  @override
  Future<void> delete(
    ContactSource source,
    ContactRecord base,
    ContactsCancellationToken token,
  ) async {
    remote.remove(base.identity.remoteId);
  }

  @override
  Future<Uint8List?> photo(
    ContactSource source,
    ContactRecord record,
    ContactsCancellationToken token,
  ) async => null;
  @override
  Future<ContactRecord> setPhoto(
    ContactSource source,
    ContactRecord base,
    Uint8List? bytes,
    String mediaType,
    ContactsCancellationToken token,
  ) async => base;
  @override
  Future<ContactActionResult> action(
    ContactProviderAction action,
    ContactsCancellationToken token,
  ) async => const ContactActionResult(discoverSources: true);
  @override
  ContactProviderAction decodeAction(Map<String, dynamic> json) =>
      const FixtureAction();
  @override
  Future<ContactRecord?> findCreated(
    ContactSource source,
    ContactMutation mutation,
    ContactsCancellationToken token,
  ) async => remote[mutation.id];
  @override
  void close() {
    closed = true;
    if (closeFails) throw StateError('fixture close failed');
  }
}

final class FixtureAction implements ContactProviderAction {
  const FixtureAction();
  @override
  Map<String, Object?> toJson() => {'type': 'fixture'};
}

void main() {
  late TransactionStore store;
  late FixtureProvider provider;
  late ContactsDirectory directory;
  setUp(() async {
    store = TransactionStore();
    await seed(store, 'a');
    provider = FixtureProvider('a');
    directory = ContactsDirectory(store: store, maximumReadAttempts: 1);
    directory.bind(provider);
  });
  tearDown(() async {
    if (provider.closeFails) {
      await expectLater(directory.close(), throwsStateError);
    } else {
      await directory.close();
    }
    await store.close();
  });
  test(
    'shutdown drains other providers and gates after provider cleanup failure',
    () async {
      final other = FixtureProvider('b');
      await seed(store, 'b');
      directory.bind(other);
      provider.closeFails = true;
      final close = directory.close();
      await expectLater(
        close.timeout(const Duration(seconds: 2)),
        throwsStateError,
      );
      expect(other.closed, isTrue);
      expect(identical(close, directory.close()), isTrue);
      await expectLater(
        directory.discover('b'),
        throwsA(isA<ContactsException>()),
      );
    },
  );
  test('a committed replacement generation fences old awaited provider writes before detach', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    provider.onPage = (_, _, token) async {
      entered.complete();
      await release.future;
      return ContactsPage(
        records: [record('a', 'stale')],
        cursor: 'stale-cursor',
      );
    };
    final operation = directory.synchronize(source('a').key);
    final assertion = expectLater(
      operation,
      throwsA(
        isA<ContactsException>().having(
          (e) => e.kind,
          'kind',
          ContactsFailure.cancelled,
        ),
      ),
    );
    await entered.future;
    await store.write((tx) async {
      final account = (await tx.account('a'))!;
      await tx.putAccount(account.copy(generation: account.generation + 1));
    });
    release.complete();
    await assertion;
    expect(await store.read((tx) => tx.contacts()), isEmpty);
    expect(await store.read((tx) => tx.syncState(source('a').key)), isNull);
  });
  test(
    'detach drains stale reads while retaining enabled replacement enrollment',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      provider.onPage = (_, _, token) async {
        entered.complete();
        await release.future;
        return ContactsPage(records: [record('a', 'stale')]);
      };
      final running = directory.synchronize(source('a').key);
      final failed = expectLater(
        running,
        throwsA(
          isA<ContactsException>().having(
            (e) => e.kind,
            'kind',
            ContactsFailure.cancelled,
          ),
        ),
      );
      await entered.future;
      await store.write((tx) async {
        final previous = (await tx.account('a'))!;
        await tx.putAccount(previous.copy(generation: previous.generation + 1));
      });
      await directory.detach('a');
      await failed;
      expect(
        (await store.read((tx) async => tx.account('a')))!.enabled,
        isTrue,
      );
      provider = FixtureProvider('a');
      directory.bind(provider);
      provider.remote['fresh'] = record('a', 'fresh');
      release.complete();
      await directory.synchronize(source('a').key);
      expect((await directory.search('')).map((r) => r.identity.remoteId), [
        'fresh',
      ]);
    },
  );
  test('durable stage is observable before dispatch fails', () async {
    provider.ambiguousCreate = true;
    ContactMutation? staged;
    final result = await directory.create(
      source('a').key,
      const ContactPatch(),
      onStaged: (m) => staged = m,
    );
    expect(staged!.id, result.id);
    expect(staged!.state, ContactMutationState.queued);
    expect(result.state, ContactMutationState.unknown);
    await directory.retry(result.id);
    expect(provider.creates, 1);
  });
  test('preserved date representations reject common edits before journaling or HTTP', () async {
    final original = record('a', 'text-date');
    final card = original.vcard.replace('BDAY', [
      const VCardProperty(
        name: 'BDAY',
        rawValue: 'Springtime',
        parameters: [
          VCardParameter('VALUE', ['text']),
        ],
      ),
    ]);
    final base = CardDavContactRecord(
      identity: original.identity,
      vcard: card,
      revision: original.revision,
      projection: projectVcard(original.identity, card),
    );
    await store.write((tx) async => tx.putContact(base));
    expect(base.projection.readOnlyFields, contains(ContactField.dates));
    await expectLater(
      directory.update(base, const ContactPatch(dates: FieldEdit.clear())),
      throwsA(
        isA<ContactsException>().having(
          (error) => error.kind,
          'kind',
          ContactsFailure.permission,
        ),
      ),
    );
    expect(provider.updates, 0);
    expect(await store.read((tx) async => tx.mutations()), isEmpty);
    final stored = await store.read((tx) async => tx.contact(base.identity));
    expect((stored as CardDavContactRecord).vcard.text('BDAY'), 'Springtime');
  });
  test('initial pages commit records and cursor together; interrupted scan never prunes unseen cache', () async {
    final cached = record('a', 'cached');
    await store.write((tx) async => tx.putContact(cached));
    provider.onPage = (cursor, page, _) async => page == null
        ? ContactsPage(
            records: [record('a', 'first')],
            nextPage: 'page2',
            fullEnumeration: true,
          )
        : throw const ContactsException(ContactsFailure.offline, 'mid-scan');
    await expectLater(
      directory.synchronize(source('a').key),
      throwsA(isA<ContactsException>()),
    );
    expect(await store.read((tx) async => tx.count()), 2);
    final checkpoint = await store.read(
      (tx) async => tx.syncState(source('a').key),
    );
    expect(checkpoint!.page, 'page2');
    expect(checkpoint.cursor, isNull);
    expect(checkpoint.scanId, isNotNull);
    provider.onPage = (cursor, page, _) async {
      expect(page, 'page2');
      return ContactsPage(records: [record('a', 'last')], cursor: 'committed');
    };
    await directory.synchronize(source('a').key);
    expect(await store.read((tx) async => tx.contact(cached.identity)), isNull);
    expect(await store.read((tx) async => tx.count()), 2);
    expect(
      (await store.read((tx) async => tx.syncState(source('a').key)))!.cursor,
      'committed',
    );
  });
  test('transaction failure cannot advance cursor without its data', () async {
    provider.remote['new'] = record('a', 'new');
    store.failCommit = true;
    await expectLater(directory.synchronize(source('a').key), throwsStateError);
    expect(await store.read((tx) async => tx.count()), 0);
    expect(
      await store.read((tx) async => tx.syncState(source('a').key)),
      isNull,
    );
    await directory.synchronize(source('a').key);
    expect(await store.read((tx) async => tx.count()), 1);
  });
  test(
    'async transaction gaps remain isolated and roll back atomically',
    () async {
      final inserted = record('a', 'delayed');
      await expectLater(
        store.write<void>((tx) async {
          await tx.putContact(inserted);
          await Future<void>.delayed(const Duration(milliseconds: 1));
          await tx.putSyncState(
            ContactSyncState(
              sourceKey: source('a').key,
              cursor: 'not-committed',
            ),
          );
          throw StateError('rollback after await');
        }),
        throwsStateError,
      );
      expect(await store.read((tx) async => tx.count()), 0);
      expect(
        await store.read((tx) async => tx.syncState(source('a').key)),
        isNull,
      );

      final release = Completer<void>();
      final first = store.write((tx) async {
        await tx.putContact(record('a', 'first'));
        await release.future;
      });
      var secondStarted = false;
      final second = store.write((tx) async {
        secondStarted = true;
        expect(await tx.count(), 1);
        await tx.putContact(record('a', 'second'));
      });
      await Future<void>.delayed(Duration.zero);
      expect(secondStarted, isFalse);
      release.complete();
      await Future.wait([first, second]);
      expect(await store.read((tx) async => tx.count()), 2);
    },
  );
  test(
    'recipient source filters and exclusions apply before result limiting',
    () async {
      final disabled = source('a', sourceId: 'disabled', name: 'Disabled');
      final selected = source('a', sourceId: 'selected', name: 'Selected');
      await store.write((tx) async {
        await tx.putSource(disabled);
        await tx.putSource(selected);
        for (var index = 0; index < 12; index++) {
          await tx.putContact(
            record(
              'a',
              'disabled-$index',
              name: 'A $index',
              email: 'disabled$index@example.test',
              sourceId: 'disabled',
            ),
          );
        }
        await tx.putContact(
          record(
            'a',
            'selected-one',
            name: 'Z Selected',
            email: 'selected@example.test',
            sourceId: 'selected',
          ),
        );
        await tx.putContact(
          record(
            'a',
            'selected-excluded',
            name: 'Z Excluded',
            email: 'excluded@example.test',
            sourceId: 'selected',
          ),
        );
      });
      final suggestions = await directory.suggestRecipients(
        '',
        accountIds: {'a'},
        sourceKeys: {selected.key},
        excludedAddresses: {'EXCLUDED@example.test'},
        limit: 1,
      );
      expect(suggestions.map((value) => value.email), [
        'selected@example.test',
      ]);
      expect(suggestions.single.identities.single.sourceId, 'selected');
    },
  );
  test(
    'expired cursor safely rebuilds while retaining drafts and pending work',
    () async {
      final base = record('a', 'edited');
      await store.write((tx) async {
        await tx.putContact(base);
        await tx.putSyncState(
          ContactSyncState(sourceKey: source('a').key, cursor: 'expired'),
        );
        await tx.putDraft(
          ContactDraft(
            id: 'draft',
            sourceKey: source('a').key,
            identity: base.identity,
            patch: const ContactPatch(notes: FieldEdit.set('local')),
          ),
        );
        await tx.putMutation(
          ContactMutation(
            id: 'pending',
            accountId: 'a',
            sourceKey: source('a').key,
            kind: ContactMutationKind.update,
            state: ContactMutationState.failed,
            createdAt: DateTime.now(),
            identity: base.identity,
            base: base,
            patch: const ContactPatch(notes: FieldEdit.set('local')),
          ),
        );
      });
      provider.onPage = (cursor, page, _) async {
        if (cursor != null)
          throw const ContactsException(
            ContactsFailure.expiredCursor,
            'expired',
          );
        return const ContactsPage(
          records: [],
          cursor: 'fresh',
          fullEnumeration: true,
        );
      };
      await directory.synchronize(source('a').key);
      expect(await store.read((tx) async => tx.count()), 1);
      expect(await store.read((tx) async => tx.drafts()), hasLength(1));
      expect(
        (await store.read((tx) async => tx.syncState(source('a').key)))!.cursor,
        'fresh',
      );
    },
  );
  test(
    'ambiguous create is persisted and reconciled without a duplicate POST',
    () async {
      provider.ambiguousCreate = true;
      final mutation = await directory.create(
        source('a').key,
        const ContactPatch(
          name: FieldEdit.set(ContactName(display: 'Created')),
        ),
      );
      expect(mutation.state, ContactMutationState.unknown);
      expect(provider.creates, 1);
      await directory.retry(mutation.id);
      await directory.resumeQueued('a');
      expect(provider.creates, 1);
      final result = await directory.reconcile(mutation.id);
      expect(result.state, ContactMutationState.confirmed);
      expect(await store.read((tx) async => tx.count()), 1);
      expect(provider.creates, 1);
    },
  );
  test('unknown create with no positive match remains unresolved and is never replayed', () async {
    provider.ambiguousCreate = true;
    final mutation = await directory.create(
      source('a').key,
      const ContactPatch(),
    );
    provider.remote.clear();
    final result = await directory.reconcile(mutation.id);
    expect(result.state, ContactMutationState.unknown);
    expect(provider.creates, 1);
  });
  test('confirmed mutation result survives delayed sync echo', () async {
    final base = record('a', 'existing');
    provider.remote['existing'] = base;
    await store.write((tx) async => tx.putContact(base));
    final mutation = await directory.update(
      base,
      const ContactPatch(notes: FieldEdit.set('confirmed')),
    );
    provider.onPage = (cursor, page, _) async => ContactsPage(
      records: [base],
      cursor: 'echo-delayed',
      fullEnumeration: true,
    );
    await directory.synchronize(source('a').key);
    expect(
      (await store.read((tx) async => tx.contact(base.identity)))!
          .projection
          .notes,
      'confirmed',
    );
    provider.onPage = (cursor, page, _) async =>
        ContactsPage(records: [mutation.result!], cursor: 'ack');
    await directory.synchronize(source('a').key);
    expect(await store.read((tx) async => tx.mutations()), isEmpty);
  });
  test('base/local/remote conflict is durable and rebase changes only explicit fields', () async {
    final base = record('a', 'existing');
    final remote = record(
      'a',
      'existing',
      revision: '"remote"',
      notes: 'remote notes',
      name: 'Remote name',
    );
    provider.remote['existing'] = remote;
    await store.write((tx) async => tx.putContact(base));
    final conflict = await directory.update(
      base,
      const ContactPatch(notes: FieldEdit.clear()),
    );
    expect(conflict.state, ContactMutationState.conflict);
    expect(conflict.base!.projection.notes, 'base');
    expect(conflict.remote!.projection.displayName, 'Remote name');
    expect(conflict.patch!.notes.kind, FieldEditKind.clear);
    final resolved = await directory.resolveConflict(
      conflict.id,
      applyLocalFields: true,
    );
    expect(resolved!.state, ContactMutationState.confirmed);
    expect(resolved.result!.projection.notes, '');
    expect(resolved.result!.projection.displayName, 'Remote name');
    expect(
      (resolved.result as CardDavContactRecord).vcard.text('X-UNKNOWN'),
      'retained',
    );
  });
  test(
    'remote deletion conflicts can be explicitly accepted without recreating',
    () async {
      final base = record('a', 'gone');
      await store.write((tx) async {
        await tx.putContact(base);
        await tx.putMutation(
          ContactMutation(
            id: 'p',
            accountId: 'a',
            sourceKey: source('a').key,
            kind: ContactMutationKind.update,
            state: ContactMutationState.queued,
            createdAt: DateTime.now(),
            identity: base.identity,
            base: base,
            patch: const ContactPatch(notes: FieldEdit.set('local')),
          ),
        );
      });
      provider.onPage = (cursor, page, _) async =>
          ContactsPage(records: [], deleted: [base.identity], cursor: 'next');
      await directory.synchronize(source('a').key);
      await directory.resolveConflict('p', applyLocalFields: false);
      expect(await store.read((tx) async => tx.count()), 0);
      expect(provider.creates, 0);
    },
  );
  test('crash/restart changes executing to unknown and queued creates alone resume', () async {
    await store.write(
      (tx) async => tx.putMutation(
        ContactMutation(
          id: 'in-flight',
          accountId: 'a',
          sourceKey: source('a').key,
          kind: ContactMutationKind.create,
          state: ContactMutationState.executing,
          createdAt: DateTime.now(),
          patch: const ContactPatch(),
        ),
      ),
    );
    await directory.restore();
    expect(
      (await store.read((tx) async => tx.mutations())).single.state,
      ContactMutationState.unknown,
    );
    await directory.resumeQueued('a');
    expect(provider.creates, 0);
  });
  test(
    'remote success followed by failed local commit remains uncertain',
    () async {
      provider.onWrite = () async {
        store.failCommit = true;
      };
      final result = await directory.create(
        source('a').key,
        const ContactPatch(),
      );
      expect(result.state, ContactMutationState.unknown);
      expect(provider.creates, 1);
      final confirmed = await directory.reconcile(result.id);
      expect(confirmed.state, ContactMutationState.confirmed);
      expect(provider.creates, 1);
    },
  );
  test('same account mutations serialize; independent instances and accounts remain separate', () async {
    provider.onWrite = () async =>
        Future<void>.delayed(const Duration(milliseconds: 5));
    await Future.wait(
      List.generate(
        4,
        (_) => directory.create(source('a').key, const ContactPatch()),
      ),
    );
    expect(provider.maximumActive, 1);
    expect(provider.creates, 4);
    final second = TransactionStore();
    await seed(second, 'b');
    final other = ContactsDirectory(store: second);
    other.bind(FixtureProvider('b'));
    await other.create(source('b').key, const ContactPatch());
    expect(await store.read((tx) async => tx.count()), 4);
    expect(await second.read((tx) async => tx.count()), 1);
    await other.close();
    await second.close();
  });
  test('offline suggestions deduplicate addresses without merging stored identities or accounts', () async {
    await seed(store, 'b');
    await store.write((tx) async {
      await tx.putContact(record('a', 'one'));
      await tx.putContact(record('b', 'two'));
    });
    final both = await directory.suggestRecipients(
      'zoë',
      accountIds: {'a', 'b'},
    );
    expect(both, hasLength(1));
    expect(both.single.identities, hasLength(2));
    expect(
      (await directory.suggestRecipients(
        '',
        accountIds: {'a'},
      )).single.identities.single.accountId,
      'a',
    );
    expect(
      await directory.suggestRecipients(
        '',
        accountIds: {'a', 'b'},
        excludedAddresses: {'SAME@EXAMPLE.TEST'},
      ),
      isEmpty,
    );
    expect(await store.read((tx) async => tx.count()), 2);
  });
  test('read-only actions are rejected before staging or dispatch', () async {
    await store.write((tx) async => tx.putSource(source('a', writable: false)));
    await expectLater(
      directory.create(source('a').key, const ContactPatch()),
      throwsA(isA<ContactsException>()),
    );
    await expectLater(
      directory.update(
        record('a', 'one'),
        const ContactPatch(notes: FieldEdit.clear()),
      ),
      throwsA(isA<ContactsException>()),
    );
    expect(provider.creates, 0);
    expect(await store.read((tx) async => tx.mutations()), isEmpty);
  });
  test('removal fences delayed completion, closes resources and affects only its account', () async {
    await seed(store, 'b');
    await store.write((tx) async => tx.putContact(record('b', 'keep')));
    final gate = Completer<ContactsPage>();
    final started = Completer<void>();
    provider.onPage = (cursor, page, _) {
      started.complete();
      return gate.future;
    };
    final syncing = directory.synchronize(source('a').key);
    final observed = expectLater(syncing, throwsA(isA<ContactsException>()));
    await started.future;
    await directory
        .disconnect('a', remove: true)
        .timeout(const Duration(seconds: 1));
    gate.complete(ContactsPage(records: [record('a', 'late')], cursor: 'late'));
    await observed;
    await Future<void>.delayed(Duration.zero);
    expect(provider.closed, isTrue);
    expect(await store.read((tx) async => tx.account('a')), isNull);
    expect(await store.read((tx) async => tx.count()), 1);
  });
  test(
    'normal directory close preserves enabled account for restart',
    () async {
      await directory.close();
      expect(
        (await store.read((tx) async => tx.account('a')))!.enabled,
        isTrue,
      );
    },
  );
  test('confirmed organizational mutation never becomes retryable because discovery failed', () async {
    provider.discoveryFails = true;
    final result = await directory.providerAction('a', const FixtureAction());
    expect(result.state, ContactMutationState.confirmed);
    expect(
      (await store.read((tx) async => tx.mutations())).single.state,
      ContactMutationState.confirmed,
    );
  });
  test(
    'paging loops never prune existing contacts or advance cursor',
    () async {
      await store.write((tx) async => tx.putContact(record('a', 'keep')));
      provider.onPage = (cursor, page, _) async => const ContactsPage(
        records: [],
        nextPage: 'same',
        fullEnumeration: true,
      );
      await expectLater(
        directory.synchronize(source('a').key),
        throwsA(
          isA<ContactsException>().having((e) => e.code, 'code', 'paging-loop'),
        ),
      );
      expect(await store.read((tx) async => tx.count()), 1);
      expect(
        (await store.read((tx) async => tx.syncState(source('a').key)))!.cursor,
        isNull,
      );
    },
  );
  test(
    'one retry owner respects Retry-After and never retries a mutation',
    () async {
      await directory.close();
      final waits = <Duration>[];
      directory = ContactsDirectory(
        store: store,
        delay: (d) async => waits.add(d),
        now: () => DateTime.utc(2026),
      );
      provider = FixtureProvider('a');
      directory.bind(provider);
      provider.onPage = (cursor, page, _) async {
        if (provider.reads < 3)
          throw ContactsException(
            ContactsFailure.throttled,
            '429',
            retryAt: DateTime.utc(2026).add(const Duration(seconds: 2)),
          );
        return const ContactsPage(records: [], cursor: 'success');
      };
      await directory.synchronize(source('a').key);
      expect(provider.reads, 3);
      expect(waits, [const Duration(seconds: 2), const Duration(seconds: 2)]);
      provider.ambiguousCreate = true;
      await directory.create(source('a').key, const ContactPatch());
      expect(provider.creates, 1);
    },
  );
}
