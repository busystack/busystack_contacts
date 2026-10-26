import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import '../domain/records.dart';
import '../persistence/contacts_store.dart';
import '../providers/provider.dart';

final class ContactRecipient {
  const ContactRecipient(this.name, this.email, this.identities);
  final String name, email;
  final List<ContactIdentity> identities;
}

/// Account-scoped sync/mutation coordination. A store and provider binding are
/// private to each consuming application instance.
final class ContactsDirectory {
  ContactsDirectory({
    required this.store,
    this.maximumConcurrentAccounts = 3,
    this.maximumReadAttempts = 3,
    Future<void> Function(Duration)? delay,
    DateTime Function()? now,
  }) : _delay = delay ?? Future<void>.delayed,
       _now = now ?? (() => DateTime.now().toUtc()) {
    if (maximumConcurrentAccounts < 1)
      throw ArgumentError.value(maximumConcurrentAccounts);
  }
  final ContactsStore store;
  final int maximumConcurrentAccounts;
  final int maximumReadAttempts;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;
  final _providers = <String, ContactsProvider>{};
  final _tails = <String, Future<void>>{};
  final _epochs = <String, int>{};
  final _bindingGenerations = <String, int?>{};
  final _operationGenerations = <String, int>{};
  final _active = <String, Set<ContactsCancellationToken>>{};
  final _slots = <Completer<void>>[];
  final _uuid = const Uuid();
  int _running = 0;
  bool _closed = false;
  Future<void>? _closeFuture;
  Stream<void> get changes => store.changes;

  void bind(ContactsProvider provider, {int? accountGeneration}) {
    if (_closed) throw StateError('Directory closed');
    if (_providers.containsKey(provider.accountId))
      throw StateError('Drain the old account binding first');
    _providers[provider.accountId] = provider;
    _bindingGenerations[provider.accountId] = accountGeneration;
  }

  Future<void> restore() => store.write((tx) async {
    for (final mutation in await tx.mutations()) {
      if (mutation.state == ContactMutationState.executing) {
        await tx.putMutation(
          mutation.copy(
            state: ContactMutationState.unknown,
            errorCode: 'interrupted-after-dispatch',
          ),
        );
      }
    }
  });
  Future<List<ContactRecord>> search(
    String query, {
    String? accountId,
    String? sourceKey,
    int limit = 100,
    int offset = 0,
  }) => store.read(
    (tx) async => tx.contacts(
      query: query,
      accountId: accountId,
      sourceKey: sourceKey,
      limit: limit,
      offset: offset,
    ),
  );
  Future<List<ContactProjection>> browse(
    String query, {
    String? accountId,
    String? sourceKey,
    int limit = 100,
    int offset = 0,
  }) => store.read(
    (tx) async => tx.projections(
      query: query,
      accountId: accountId,
      sourceKey: sourceKey,
      limit: limit,
      offset: offset,
    ),
  );
  Future<List<ContactRecipient>> suggestRecipients(
    String query, {
    required Set<String> accountIds,
    Set<String> sourceKeys = const {},
    Set<String> excludedAddresses = const {},
    int limit = 8,
  }) async {
    if (limit < 1 || limit > 100) throw RangeError.value(limit);
    return store.read((tx) async {
      const pageSize = 100;
      final grouped = <String, ContactRecipient>{};
      final seen = <ContactIdentity>{};
      final needle = query.toLowerCase();
      final excluded = excludedAddresses
          .map((value) => value.trim().toLowerCase())
          .toSet();
      for (final account in accountIds) {
        final selectedSources = sourceKeys.isEmpty
            ? <String?>[null]
            : (await tx.sources(accountId: account))
                  .where((source) => sourceKeys.contains(source.key))
                  .map<String?>((source) => source.key)
                  .toList();
        for (final source in selectedSources) {
          var offset = 0;
          int? matchingCount;
          while (true) {
            final records = await tx.projections(
              query: query,
              accountId: account,
              sourceKey: source,
              limit: pageSize,
              offset: offset,
            );
            for (final record in records) {
              if (!seen.add(record.identity) ||
                  !record.searchText.contains(needle)) {
                continue;
              }
              for (final email in record.emails) {
                final address = email.value.trim();
                final key = address.toLowerCase();
                if (key.isEmpty || excluded.contains(key)) continue;
                final old = grouped[key];
                if (old == null && grouped.length == limit) continue;
                grouped[key] = ContactRecipient(
                  old?.name ?? record.displayName,
                  address,
                  [
                    ...?old?.identities,
                    if (old == null ||
                        !old.identities.contains(record.identity))
                      record.identity,
                  ],
                );
              }
            }
            // Finish the fetched page to retain aliases without another read.
            if (grouped.length == limit) return grouped.values.toList();
            if (records.length < pageSize) break;
            offset += records.length;
            // Count only when another page is needed. The same read transaction
            // provides a finite snapshot bound even if a store repeats rows.
            matchingCount ??= await tx.count(
              query: query,
              accountId: account,
              sourceKey: source,
            );
            if (offset >= matchingCount) break;
          }
        }
      }
      return grouped.values.toList();
    });
  }

