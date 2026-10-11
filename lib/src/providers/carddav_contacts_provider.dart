import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:busystack_dav/carddav.dart';
import 'package:http/http.dart' as http;

import '../domain/models.dart';
import '../domain/records.dart';
import '../persistence/contacts_store.dart';
import '../vcard/vcard.dart';
import '../vcard/conversion.dart';
import 'provider.dart';

enum CardDavBookOperation { create, rename, delete }

final class CardDavBookAction implements ContactProviderAction {
  const CardDavBookAction(
    this.operation, {
    required this.uri,
    this.name = '',
    this.description,
  });
  final CardDavBookOperation operation;
  final Uri uri;
  final String name;
  final String? description;
  @override
  Map<String, Object?> toJson() => {
    'type': 'carddav-book',
    'operation': operation.name,
    'uri': uri.toString(),
    'name': name,
    'description': description,
  };
}

/// Full-resource CardDAV backend, also used by Nextcloud. Authentication and
/// browser setup belong to the consuming app, not to this provider.
final class CardDavContactsProvider implements ContactsProvider {
  CardDavContactsProvider({
    required this.accountId,
    required this.client,
    required this.cachedRecord,
    this.entryUri,
    this.readOnly = false,
    http.Client? publicPhotoClient,
    void Function()? disposeTransport,
  }) : _publicPhotos = publicPhotoClient ?? http.Client(),
       _ownsPhotoClient = publicPhotoClient == null,
       _disposeTransport = disposeTransport;
  @override
  final String accountId;
  final CardDavClient client;
  final Future<ContactRecord?> Function(ContactIdentity) cachedRecord;
  final Uri? entryUri;
  final bool readOnly;
  final http.Client _publicPhotos;
  final bool _ownsPhotoClient;
  final void Function()? _disposeTransport;
  DavDiscoveryResult? _discovery;
  final _sources = <String, ContactSource>{};
  final _unsupportedSync = <String>{};
  @override
  ContactProviderKind get kind => ContactProviderKind.carddav;

  @override
  Future<List<ContactSource>> discover(
    ContactsCancellationToken cancellation,
  ) => _guard(cancellation, (token) async {
    final result = await client.discover(
      entryUri: entryUri,
      cancellation: token,
    );
    _discovery = result;
    _sources.clear();
    for (final collection in result.collections) {
      final book = CardDavAddressBook(collection);
      final versions = book.vcardVersions.intersection({'3.0', '4.0'}).toList();
      if (versions.isEmpty) continue;
      final source = ContactSource(
        accountId: accountId,
        id: collection.uri.toString(),
        provider: kind,
        kind: ContactSourceKind.carddavAddressBook,
        name: collection.displayName,
        remotePath: collection.uri.toString(),
        parentId: result.homeSets
            .where(
              (home) => collection.uri.toString().startsWith(home.toString()),
            )
            .firstOrNull
            ?.toString(),
        versions: versions,
        maximumResourceBytes: book.maximumResourceBytes,
        supportsSync: collection.supportsSync,
        canRename: !readOnly && collection.canRename,
        // Removing an address book requires unbind on its containing home.
        canRemove:
            !readOnly &&
            result.homeProperties.entries.any(
              (home) =>
                  collection.uri.toString().startsWith(home.key.toString()) &&
                  _privilege(home.value, 'unbind'),
            ),
        capabilities: ContactCapabilities(
          read: collection.canRead,
          create: !readOnly && collection.canCreate,
          update: !readOnly && collection.canUpdate,
          delete: !readOnly && collection.canDelete,
          photoRead: collection.canRead,
          photoWrite: !readOnly && collection.canUpdate,
          fields: ContactField.values.toSet(),
          limits: const {ContactField.dates: 2},
        ),
      );
      _sources[source.id] = source;
    }
    return _sources.values.toList();
  });

  /// Eligible home sets for extended MKCOL. An enabled action requires both the
  /// advertised extension and bind privilege on the actual parent collection.
  List<Uri> get creatableHomes {
    final result = _discovery;
    if (readOnly ||
        result == null ||
        !result.features.contains('extended-mkcol'))
      return [];
    return result.homeProperties.entries
        .where((e) => _privilege(e.value, 'bind'))
        .map((e) => e.key)
        .toList();
  }

  bool _privilege(DavMultistatusResponse properties, String name) {
    return client.resources
        .collectionFromProperties(properties, client.resources.authority)
        .hasPrivilege(name);
  }

  @override
  Future<ContactsPage> page(
    ContactSource source, {
    String? cursor,
    String? page,
    required ContactsCancellationToken cancellation,
  }) => _guard(cancellation, (token) async {
    _owned(source);
    final collection = Uri.parse(source.remotePath);
    Map<String, dynamic> checkpoint;
    if (page != null) {
      if (page.length > 16 * 1024 * 1024)
        throw const FormatException('CardDAV checkpoint limit');
      checkpoint = (jsonDecode(page) as Map).cast();
      if (checkpoint['source'] != source.key)
        throw const FormatException('CardDAV checkpoint source mismatch');
    } else {
      var useSync =
          source.supportsSync && !_unsupportedSync.contains(source.id);
      DavSyncResult? synced;
      if (useSync) {
        try {
          synced = await client.resources.syncCollection(
            collection,
            cursor ?? '',
            cancellation: token,
          );
        } on DavException catch (error) {
          if (error.statusCode != 405 && error.statusCode != 501) rethrow;
          // An optional report that the server rejects is not a usable capability.
          _unsupportedSync.add(source.id);
          useSync = false;
        }
      }
      final entries =
          synced?.changed ??
          await client.resources.enumerateEtags(
            collection,
            cancellation: token,
          );
      checkpoint = {
        'source': source.key,
        'entries': entries.entries
            .map((e) => [e.key.toString(), e.value])
            .toList(),
        'deleted': synced?.deleted.map((e) => e.toString()).toList() ?? [],
        'cursor': synced?.syncToken,
        'continueSync': synced?.truncated ?? false,
        'full': !useSync || cursor == null,
      };
    }
    final inventory = (checkpoint['entries'] as List)
        .map((e) => (e as List).cast<String>())
        .toList();
    final batch = inventory.take(10).toList();
    final records = <ContactRecord>[], missing = <Uri>[];
    for (final item in batch) {
      final uri = Uri.parse(item[0]);
      client.resources.requireMember(collection, uri);
      final cached = await cachedRecord(_identity(source, uri));
      if (cached is CardDavContactRecord &&
          cached.complete &&
          cached.revision == item[1]) {
        records.add(cached);
      } else {
        missing.add(uri);
      }
    }
    if (missing.isNotEmpty) {
      final fetched = <DavObject>[];
      // One bounded full-resource GET per changed ETag keeps photos and unknown
      // source properties without assembling a huge multiget body in memory.
      for (final uri in missing) {
        try {
          fetched.add(await client.get(uri, cancellation: token));
        } on DavException catch (error) {
          if (error.kind != DavErrorKind.notFound) rethrow;
        }
      }
      final byUri = {
        for (final object in fetched) object.uri.toString(): object,
      };
      for (final uri in missing) {
        final object = byUri[uri.toString()];
        // A resource removed between enumeration and multiget is a tombstone.
        if (object != null)
          records.add(await _record(source, object));
        else
          (checkpoint['deleted'] as List).add(uri.toString());
      }
    }
    final deleted = (checkpoint['deleted'] as List).cast<String>().map((v) {
      final uri = Uri.parse(v);
      client.resources.requireMember(collection, uri);
      return _identity(source, uri);
    }).toList();
    final remaining = inventory.skip(batch.length).toList();
    String? next;
    if (remaining.isNotEmpty) {
      next = jsonEncode({
        ...checkpoint,
        'entries': remaining,
        'deleted': <String>[],
      });
    } else if (checkpoint['continueSync'] == true) {
      // The intermediate token is durable together with its preceding changes.
      // A tiny checkpoint requests the next server page after restart.
      next = jsonEncode({
        'source': source.key,
        'entries': [],
        'deleted': [],
        'resumeSync': checkpoint['cursor'],
        'full': checkpoint['full'],
      });
    }
    if (checkpoint.containsKey('resumeSync')) {
      return this.page(
        source,
        cursor: checkpoint['resumeSync'] as String,
        cancellation: cancellation,
      );
    }
    return ContactsPage(
      records: records,
      deleted: deleted,
      nextPage: next,
      cursor: next == null ? checkpoint['cursor'] as String? : null,
      fullEnumeration: checkpoint['full'] == true,
    );
  });