  Future<List<ContactSource>> discover(String accountId) => _serial(accountId, (
    provider,
    token,
    epoch,
  ) async {
    final sources = await _readRetry(() => provider.discover(token), token);
    await _writeFenced(accountId, epoch, token, (tx) async {
      for (final source in sources) {
        if (source.accountId != accountId || source.provider != provider.kind)
          throw StateError('Provider source ownership');
        await tx.putSource(source);
      }
      // Removed sources with pending work stay visible for recovery.
      final keys = sources.map((s) => s.key).toSet();
      for (final old in await tx.sources(accountId: accountId)) {
        if (!keys.contains(old.key) &&
            !(await tx.mutations(sourceKey: old.key)).any(_unresolved)) {
          await tx.removeSource(old.key);
        }
      }
    });
    return sources;
  });

  Future<void> synchronize(String sourceKey) async {
    final source = await _source(sourceKey);
    return _serial(source.accountId, (provider, token, epoch) async {
      var state =
          await store.read((tx) async => tx.syncState(sourceKey)) ??
          ContactSyncState(sourceKey: sourceKey);
      var scan = state.scanId ?? _uuid.v7();
      var page = state.page;
      var cursor = state.scanId == null ? state.cursor : state.scanCursor;
      var full = state.scanId == null ? state.cursor == null : state.full;
      var recoveredExpired = false;
      final visited = <String>{};
      while (true) {
        token.throwIfCancelled();
        ContactsPage batch;
        try {
          batch = await _readRetry(
            () => provider.page(
              source,
              cursor: cursor,
              page: page,
              cancellation: token,
            ),
            token,
          );
        } on ContactsException catch (error) {
          if (error.kind == ContactsFailure.expiredCursor &&
              !recoveredExpired) {
            // Retain all cached contacts/pending edits until a complete new scan.
            recoveredExpired = true;
            cursor = null;
            page = null;
            full = true;
            scan = _uuid.v7();
            await _writeFenced(
              source.accountId,
              epoch,
              token,
              (tx) async => tx.putSyncState(
                ContactSyncState(
                  sourceKey: sourceKey,
                  cursor: state.cursor,
                  scanId: scan,
                  full: true,
                ),
              ),
            );
            continue;
          }
          await _writeFenced(source.accountId, epoch, token, (tx) async {
            final current = await tx.syncState(sourceKey);
            await tx.putSyncState(
              ContactSyncState(
                sourceKey: sourceKey,
                cursor: current?.cursor ?? state.cursor,
                scanId: scan,
                scanCursor: cursor,
                page: page,
                full: full,
                lastSync: current?.lastSync,
                errorCode: error.code,
              ),
            );
          });
          rethrow;
        }
        full = full || batch.fullEnumeration;
        final finished = batch.nextPage == null;
        if (!finished &&
            (!visited.add(batch.nextPage!) || batch.nextPage == page)) {
          throw const ContactsException(
            ContactsFailure.protocol,
            'paging-loop',
          );
        }
        await _writeFenced(source.accountId, epoch, token, (tx) async {
          final mutations = await tx.mutations(sourceKey: sourceKey);
          final protected = <String>{};
          for (final mutation in mutations) {
            if (_unresolved(mutation) && mutation.identity != null)
              protected.add(mutation.identity!.key);
            if (mutation.state == ContactMutationState.confirmed &&
                mutation.result != null) {
              protected.add(mutation.result!.identity.key);
            }
          }
          for (final incoming in batch.records) {
            if (incoming.identity.accountId != source.accountId ||
                incoming.identity.sourceId != source.id) {
              throw const ContactsException(
                ContactsFailure.protocol,
                'record-ownership',
              );
            }
            final unresolved = mutations
                .where((m) => _unresolved(m) && m.identity == incoming.identity)
                .firstOrNull;
            if (unresolved != null) {
              await tx.putContact(
                await tx.contact(incoming.identity) ?? incoming,
                seenScan: scan,
              );
              if (unresolved.base?.revision != incoming.revision) {
                await tx.putMutation(
                  unresolved.copy(
                    state: ContactMutationState.conflict,
                    remote: incoming,
                    errorCode: 'remote-changed-during-pending-edit',
                  ),
                );
              }
              continue;
            }
            final confirmed = mutations
                .where(
                  (m) =>
                      m.state == ContactMutationState.confirmed &&
                      m.result?.identity == incoming.identity,
                )
                .firstOrNull;
            if (confirmed != null &&
                incoming.revision == confirmed.base?.revision &&
                incoming.revision != confirmed.result!.revision) {
              await tx.putContact(confirmed.result!, seenScan: scan);
              continue;
            }
            if (confirmed != null &&
                incoming.revision == confirmed.result!.revision) {
              await tx.deleteMutation(confirmed.id);
            }
            await tx.putContact(incoming, seenScan: scan);
          }
          for (final deleted in batch.deleted) {
            final mutation = mutations
                .where((m) => m.identity == deleted && _unresolved(m))
                .firstOrNull;
            if (mutation != null) {
              await tx.putMutation(
                mutation.copy(
                  state: ContactMutationState.conflict,
                  errorCode: 'remote-deleted',
                ),
              );
            } else if (!protected.contains(deleted.key)) {
              await tx.deleteContact(deleted);
            }
          }
          if (finished && full) {
            await tx.pruneUnseen(sourceKey, scan, protected);
          }
          await tx.putSyncState(
            ContactSyncState(
              sourceKey: sourceKey,
              cursor: finished ? batch.cursor : state.cursor,
              page: batch.nextPage,
              scanCursor: finished ? null : cursor,
              scanId: finished ? null : scan,
              full: full,
              lastSync: finished ? DateTime.now().toUtc() : state.lastSync,
            ),
          );
        });
        if (finished) break;
        page = batch.nextPage;
      }
    });
  }