  @override
  Future<ContactRecord> get(
    ContactSource source,
    ContactIdentity identity,
    ContactsCancellationToken cancellation,
  ) => _guard(
    cancellation,
    (token) async => _record(
      source,
      await client.get(_member(source, identity), cancellation: token),
    ),
  );

  @override
  Future<ContactRecord> create(
    ContactSource source,
    ContactPatch patch,
    String mutationId,
    ContactsCancellationToken cancellation, {
    String? fullVcard,
  }) => _guard(cancellation, (token) async {
    _require(source, source.capabilities.create);
    source.capabilities.validate(patch);
    final card = fullVcard == null
        ? newVcard(patch, version: _version(source), uid: mutationId)
        : applyVcardPatch(parseVcard(fullVcard), patch);
    _validateCard(source, card);
    final uri = Uri.parse(source.remotePath).resolve(mutationId + '.vcf');
    return _record(
      source,
      await client.put(
        uri,
        card.serialize(),
        create: true,
        cancellation: token,
      ),
    );
  });
  @override
  Future<ContactRecord> update(
    ContactSource source,
    ContactRecord base,
    ContactPatch patch,
    ContactsCancellationToken cancellation,
  ) => _guard(cancellation, (token) async {
    _require(source, source.capabilities.update);
    source.capabilities.validate(patch);
    final uri = _member(source, base.identity);
    if (base is! CardDavContactRecord || !base.complete)
      throw const ContactsException(
        ContactsFailure.validation,
        'complete-vcard-required',
      );
    if (patch.changedFields
        .intersection(base.projection.readOnlyFields)
        .isNotEmpty) {
      throw const ContactsException(
        ContactsFailure.permission,
        'contact-field-read-only',
      );
    }
    final card = applyVcardPatch(base.vcard, patch);
    _validateCard(source, card);
    return _record(
      source,
      await client.put(
        uri,
        card.serialize(),
        etag: base.revision,
        cancellation: token,
      ),
    );
  });
  @override
  Future<void> delete(
    ContactSource source,
    ContactRecord base,
    ContactsCancellationToken cancellation,
  ) => _guard(cancellation, (token) async {
    _require(source, source.capabilities.delete);
    await client.delete(
      _member(source, base.identity),
      etag: base.revision,
      cancellation: token,
    );
  });
  @override
  Future<Uint8List?> photo(
    ContactSource source,
    ContactRecord record,
    ContactsCancellationToken cancellation,
  ) async {
    _owned(source);
    _member(source, record.identity);
    cancellation.throwIfCancelled();
    if (record is! CardDavContactRecord)
      throw const ContactsException(
        ContactsFailure.validation,
        'vcard-required',
      );
    final embedded = record.vcard.embeddedPhoto();
    if (embedded != null) return embedded;
    final uri = record.projection.photo?.url;
    if (uri == null) return null;
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.fragment.isNotEmpty) {
      throw const ContactsException(
        ContactsFailure.unsupported,
        'unsafe-photo-url',
      );
    }
    return readContactPhoto(_publicPhotos, uri, cancellation);
  }

  @override
  Future<ContactRecord> setPhoto(
    ContactSource source,
    ContactRecord base,
    Uint8List? bytes,
    String mediaType,
    ContactsCancellationToken cancellation,
  ) => _guard(cancellation, (token) async {
    _require(source, source.capabilities.photoWrite);
    if (base is! CardDavContactRecord || !base.complete)
      throw const ContactsException(
        ContactsFailure.validation,
        'complete-vcard-required',
      );
    if (bytes != null &&
        (bytes.length > 2 * 1024 * 1024 ||
            !const {'image/jpeg', 'image/png'}.contains(mediaType))) {
      throw const ContactsException(
        ContactsFailure.validation,
        'invalid-photo',
      );
    }
    final replacement = bytes == null
        ? <VCardProperty>[]
        : [
            VCardProperty(
              name: 'PHOTO',
              rawValue: base.vcard.version == '4.0'
                  ? 'data:' + mediaType + ';base64,' + base64Encode(bytes)
                  : base64Encode(bytes),
              parameters: base.vcard.version == '4.0'
                  ? []
                  : [
                      const VCardParameter('ENCODING', ['b']),
                      VCardParameter('TYPE', [
                        mediaType == 'image/jpeg' ? 'JPEG' : 'PNG',
                      ]),
                    ],
            ),
          ];
    final card = base.vcard.replace('PHOTO', replacement);
    _validateCard(source, card);
    return _record(
      source,
      await client.put(
        _member(source, base.identity),
        card.serialize(),
        etag: base.revision,
        cancellation: token,
      ),
    );
  });

  @override
  ContactProviderAction decodeAction(Map<String, dynamic> json) {
    if (json['type'] != 'carddav-book')
      throw const ContactsException(
        ContactsFailure.unsupported,
        'carddav-action',
      );
    return CardDavBookAction(
      CardDavBookOperation.values.byName(json['operation'] as String),
      uri: Uri.parse(json['uri'] as String),
      name: json['name'] as String? ?? '',
      description: json['description'] as String?,
    );
  }

  @override
  Future<ContactActionResult> action(
    ContactProviderAction action,
    ContactsCancellationToken cancellation,
  ) => _guard(cancellation, (token) async {
    if (action is! CardDavBookAction || readOnly)
      throw const ContactsException(
        ContactsFailure.permission,
        'address-book-action-unavailable',
      );
    if (_discovery == null) await discover(cancellation);
    switch (action.operation) {
      case CardDavBookOperation.create:
        if (!creatableHomes.any((home) {
          try {
            client.resources.requireMember(
              home,
              action.uri.replace(
                path: action.uri.path.endsWith('/')
                    ? action.uri.path.substring(0, action.uri.path.length - 1)
                    : action.uri.path,
              ),
            );
            return true;
          } catch (_) {
            return false;
          }
        }))
          throw const ContactsException(
            ContactsFailure.permission,
            'address-book-parent-read-only',
          );
        if (action.name.trim().isEmpty || !action.uri.path.endsWith('/'))
          throw const ContactsException(
            ContactsFailure.validation,
            'address-book-name-required',
          );
        await client.createAddressBook(
          action.uri,
          action.name,
          description: action.description,
          cancellation: token,
        );
      case CardDavBookOperation.rename:
        final source = _sources[action.uri.toString()];
        if (source?.canRename != true || action.name.trim().isEmpty)
          throw const ContactsException(
            ContactsFailure.permission,
            'address-book-rename-unavailable',
          );
        await client.renameAddressBook(
          action.uri,
          action.name,
          cancellation: token,
        );
      case CardDavBookOperation.delete:
        if (_sources[action.uri.toString()]?.canRemove != true)
          throw const ContactsException(
            ContactsFailure.permission,
            'address-book-delete-unavailable',
          );
        await client.deleteAddressBook(action.uri, cancellation: token);
    }
    return const ContactActionResult(discoverSources: true);
  });
  @override
  Future<ContactRecord?> findCreated(
    ContactSource source,
    ContactMutation mutation,
    ContactsCancellationToken cancellation,
  ) async {
    // A deterministic UUID resource plus UID lets us positively reconcile a
    // timed-out create without sending it twice. Absence still means uncertain.
    final uri = Uri.parse(source.remotePath).resolve(mutation.id + '.vcf');
    try {
      final record = await get(
        source,
        _identity(source, uri),
        cancellation,
      ) as CardDavContactRecord;
      final original = mutation.payload['vcard'] as String?;
      final uid = original == null
          ? mutation.id
          : parseVcard(original).text('UID');
      return record.vcard.text('UID') == uid ? record : null;
    } on ContactsException catch (error) {
      if (error.kind == ContactsFailure.notFound) return null;
      rethrow;
    }
  }

  Future<CardDavContactRecord> _record(ContactSource source, DavObject object) {
    final identity = _identity(source, object.uri);
    _member(source, identity);
    return _decodeCardRecord(
      identity,
      object.data,
      object.etag,
      object.complete,
    );
  }

  ContactIdentity _identity(ContactSource source, Uri uri) => ContactIdentity(
    accountId: accountId,
    provider: kind,
    sourceId: source.id,
    remoteId: uri.toString(),
  );
  void _owned(ContactSource source) {
    if (source.accountId != accountId ||
        source.provider != kind ||
        source.remotePath != source.id)
      throw const ContactsException(
        ContactsFailure.permission,
        'source-ownership',
      );
  }

  Uri _member(ContactSource source, ContactIdentity identity) {
    _owned(source);
    if (identity.accountId != accountId ||
        identity.provider != kind ||
        identity.sourceId != source.id) {
      throw const ContactsException(
        ContactsFailure.permission,
        'contact-ownership',
      );
    }
    final uri = Uri.parse(identity.remoteId);
    client.resources.requireMember(Uri.parse(source.remotePath), uri);
    return uri;
  }

  void _require(ContactSource source, bool permitted) {
    _owned(source);
    if (readOnly || !permitted)
      throw const ContactsException(
        ContactsFailure.permission,
        'source-read-only',
      );
  }

  String _version(ContactSource source) =>
      source.versions.contains('4.0') ? '4.0' : '3.0';
  void _validateCard(ContactSource source, VCardDocument card) {
    if (!card.complete || !source.versions.contains(card.version))
      throw const ContactsException(
        ContactsFailure.validation,
        'unsupported-vcard-version',
      );
    if (card.values('UID').length != 1 || card.text('UID')!.isEmpty)
      throw const ContactsException(
        ContactsFailure.validation,
        'carddav-uid-required',
      );
    try {
      final serialized = card.serialize();
      final bytes = utf8.encode(serialized);
      if (bytes.length > (source.maximumResourceBytes ?? 4 * 1024 * 1024) ||
          bytes.length > 4 * 1024 * 1024)
        throw const ContactsException(
          ContactsFailure.validation,
          'vcard-resource-limit',
        );
      parseVcard(serialized); // Required fields and photo limits.
    } on FormatException {
      // Local serialization/format failures happen before client.put dispatch.
      // They are confirmed validation failures, not remote protocol failures or
      // an uncertain write that would require reconciliation.
      throw const ContactsException(
        ContactsFailure.validation,
        'invalid-vcard',
      );
    }
  }

  Future<T> _guard<T>(
    ContactsCancellationToken cancellation,
    Future<T> Function(DavCancellationToken) action,
  ) async {
    cancellation.throwIfCancelled();
    final token = DavCancellationToken();
    final sub = cancellation.cancellations.listen((_) => token.cancel());
    try {
      return await action(token);
    } on DavException catch (error) {
      throw ContactsException(
        switch (error.kind) {
          DavErrorKind.cancelled => ContactsFailure.cancelled,
          DavErrorKind.authentication => ContactsFailure.authentication,
          DavErrorKind.authorization => ContactsFailure.permission,
          DavErrorKind.notFound => ContactsFailure.notFound,
          DavErrorKind.conflict ||
          DavErrorKind.preconditionFailed => ContactsFailure.conflict,
          DavErrorKind.invalidSyncToken => ContactsFailure.expiredCursor,
          DavErrorKind.rateLimited => ContactsFailure.throttled,
          DavErrorKind.unknownOutcome => ContactsFailure.unknownOutcome,
          DavErrorKind.network ||
          DavErrorKind.timeout => ContactsFailure.offline,
          DavErrorKind.server => ContactsFailure.server,
          _ => ContactsFailure.protocol,
        },
        error.code,
        retryAt: error.retryAfter == null
            ? null
            : DateTime.now().toUtc().add(error.retryAfter!),
      );
    } on FormatException {
      throw const ContactsException(
        ContactsFailure.protocol,
        'invalid-carddav-data',
      );
    } finally {
      await sub.cancel();
    }
  }

  @override
  void close() {
    _disposeTransport?.call();
    if (_ownsPhotoClient) _publicPhotos.close();
  }
}

Future<CardDavContactRecord> _decodeCardRecord(
  ContactIdentity identity,
  String data,
  String etag,
  bool complete,
) => Isolate.run(() {
  final card = parseVcard(data, complete: complete);
  return CardDavContactRecord(
    identity: identity,
    revision: etag,
    vcard: card,
    projection: projectVcard(identity, card),
  );
});