  Future<ContactMutation> create(
    String sourceKey,
    ContactPatch patch, {
    String? fullVcard,
    void Function(ContactMutation)? onStaged,
  }) async {
    final source = await _source(sourceKey);
    if (!source.capabilities.create)
      throw const ContactsException(
        ContactsFailure.permission,
        'source-read-only',
      );
    source.capabilities.validate(patch);
    final mutation = ContactMutation(
      id: _uuid.v7(),
      accountId: source.accountId,
      sourceKey: sourceKey,
      kind: ContactMutationKind.create,
      state: ContactMutationState.queued,
      createdAt: DateTime.now().toUtc(),
      patch: patch,
      payload: {'vcard': ?fullVcard},
    );
    await _stage(mutation);
    onStaged?.call(mutation);
    return retry(mutation.id);
  }

  Future<ContactMutation> update(
    ContactRecord base,
    ContactPatch patch, {
    void Function(ContactMutation)? onStaged,
  }) async {
    if (patch.changedFields
        .intersection(base.projection.readOnlyFields)
        .isNotEmpty) {
      throw const ContactsException(
        ContactsFailure.permission,
        'contact-field-read-only',
      );
    }
    final source = await _sourceFor(base.identity);
    if (!source.capabilities.update)
      throw const ContactsException(
        ContactsFailure.permission,
        'source-read-only',
      );
    source.capabilities.validate(patch);
    if (patch.changedFields.isEmpty)
      throw const ContactsException(ContactsFailure.validation, 'no-changes');
    return _stageAndRun(
      ContactMutation(
        id: _uuid.v7(),
        accountId: source.accountId,
        sourceKey: source.key,
        identity: base.identity,
        base: base,
        patch: patch,
        kind: ContactMutationKind.update,
        state: ContactMutationState.queued,
        createdAt: DateTime.now().toUtc(),
      ),
      onStaged: onStaged,
    );
  }

  Future<ContactMutation> delete(ContactRecord base) async {
    final source = await _sourceFor(base.identity);
    if (!source.capabilities.delete)
      throw const ContactsException(
        ContactsFailure.permission,
        'source-read-only',
      );
    return _stageAndRun(
      ContactMutation(
        id: _uuid.v7(),
        accountId: source.accountId,
        sourceKey: source.key,
        identity: base.identity,
        base: base,
        kind: ContactMutationKind.delete,
        state: ContactMutationState.queued,
        createdAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<ContactMutation> setPhoto(
    ContactRecord base,
    Uint8List? photo,
    String mediaType,
  ) async {
    final source = await _sourceFor(base.identity);
    if (!source.capabilities.photoWrite)
      throw const ContactsException(
        ContactsFailure.unsupported,
        'photo-read-only',
      );
    if (photo != null && photo.length > 2 * 1024 * 1024)
      throw const ContactsException(ContactsFailure.validation, 'photo-limit');
    return _stageAndRun(
      ContactMutation(
        id: _uuid.v7(),
        accountId: source.accountId,
        sourceKey: source.key,
        identity: base.identity,
        base: base,
        kind: ContactMutationKind.photo,
        state: ContactMutationState.queued,
        createdAt: DateTime.now().toUtc(),
        payload: {
          'bytes': photo == null ? null : base64Encode(photo),
          'mediaType': mediaType,
        },
      ),
    );
  }

  Future<ContactMutation> providerAction(
    String accountId,
    ContactProviderAction action,
  ) => _stageAndRun(
    ContactMutation(
      id: _uuid.v7(),
      accountId: accountId,
      sourceKey: '',
      kind: ContactMutationKind.providerAction,
      state: ContactMutationState.queued,
      createdAt: DateTime.now().toUtc(),
      payload: action.toJson(),
    ),
  );

  Future<ContactMutation> _stageAndRun(
    ContactMutation mutation, {
    void Function(ContactMutation)? onStaged,
  }) async {
    await _stage(mutation);
    onStaged?.call(mutation);
    return retry(mutation.id);
  }

  Future<void> _stage(ContactMutation mutation) => store.write((tx) async {
    final account = await tx.account(mutation.accountId);
    if (account == null || !account.enabled)
      throw const ContactsException(
        ContactsFailure.cancelled,
        'account-disabled',
      );
    if (mutation.identity != null &&
        (await tx.mutations(accountId: mutation.accountId))
            .any((m) => _unresolved(m) && m.identity == mutation.identity))
      throw const ContactsException(
        ContactsFailure.conflict,
        'pending-change-exists',
      );
    await tx.putMutation(mutation);
  });

  Future<ContactMutation> retry(String id) async {
    final mutation = await _mutation(id);
    if (mutation.state == ContactMutationState.unknown ||
        mutation.state == ContactMutationState.executing ||
        mutation.state == ContactMutationState.conflict ||
        mutation.state == ContactMutationState.confirmed)
      return mutation;
    return _serial(mutation.accountId, (provider, token, epoch) async {
      final current = await _mutation(id);
      if (current.state == ContactMutationState.confirmed ||
          current.state == ContactMutationState.unknown ||
          current.state == ContactMutationState.conflict)
        return current;
      final source = current.kind == ContactMutationKind.providerAction
          ? null
          : await _source(current.sourceKey);
      await _writeFenced(
        current.accountId,
        epoch,
        token,
        (tx) async =>
            tx.putMutation(current.copy(state: ContactMutationState.executing)),
      );
      try {
        ContactRecord? result;
        var needsDiscovery = false;
        switch (current.kind) {
          case ContactMutationKind.create:
            result = await provider.create(
              source!,
              current.patch!,
              current.id,
              token,
              fullVcard: current.payload['vcard'] as String?,
            );
          case ContactMutationKind.update:
            result = await provider.update(
              source!,
              current.base!,
              current.patch!,
              token,
            );
          case ContactMutationKind.delete:
            await provider.delete(source!, current.base!, token);
          case ContactMutationKind.photo:
            result = await provider.setPhoto(
              source!,
              current.base!,
              current.payload['bytes'] == null
                  ? null
                  : base64Decode(current.payload['bytes'] as String),
              current.payload['mediaType'] as String,
              token,
            );
          case ContactMutationKind.providerAction:
            final outcome = await provider.action(
              provider.decodeAction(current.payload.cast()),
              token,
            );
            needsDiscovery = outcome.discoverSources;
            await _writeFenced(current.accountId, epoch, token, (tx) async {
              for (final record in outcome.records) {
                await tx.putContact(record);
              }
            });
        }
        final confirmed = current.copy(
          state: ContactMutationState.confirmed,
          result: result,
        );
        await _writeFenced(current.accountId, epoch, token, (tx) async {
          if (result != null) await tx.putContact(result);
          if (current.kind == ContactMutationKind.delete) {
            await tx.deleteContact(current.identity!);
          }
          await tx.putMutation(confirmed);
        });
        if (needsDiscovery) {
          // A failed follow-up read must never turn a confirmed mutation into a
          // retryable failure and duplicate a newly created folder/group/book.
          try {
            final sources = await _readRetry(
              () => provider.discover(token),
              token,
            );
            await _writeFenced(current.accountId, epoch, token, (tx) async {
              for (final source in sources) {
                await tx.putSource(source);
              }
            });
          } catch (_) {
            /* The normal account sync refreshes source discovery. */
          }
        }
        return confirmed;
      } catch (error) {
        final failure = error is ContactsException
            ? error
            : const ContactsException(
                ContactsFailure.unknownOutcome,
                'mutation-needs-reconciliation',
              );
        ContactRecord? remote;
        if (failure.kind == ContactsFailure.conflict &&
            current.identity != null &&
            source != null) {
          try {
            remote = await provider.get(source, current.identity!, token);
          } catch (_) {
            /* Keep the original. */
          }
        }
        final failed = current.copy(
          state: switch (failure.kind) {
            ContactsFailure.conflict => ContactMutationState.conflict,
            ContactsFailure.unknownOutcome ||
            ContactsFailure.cancelled => ContactMutationState.unknown,
            _ => ContactMutationState.failed,
          },
          remote: remote,
          errorCode: failure.code,
        );
        // During disconnect, preserve uncertainty only while this account still exists.
        await store.write((tx) async {
          if ((_epochs[current.accountId] ?? 0) == epoch &&
              (await tx.account(current.accountId))?.generation ==
                  _operationGenerations[current.accountId] &&
              (await tx.mutations(accountId: current.accountId))
                  .any((m) => m.id == id)) {
            await tx.putMutation(failed);
          }
        });
        return failed;
      }
    });
  }

  Future<ContactMutation> reconcile(String id) async {
    final mutation = await _mutation(id);
    if (mutation.state != ContactMutationState.unknown) return mutation;
    return _serial(mutation.accountId, (provider, token, epoch) async {
      final source = mutation.sourceKey.isEmpty
          ? null
          : await _source(mutation.sourceKey);
      ContactRecord? remote;
      if (mutation.kind == ContactMutationKind.create) {
        remote = await provider.findCreated(source!, mutation, token);
        if (remote == null)
          return mutation; // Never automatically replay an uncertain create.
      } else if (mutation.identity != null) {
        try {
          remote = await provider.get(source!, mutation.identity!, token);
        } on ContactsException catch (error) {
          if (error.kind == ContactsFailure.notFound &&
              mutation.kind == ContactMutationKind.delete) {
            final confirmed = mutation.copy(
              state: ContactMutationState.confirmed,
            );
            await _writeFenced(mutation.accountId, epoch, token, (tx) async {
              await tx.deleteContact(mutation.identity!);
              await tx.putMutation(confirmed);
            });
            return confirmed;
          }
          rethrow;
        }
        // Fetching does not prove a timed-out PATCH/photo operation succeeded.
        final conflict = mutation.copy(
          state: ContactMutationState.conflict,
          remote: remote,
          errorCode: 'review-remote-result',
        );
        await _writeFenced(
          mutation.accountId,
          epoch,
          token,
          (tx) async => tx.putMutation(conflict),
        );
        return conflict;
      } else {
        return mutation;
      }
      final confirmed = mutation.copy(
        state: ContactMutationState.confirmed,
        result: remote,
      );
      await _writeFenced(mutation.accountId, epoch, token, (tx) async {
        await tx.putContact(remote!);
        await tx.putMutation(confirmed);
      });
      return confirmed;
    });
  }

  /// Explicitly retain the remote record, or rebase only the selected edit fields.
  Future<ContactMutation?> resolveConflict(
    String id, {
    required bool applyLocalFields,
  }) async {
    final conflict = await _mutation(id);
    if (conflict.state == ContactMutationState.conflict &&
        conflict.errorCode == 'remote-deleted' &&
        !applyLocalFields) {
      await store.write((tx) async {
        await tx.deleteContact(conflict.identity!);
        await tx.deleteMutation(id);
      });
      return null;
    }
    if (conflict.state != ContactMutationState.conflict ||
        conflict.remote == null) {
      throw const ContactsException(
        ContactsFailure.conflict,
        'remote-review-required',
      );
    }
    await store.write((tx) async {
      await tx.putContact(conflict.remote!);
      await tx.deleteMutation(id);
    });
    if (!applyLocalFields) return null;
    return switch (conflict.kind) {
      ContactMutationKind.update => update(conflict.remote!, conflict.patch!),
      ContactMutationKind.delete => delete(conflict.remote!),
      ContactMutationKind.photo => setPhoto(
        conflict.remote!,
        conflict.payload['bytes'] == null
            ? null
            : base64Decode(conflict.payload['bytes'] as String),
        conflict.payload['mediaType'] as String,
      ),
      _ => throw const ContactsException(
        ContactsFailure.unsupported,
        'manual-create-reconciliation-required',
      ),
    };
  }

  Future<void> acceptUnknownCreate(
    String id,
    ContactRecord confirmedRemote,
  ) async {
    final mutation = await _mutation(id);
    if (mutation.kind != ContactMutationKind.create ||
        mutation.state != ContactMutationState.unknown ||
        confirmedRemote.identity.accountId != mutation.accountId ||
        (await _source(mutation.sourceKey)).id !=
            confirmedRemote.identity.sourceId) {
      throw const ContactsException(
        ContactsFailure.validation,
        'invalid-create-resolution',
      );
    }
    final source = await _source(mutation.sourceKey);
    await _serial(mutation.accountId, (provider, token, epoch) async {
      final fresh = await provider.get(source, confirmedRemote.identity, token);
      await _writeFenced(mutation.accountId, epoch, token, (tx) async {
        await tx.putContact(fresh);
        await tx.putMutation(
          mutation.copy(state: ContactMutationState.confirmed, result: fresh),
        );
      });
    });
  }

  Future<void> discardFailedChange(String id) async {
    final mutation = await _mutation(id);
    if (mutation.state == ContactMutationState.executing)
      throw const ContactsException(
        ContactsFailure.conflict,
        'operation-in-progress',
      );
    await store.write((tx) async => tx.deleteMutation(id));
  }

  Future<Uint8List?> loadPhoto(ContactRecord record) async {
    final source = await _sourceFor(record.identity);
    if (!source.capabilities.photoRead) return null;
    return _serial(
      record.identity.accountId,
      (provider, token, _) => provider.photo(source, record, token),
    );
  }

  Future<List<ContactMutation>> resumeQueued(String accountId) async {
    final mutations = await store.read(
      (tx) async => tx.mutations(accountId: accountId),
    );
    final results = <ContactMutation>[];
    for (final mutation in mutations.where(
      (m) => m.state == ContactMutationState.queued,
    )) {
      results.add(await retry(mutation.id));
    }
    return results;
  }

  Future<void> saveDraft(ContactDraft draft) =>
      store.write((tx) async => tx.putDraft(draft));
  Future<void> deleteDraft(String id) =>
      store.write((tx) async => tx.deleteDraft(id));

  /// Cancels and drains a provider binding without changing account enrollment.
  /// Applications use this after a staged replacement has committed. Consent
  /// failures never need to interrupt the still-working binding.
  Future<void> detach(String accountId) async {
    _epochs[accountId] = (_epochs[accountId] ?? 0) + 1;
    for (final token
        in _active[accountId]?.toList() ?? <ContactsCancellationToken>[]) {
      token.cancel();
    }
    final provider = _providers.remove(accountId);
    _bindingGenerations.remove(accountId);
    Object? failure;
    StackTrace? failureStack;
    try {
      provider?.close();
    } on Object catch (error, stack) {
      failure = error;
      failureStack = stack;
    }
    await (_tails[accountId] ?? Future.value());
    await store.write((tx) async {
      for (final mutation in await tx.mutations(accountId: accountId)) {
        if (mutation.state == ContactMutationState.executing) {
          await tx.putMutation(
            mutation.copy(
              state: ContactMutationState.unknown,
              errorCode: 'disconnected-after-dispatch',
            ),
          );
        }
      }
    });
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }

  Future<void> disconnect(String accountId, {bool remove = false}) async {
    await detach(accountId);
    await store.write((tx) async {
      if (remove) {
        await tx.removeAccount(accountId);
      } else {
        for (final mutation in await tx.mutations(accountId: accountId)) {
          if (mutation.state == ContactMutationState.executing)
            await tx.putMutation(
              mutation.copy(
                state: ContactMutationState.unknown,
                errorCode: 'disconnected-after-dispatch',
              ),
            );
        }
        final account = await tx.account(accountId);
        if (account != null)
          await tx.putAccount(
            account.copy(enabled: false, generation: account.generation + 1),
          );
      }
    });
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    final failures = <Object>[];
    StackTrace? firstStack;
    for (final id in _providers.keys.toList()) {
      _epochs[id] = (_epochs[id] ?? 0) + 1;
      for (final token
          in _active[id]?.toList() ?? <ContactsCancellationToken>[]) {
        token.cancel();
      }
      try {
        _providers.remove(id)?.close();
      } on Object catch (error, stack) {
        failures.add(error);
        firstStack ??= stack;
      }
    }
    await Future.wait(_tails.values);
    if (failures.length == 1)
      Error.throwWithStackTrace(failures.single, firstStack!);
    if (failures.isNotEmpty)
      Error.throwWithStackTrace(
        ContactsDirectoryCleanupFailure(failures),
        firstStack!,
      );
  }

  Future<ContactSource> _source(String key) async =>
      await store.read<ContactSource?>((tx) async => tx.source(key)) ??
      (throw const ContactsException(
        ContactsFailure.notFound,
        'source-not-found',
      ));
  Future<ContactSource> _sourceFor(ContactIdentity id) =>
      _source(jsonEncode([id.accountId, id.provider.name, id.sourceId]));
  Future<ContactMutation> _mutation(String id) async =>
      await store.read<ContactMutation?>(
        (tx) async =>
            (await tx.mutations()).where((m) => m.id == id).firstOrNull,
      ) ??
      (throw const ContactsException(
        ContactsFailure.notFound,
        'mutation-not-found',
      ));
  bool _unresolved(ContactMutation m) =>
      m.state != ContactMutationState.confirmed;

  /// This coordinator owns contact read retries. Provider transports supplied
  /// to it must use one attempt. Dispatched mutations are never retried here.
  Future<T> _readRetry<T>(
    Future<T> Function() action,
    ContactsCancellationToken token,
  ) async {
    for (var attempt = 1; ; attempt++) {
      token.throwIfCancelled();
      try {
        return await action();
      } on ContactsException catch (error) {
        if (attempt >= maximumReadAttempts ||
            !const {
              ContactsFailure.throttled,
              ContactsFailure.offline,
              ContactsFailure.server,
            }.contains(error.kind))
          rethrow;
        final duration =
            error.retryAt?.difference(_now()) ??
            Duration(milliseconds: 250 * (1 << (attempt - 1)));
        // Longer provider deadlines remain visible for the application's later
        // scheduled sync; never retry earlier than the server requested.
        if (duration > const Duration(minutes: 1)) rethrow;
        await Future.any<void>([
          _delay(duration.isNegative ? Duration.zero : duration),
          token.whenCancelled.then((_) => token.throwIfCancelled()),
        ]);
      }
    }
  }

  Future<void> _writeFenced(
    String account,
    int epoch,
    ContactsCancellationToken token,
    Future<void> Function(ContactsWriteTransaction) action,
  ) async {
    token.throwIfCancelled();
    if ((_epochs[account] ?? 0) != epoch)
      throw const ContactsException(
        ContactsFailure.cancelled,
        'stale-account-operation',
      );
    await store.write((tx) async {
      if ((await tx.account(account))?.enabled != true ||
          (await tx.account(account))?.generation !=
              _operationGenerations[account] ||
          (_epochs[account] ?? 0) != epoch) {
        throw const ContactsException(
          ContactsFailure.cancelled,
          'stale-account-operation',
        );
      }
      await action(tx);
      token.throwIfCancelled();
      if ((await tx.account(account))?.enabled != true ||
          (await tx.account(account))?.generation !=
              _operationGenerations[account] ||
          (_epochs[account] ?? 0) != epoch) {
        throw const ContactsException(
          ContactsFailure.cancelled,
          'stale-account-operation',
        );
      }
    });
  }

  Future<T> _serial<T>(
    String accountId,
    Future<T> Function(ContactsProvider, ContactsCancellationToken, int) action,
  ) {
    final epoch = _epochs[accountId] ?? 0;
    // The success-only tail belongs to the root zone. Flutter's widget-test
    // zone can pause after it observes the operation result; chaining the tail
    // from that result would then make shutdown wait forever. Provider work and
    // its errors still run in the caller's zone.
    final done = Zone.root.run(Completer<void>.new);
    final result = (_tails[accountId] ?? Future.value()).then<T>((_) async {
      try {
        if (_closed || (_epochs[accountId] ?? 0) != epoch) {
          throw const ContactsException(
            ContactsFailure.cancelled,
            'account-disconnected',
          );
        }
        final provider = _providers[accountId];
        final account = await store.read((tx) => tx.account(accountId));
        final bindingGeneration = _bindingGenerations[accountId];
        if (bindingGeneration != null &&
            account?.generation != bindingGeneration) {
          throw const ContactsException(
            ContactsFailure.cancelled,
            'stale-account-binding',
          );
        }
        if (provider == null || account?.enabled != true) {
          throw const ContactsException(
            ContactsFailure.authentication,
            'account-not-connected',
          );
        }
        if (_running >= maximumConcurrentAccounts) {
          final slot = Completer<void>();
          _slots.add(slot);
          await slot.future;
        } else {
          _running++;
        }
        _operationGenerations[accountId] = account!.generation;
        final token = ContactsCancellationToken();
        (_active[accountId] ??= {}).add(token);
        try {
          if (_closed || (_epochs[accountId] ?? 0) != epoch) {
            throw const ContactsException(
              ContactsFailure.cancelled,
              'stale-account-operation',
            );
          }
          return await Future.any<T>([
            action(provider, token, epoch),
            token.whenCancelled.then<T>((_) {
              token.throwIfCancelled();
              throw StateError('unreachable');
            }),
          ]);
        } finally {
          _active[accountId]?.remove(token);
          _operationGenerations.remove(accountId);
          if (_slots.isNotEmpty) {
            _slots.removeAt(0).complete();
          } else {
            _running--;
          }
        }
      } finally {
        done.complete();
      }
    });
    _tails[accountId] = done.future;
    return result;
  }
}

/// All provider cleanup diagnostics, in the order they occurred. The first
/// error and its stack are preserved when shutdown must finish other cleanup.
final class ContactsDirectoryCleanupFailure implements Exception {
  ContactsDirectoryCleanupFailure(List<Object> failures)
    : failures = List.unmodifiable(failures);
  final List<Object> failures;
  @override
  String toString() =>
      'Contacts provider cleanup failed: ${failures.join('; ')}';
}
