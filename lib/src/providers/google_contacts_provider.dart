import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:googleapis/people/v1.dart' as people;
import 'package:googleapis/people/v1.dart' show DetailedApiRequestError;
import 'package:http/http.dart' as http;

import '../domain/models.dart';
import '../domain/records.dart';
import '../persistence/contacts_store.dart';
import 'provider.dart';

enum GoogleGroupOperation { create, rename, delete, membership }

final class GoogleGroupAction implements ContactProviderAction {
  const GoogleGroupAction(
    this.operation, {
    this.resourceName,
    this.name,
    this.etag,
    this.add = const [],
    this.remove = const [],
  });
  final GoogleGroupOperation operation;
  final String? resourceName, name, etag;
  final List<String> add, remove;
  @override
  Map<String, Object?> toJson() => {
    'type': 'googleGroup',
    'operation': operation.name,
    'resourceName': resourceName,
    'name': name,
    'etag': etag,
    'add': add,
    'remove': remove,
  };
}

final class GoogleFieldsAction implements ContactProviderAction {
  GoogleFieldsAction({
    required this.identity,
    required this.baseRevision,
    required this.replacement,
    required this.fields,
  });
  final ContactIdentity identity;
  final String baseRevision;
  final people.Person replacement;
  final Set<String> fields;
  @override
  Map<String, Object?> toJson() => {
    'type': 'googleFields',
    'identity': identity.toJson(),
    'revision': baseRevision,
    'replacement': replacement.toJson(),
    'fields': fields.toList(),
  };
}

/// Generated People API, with bounded original-JSON preservation alongside its
/// typed Person model. This package never implements Google OAuth.
final class GoogleContactsProvider implements ContactsProvider {
  GoogleContactsProvider({
    required this.accountId,
    required http.Client authorizedClient,
    required this.grantedScopes,
    http.Client? publicPhotoClient,
  }) : _archive = _PeopleArchiveClient(authorizedClient),
       _photos = publicPhotoClient ?? http.Client(),
       _ownsPhotos = publicPhotoClient == null {
    _api = people.PeopleServiceApi(_archive);
  }
  @override
  final String accountId;
  final Set<String> grantedScopes;
  final _PeopleArchiveClient _archive;
  final http.Client _photos;
  final bool _ownsPhotos;
  late final people.PeopleServiceApi _api;
  @override
  ContactProviderKind get kind => ContactProviderKind.google;
  static const readMask =
      'addresses,ageRanges,biographies,birthdays,calendarUrls,clientData,coverPhotos,'
      'emailAddresses,events,externalIds,genders,imClients,interests,locales,locations,memberships,metadata,'
      'miscKeywords,names,nicknames,occupations,organizations,phoneNumbers,photos,relations,sipAddresses,skills,urls,userDefined';
  static const _sources = ['READ_SOURCE_TYPE_CONTACT'];
  static const _marker = 'io.busystack.contacts/mutation';
  bool get _write =>
      grantedScopes.contains(people.PeopleServiceApi.contactsScope);
  bool get _read =>
      _write ||
      grantedScopes.contains(people.PeopleServiceApi.contactsReadonlyScope);
  ContactSource get personalSource => ContactSource(
    accountId: accountId,
    id: 'personal',
    provider: kind,
    kind: ContactSourceKind.googlePersonal,
    name: 'Personal contacts',
    remotePath: 'people/me',
    supportsSync: true,
    capabilities: ContactCapabilities(
      read: _read,
      create: _write,
      update: _write,
      delete: _write,
      photoRead: _read,
      photoWrite: _write,
      fields: ContactField.values
          .where((f) => f != ContactField.labels)
          .toSet(),
    ),
  );
  @override
  Future<List<ContactSource>> discover(ContactsCancellationToken token) async {
    token.throwIfCancelled();
    if (!_read)
      throw const ContactsException(
        ContactsFailure.authentication,
        'contacts-scope-missing',
      );
    return [personalSource];
  }

  @override
  Future<ContactsPage> page(
    ContactSource source, {
    String? cursor,
    String? page,
    required ContactsCancellationToken cancellation,
  }) => _run(cancellation, () async {
    _owned(source);
    final result = await _api.people.connections.list(
      'people/me',
      pageSize: 100,
      pageToken: page,
      personFields: readMask,
      // The endpoint reference requires the non-token parameters to match the
      // initial request and returns nextSyncToken only when this is true. Keep
      // it on incremental pages as well so successful syncs rotate the cursor.
      requestSyncToken: true,
      sources: _sources,
      syncToken: cursor,
    );
    if (result.nextPageToken == null && result.nextSyncToken == null)
      throw const ContactsException(
        ContactsFailure.protocol,
        'google-sync-token-missing',
      );
    final records = <ContactRecord>[], deleted = <ContactIdentity>[];
    for (final person in result.connections ?? <people.Person>[]) {
      final identity = _identity(person.resourceName!);
      if (person.metadata?.deleted == true) {
        deleted.add(identity);
      } else {
        records.add(_record(person));
      }
    }
    return ContactsPage(
      records: records,
      deleted: deleted,
      nextPage: result.nextPageToken,
      cursor: result.nextSyncToken,
      fullEnumeration: cursor == null,
    );
  });
  @override
  Future<ContactRecord> get(
    ContactSource source,
    ContactIdentity identity,
    ContactsCancellationToken cancellation,
  ) => _run(cancellation, () async {
    _owned(source);
    _ownedIdentity(identity);
    return _record(
      await _api.people.get(
        identity.remoteId,
        personFields: readMask,
        sources: _sources,
      ),
    );
  });
  @override
  Future<ContactRecord> create(
    ContactSource source,
    ContactPatch patch,
    String mutationId,
    ContactsCancellationToken cancellation, {
    String? fullVcard,
  }) => _run(cancellation, () async {
    _requireWrite(source);
    _validate(patch);
    final body = googlePatch(patch);
    body['clientData'] = [
      {'key': _marker, 'value': mutationId},
    ];
    return _record(
      await _api.people.createContact(
        _ContactWritePerson(body),
        personFields: readMask,
        sources: _sources,
      ),
    );
  }, mutation: true);
  @override
  Future<ContactRecord> update(
    ContactSource source,
    ContactRecord base,
    ContactPatch patch,
    ContactsCancellationToken cancellation,
  ) => _run(cancellation, () async {
    _requireWrite(source);
    _validate(patch);
    if (base is! GoogleContactRecord || !base.complete)
      throw const ContactsException(
        ContactsFailure.validation,
        'full-google-record-required',
      );
    final body = googlePatch(patch, base: base.nativeDocument);
    return _writeFields(base, body, body.keys.toSet().difference({'metadata'}));
  }, mutation: true);
  Future<GoogleContactRecord> _writeFields(
    GoogleContactRecord base,
    Map<String, dynamic> body,
    Set<String> fields,
  ) async {
    for (final field in fields) {
      if ((base.nativeDocument[field] as List? ?? []).any(
        (value) =>
            value is Map &&
            value['metadata'] is Map &&
            (value['metadata'] as Map)['source'] is Map &&
            ((value['metadata'] as Map)['source'] as Map)['type'] != 'CONTACT',
      )) {
        throw const ContactsException(
          ContactsFailure.permission,
          'google-field-not-contact-owned',
        );
      }
    }
    final sources =
        base.person.metadata?.sources
            ?.where((s) => s.type == 'CONTACT' && s.etag?.isNotEmpty == true)
            .toList() ??
        [];
    if (sources.isEmpty)
      throw const ContactsException(
        ContactsFailure.conflict,
        'google-contact-source-etag-required',
      );
    body['metadata'] = {'sources': sources.map((s) => s.toJson()).toList()};
    final confirmed = await _api.people.updateContact(
      _ContactWritePerson(body),
      base.identity.remoteId,
      updatePersonFields: fields.join(','),
      personFields: readMask,
      sources: _sources,
    );
    return _record(confirmed);
  }

  @override
  Future<void> delete(
    ContactSource source,
    ContactRecord base,
    ContactsCancellationToken cancellation,
  ) => _run(cancellation, () async {
    _requireWrite(source);
    _ownedIdentity(base.identity);
    final latest = _record(
      await _api.people.get(
        base.identity.remoteId,
        personFields: readMask,
        sources: _sources,
      ),
    );
    if (latest.revision != base.revision)
      throw const ContactsException(
        ContactsFailure.conflict,
        'google-preflight-change',
      );
    await _api.people.deleteContact(base.identity.remoteId);
  }, mutation: true);
  @override
  Future<Uint8List?> photo(
    ContactSource source,
    ContactRecord record,
    ContactsCancellationToken cancellation,
  ) => _run(cancellation, () async {
    final url = record.projection.photo?.url;
    if (url == null) return null;
    if (url.scheme != 'https' ||
        url.userInfo.isNotEmpty ||
        url.port != 443 ||
        !(url.host == 'googleusercontent.com' ||
            url.host.endsWith('.googleusercontent.com'))) {
      throw const ContactsException(
        ContactsFailure.protocol,
        'untrusted-google-photo',
      );
    }
    return readContactPhoto(_photos, url, cancellation);
  });
  @override
  Future<ContactRecord> setPhoto(
    ContactSource source,
    ContactRecord base,
    Uint8List? bytes,
    String mediaType,
    ContactsCancellationToken cancellation,
  ) => _run(cancellation, () async {
    _requireWrite(source);
    final latest = _record(
      await _api.people.get(
        base.identity.remoteId,
        personFields: readMask,
        sources: _sources,
      ),
    );
    if (latest.revision != base.revision)
      throw const ContactsException(
        ContactsFailure.conflict,
        'google-photo-preflight-change',
      );
    if (bytes != null && bytes.length > 2 * 1024 * 1024)
      throw const ContactsException(ContactsFailure.validation, 'photo-limit');
    if (bytes == null) {
      final result = await _api.people.deleteContactPhoto(
        base.identity.remoteId,
        personFields: readMask,
        sources: _sources,
      );
      return _record(result.person!);
    }
    final result = await _api.people.updateContactPhoto(
      people.UpdateContactPhotoRequest(
        photoBytes: base64Encode(bytes),
        personFields: readMask,
        sources: _sources,
      ),
      base.identity.remoteId,
    );
    return _record(result.person!);
  }, mutation: true);
  Future<List<people.ContactGroup>> groups(
    ContactsCancellationToken cancellation,
  ) => _run(cancellation, () async {
    final groups = <people.ContactGroup>[], seen = <String>{};
    String? page;
    do {
      final result = await _api.contactGroups.list(
        pageSize: 1000,
        pageToken: page,
        groupFields: 'name,groupType,memberCount,metadata,clientData',
      );
      groups.addAll(result.contactGroups ?? []);
      if (groups.length > 20000)
        throw const ContactsException(
          ContactsFailure.protocol,
          'group-count-limit',
        );
      page = result.nextPageToken;
      if (page != null && !seen.add(page))
        throw const ContactsException(
          ContactsFailure.protocol,
          'group-paging-loop',
        );
    } while (page != null);
    return groups;
  });
  @override
  Future<ContactActionResult> action(
    ContactProviderAction action,
    ContactsCancellationToken cancellation,
  ) => _run(cancellation, () async {
    if (!_write)
      throw const ContactsException(
        ContactsFailure.permission,
        'contacts-read-only',
      );
    if (action is GoogleFieldsAction) {
      _ownedIdentity(action.identity);
      final latest = _record(
        await _api.people.get(
          action.identity.remoteId,
          personFields: readMask,
          sources: _sources,
        ),
      );
      if (latest.revision != action.baseRevision)
        throw const ContactsException(
          ContactsFailure.conflict,
          'google-preflight-change',
        );
      final allowed = readMask.split(',').toSet().difference({
        'ageRanges',
        'coverPhotos',
        'metadata',
        'photos',
        'memberships',
      });
      if (action.fields.isEmpty || action.fields.difference(allowed).isNotEmpty)
        throw const ContactsException(
          ContactsFailure.validation,
          'google-update-fields',
        );
      final replacement = action.replacement.toJson();
      for (final singleton in [
        'names',
        'biographies',
        'birthdays',
        'genders',
      ]) {
        if (action.fields.contains(singleton) &&
            (replacement[singleton] as List? ?? []).length > 1) {
          throw const ContactsException(
            ContactsFailure.validation,
            'google-singleton-field',
          );
        }
      }
      return ContactActionResult(
        records: [
          await _writeFields(latest, {
            for (final field in action.fields)
              field: replacement[field] ?? <Object>[],
          }, action.fields),
        ],
      );
    }
    if (action is! GoogleGroupAction)
      throw const ContactsException(
        ContactsFailure.unsupported,
        'wrong-provider-action',
      );
    if (action.operation == GoogleGroupOperation.create) {
      if (action.name?.trim().isNotEmpty != true)
        throw const ContactsException(
          ContactsFailure.validation,
          'group-name-required',
        );
      await _api.contactGroups.create(
        people.CreateContactGroupRequest(
          contactGroup: people.ContactGroup(name: action.name),
        ),
      );
      return const ContactActionResult();
    }
    final group = await _api.contactGroups.get(
      action.resourceName!,
      maxMembers: 0,
    );
    if (action.operation == GoogleGroupOperation.rename ||
        action.operation == GoogleGroupOperation.delete) {
      if (group.groupType != 'USER_CONTACT_GROUP')
        throw const ContactsException(
          ContactsFailure.permission,
          'system-group-protected',
        );
    }
    switch (action.operation) {
      case GoogleGroupOperation.create:
        break;
      case GoogleGroupOperation.rename:
        if (group.etag != action.etag)
          throw const ContactsException(
            ContactsFailure.conflict,
            'group-revision-changed',
          );
        if (action.name?.trim().isNotEmpty != true)
          throw const ContactsException(
            ContactsFailure.validation,
            'group-name-required',
          );
        await _api.contactGroups.update(
          people.UpdateContactGroupRequest(
            contactGroup: people.ContactGroup(
              name: action.name,
              etag: group.etag,
            ),
            updateGroupFields: 'name',
          ),
          action.resourceName!,
        );
      case GoogleGroupOperation.delete:
        await _api.contactGroups.delete(
          action.resourceName!,
          deleteContacts: false,
        );
      case GoogleGroupOperation.membership:
        if (group.groupType == 'SYSTEM_CONTACT_GROUP' &&
            action.add.isNotEmpty &&
            !const {
              'contactGroups/myContacts',
              'contactGroups/starred',
            }.contains(action.resourceName)) {
          throw const ContactsException(
            ContactsFailure.permission,
            'system-group-add-prohibited',
          );
        }
        if (action.add.length + action.remove.length > 1000)
          throw const ContactsException(
            ContactsFailure.validation,
            'group-member-limit',
          );
        final result = await _api.contactGroups.members.modify(
          people.ModifyContactGroupMembersRequest(
            resourceNamesToAdd: action.add,
            resourceNamesToRemove: action.remove,
          ),
          action.resourceName!,
        );
        final records = <ContactRecord>[];
        for (final id in {...action.add, ...action.remove}) {
          if (result.notFoundResourceNames?.contains(id) == true) continue;
          records.add(
            _record(
              await _api.people.get(
                id,
                personFields: readMask,
                sources: _sources,
              ),
            ),
          );
        }
        if (result.notFoundResourceNames?.isNotEmpty == true ||
            result.canNotRemoveLastContactGroupResourceNames?.isNotEmpty ==
                true) {
          // Some remote memberships may have changed; require reconciliation.
          throw const ContactsException(
            ContactsFailure.unknownOutcome,
            'group-membership-partial-result',
          );
        }
        return ContactActionResult(records: records);
    }
    return const ContactActionResult();
  }, mutation: true);
  @override
  ContactProviderAction decodeAction(Map<String, dynamic> json) =>
      json['type'] == 'googleGroup'
      ? GoogleGroupAction(
          GoogleGroupOperation.values.byName(json['operation'] as String),
          resourceName: json['resourceName'] as String?,
          name: json['name'] as String?,
          etag: json['etag'] as String?,
          add: (json['add'] as List? ?? []).cast<String>(),
          remove: (json['remove'] as List? ?? []).cast<String>(),
        )
      : GoogleFieldsAction(
          identity: ContactIdentity.fromJson((json['identity'] as Map).cast()),
          baseRevision: json['revision'] as String,
          replacement: people.Person.fromJson(
            (json['replacement'] as Map).cast(),
          ),
          fields: (json['fields'] as List).cast<String>().toSet(),
        );
  @override
  Future<ContactRecord?> findCreated(
    ContactSource source,
    ContactMutation mutation,
    ContactsCancellationToken cancellation,
  ) => _run(cancellation, () async {
    String? page;
    final matches = <ContactRecord>[];
    final seen = <String>{};
    var count = 0;
    do {
      final result = await _api.people.connections.list(
        'people/me',
        pageSize: 1000,
        pageToken: page,
        personFields: readMask,
        sources: _sources,
      );
      for (final person in result.connections ?? <people.Person>[]) {
        if (++count > 200000)
          throw const ContactsException(
            ContactsFailure.protocol,
            'google-reconciliation-limit',
          );
        if (person.clientData?.any(
              (v) => v.key == _marker && v.value == mutation.id,
            ) ==
            true)
          matches.add(_record(person));
      }
      page = result.nextPageToken;
      if (page != null && !seen.add(page))
        throw const ContactsException(
          ContactsFailure.protocol,
          'google-paging-loop',
        );
    } while (page != null);
    return matches.length == 1 ? matches.single : null;
  });
  ContactIdentity _identity(String name) => ContactIdentity(
    accountId: accountId,
    provider: kind,
    sourceId: 'personal',
    remoteId: name,
  );
  GoogleContactRecord _record(people.Person person) {
    if (person.resourceName == null)
      throw const ContactsException(
        ContactsFailure.protocol,
        'google-resource-name-missing',
      );
    final json = _archive.documents[person.resourceName] ?? person.toJson();
    final identity = _identity(person.resourceName!);
    return GoogleContactRecord(
      identity: identity,
      nativeDocument: json,
      projection: projectGoogleContact(identity, json),
    );
  }

  void _owned(ContactSource source) {
    if (source.accountId != accountId ||
        source.id != 'personal' ||
        source.provider != kind)
      throw const ContactsException(
        ContactsFailure.permission,
        'source-ownership',
      );
  }

  void _ownedIdentity(ContactIdentity id) {
    if (id.accountId != accountId ||
        id.sourceId != 'personal' ||
        !RegExp(r'^people/[^/]+$').hasMatch(id.remoteId)) {
      throw const ContactsException(
        ContactsFailure.permission,
        'contact-ownership',
      );
    }
  }

  void _requireWrite(ContactSource source) {
    _owned(source);
    if (!_write)
      throw const ContactsException(
        ContactsFailure.permission,
        'contacts-read-only',
      );
  }

  void _validate(ContactPatch patch) {
    personalSource.capabilities.validate(patch);
    if (patch.labels.changed)
      throw const ContactsException(
        ContactsFailure.unsupported,
        'google-groups-use-membership-actions',
      );
    if ((patch.dates.value ?? []).where((d) => d.label == 'birthday').length >
        1)
      throw const ContactsException(
        ContactsFailure.validation,
        'google-birthday-singleton',
      );
  }

  Future<T> _run<T>(
    ContactsCancellationToken cancellation,
    Future<T> Function() action, {
    bool mutation = false,
  }) async {
    cancellation.throwIfCancelled();
    _archive.cancellation = cancellation;
    final dispatchedBefore = _archive.dispatchedMutations;
    try {
      return await action();
    } on DetailedApiRequestError catch (error) {
      final status = error.status ?? 0,
          reason = _archive.lastErrorReason ?? error.errors.firstOrNull?.reason;
      throw ContactsException(
        reason == 'EXPIRED_SYNC_TOKEN' || status == 410
            ? ContactsFailure.expiredCursor
            : reason == 'failedPrecondition'
            ? ContactsFailure.conflict
            : switch (status) {
                401 => ContactsFailure.authentication,
                403 => ContactsFailure.permission,
                404 => ContactsFailure.notFound,
                409 || 412 => ContactsFailure.conflict,
                429 => ContactsFailure.throttled,
                >= 500 =>
                  mutation
                      ? ContactsFailure.unknownOutcome
                      : ContactsFailure.server,
                _ => ContactsFailure.validation,
              },
        reason ?? 'google-http-' + status.toString(),
        retryAt: _archive.lastRetryAt,
      );
    } on ContactsException catch (error) {
      if (mutation &&
          _archive.dispatchedMutations > dispatchedBefore &&
          const {
            ContactsFailure.cancelled,
            ContactsFailure.offline,
            ContactsFailure.protocol,
          }.contains(error.kind)) {
        throw const ContactsException(
          ContactsFailure.unknownOutcome,
          'google-reconcile-before-retry',
        );
      }
      rethrow;
    } catch (_) {
      throw ContactsException(
        mutation
            ? ContactsFailure.unknownOutcome
            : cancellation.isCancelled
            ? ContactsFailure.cancelled
            : ContactsFailure.offline,
        mutation ? 'google-reconcile-before-retry' : 'google-request-failed',
      );
    } finally {
      _archive.cancellation = null;
    }
  }

  @override
  void close() {
    _archive.close();
    if (_ownsPhotos) _photos.close();
  }
}

/// The generated client still owns endpoints and request encoding. Retaining
/// the intended field's original subproperties avoids its generated projection
/// dropping a newer source property during a replacement-field update.
final class _ContactWritePerson extends people.Person {
  _ContactWritePerson(this.document);
  final Map<String, dynamic> document;
  @override
  Map<String, dynamic> toJson() => document;
}

final class _PeopleArchiveClient extends http.BaseClient {
  _PeopleArchiveClient(this.client);
  final http.Client client;
  ContactsCancellationToken? cancellation;
  final documents = <String, Map<String, dynamic>>{};
  int dispatchedMutations = 0;
  String? lastErrorReason;
  DateTime? lastRetryAt;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final token = cancellation ?? ContactsCancellationToken();
    token.throwIfCancelled();
    final operation = ContactsCancellationToken();
    final subscription = token.cancellations.listen((_) => operation.cancel());
    try {
      return await _send(request, operation);
    } finally {
      operation.cancel();
      await subscription.cancel();
    }
  }

  Future<http.StreamedResponse> _send(
    http.BaseRequest request,
    ContactsCancellationToken token,
  ) async {
    if (request.url.scheme != 'https' ||
        request.url.host != 'people.googleapis.com' ||
        request.url.port != 443 ||
        request.url.userInfo.isNotEmpty ||
        request.url.hasFragment)
      throw const ContactsException(
        ContactsFailure.protocol,
        'untrusted-people-endpoint',
      );
    token.throwIfCancelled();
    final outbound =
        http.AbortableRequest(
            request.method,
            request.url,
            abortTrigger: token.whenCancelled,
          )
          ..followRedirects = false
          ..headers.addAll(request.headers);
    // Generated requests are JSON-sized and bounded independently of photos.
    outbound.bodyBytes = await _readBounded(
      request.finalize(),
      4 * 1024 * 1024,
      token,
    );
    if (!const {'GET', 'HEAD', 'OPTIONS'}.contains(request.method))
      dispatchedMutations++;
    final response = await Future.any([
      client.send(outbound).timeout(const Duration(seconds: 45)),
      token.whenCancelled.then<http.StreamedResponse>((_) {
        token.throwIfCancelled();
        throw StateError('unreachable');
      }),
    ]);
    final body = await _readBounded(response.stream, 32 * 1024 * 1024, token);
    documents.clear();
    lastErrorReason = null;
    lastRetryAt = null;
    final retrySeconds = int.tryParse(response.headers['retry-after'] ?? '');
    if (retrySeconds != null && retrySeconds >= 0)
      lastRetryAt = DateTime.now().toUtc().add(Duration(seconds: retrySeconds));
    if (response.statusCode >= 400 && body.isNotEmpty) {
      try {
        final error = (jsonDecode(utf8.decode(body)) as Map)['error'];
        if (error is Map) {
          for (final detail in error['details'] as List? ?? []) {
            if (detail is Map &&
                detail['@type'] == 'type.googleapis.com/google.rpc.ErrorInfo') {
              lastErrorReason = detail['reason'] as String?;
            }
          }
        }
      } on FormatException {
        /* The generated client classifies malformed JSON. */
      }
    }
    if (response.statusCode >= 200 &&
        response.statusCode < 300 &&
        body.isNotEmpty) {
      final json = await _decodePeopleJson(body);
      void capture(Object? value) {
        if (value is Map<String, dynamic> &&
            value['resourceName'] is String &&
            (value['resourceName'] as String).startsWith('people/'))
          documents[value['resourceName'] as String] = value;
      }

      capture(json);
      if (json is Map) {
        capture(json['person']);
        for (final person in json['connections'] as List? ?? []) {
          capture(person);
        }
      }
    }
    return http.StreamedResponse(
      Stream.value(body),
      response.statusCode,
      headers: response.headers,
      contentLength: body.length,
      request: request,
    );
  }

  @override
  void close() => client.close();
}

Future<Object?> _decodePeopleJson(Uint8List body) =>
    Isolate.run(() => jsonDecode(utf8.decode(body)));
Future<Uint8List> _readBounded(
  Stream<List<int>> stream,
  int maximum,
  ContactsCancellationToken token,
) async {
  final bytes = BytesBuilder(copy: false);
  final iterator = StreamIterator(stream);
  try {
    while (await Future.any([
      iterator.moveNext().timeout(const Duration(seconds: 60)),
      token.whenCancelled.then<bool>((_) {
        token.throwIfCancelled();
        return false;
      }),
    ])) {
      token.throwIfCancelled();
      final chunk = iterator.current;
      if (bytes.length + chunk.length > maximum)
        throw const ContactsException(
          ContactsFailure.protocol,
          'google-response-limit',
        );
      bytes.add(chunk);
    }
  } finally {
    await iterator.cancel();
  }
  return bytes.takeBytes();
}

ContactProjection projectGoogleContact(
  ContactIdentity identity,
  Map<String, dynamic> json,
) {
  List<Map<String, dynamic>> objects(String field) =>
      (json[field] as List? ?? [])
          .map((v) => (v as Map).cast<String, dynamic>())
          .toList();
  final name = objects('names').firstOrNull ?? {},
      org = objects('organizations').firstOrNull ?? {};
  List<ContactValue> values(String field) => objects(field).indexed
      .map(
        (e) => ContactValue(
          e.$2['value'] as String? ?? '',
          label: e.$2['type'] as String? ?? '',
          types: [if (e.$2['type'] is String) e.$2['type'] as String],
          nativeId: e.$1.toString(),
        ),
      )
      .toList();
  final photo = objects('photos').firstOrNull;
  return ContactProjection(
    identity: identity,
    name: ContactName(
      display: name['displayName'] as String? ?? '',
      given: name['givenName'] as String? ?? '',
      middle: name['middleName'] as String? ?? '',
      family: name['familyName'] as String? ?? '',
      prefix: name['honorificPrefix'] as String? ?? '',
      suffix: name['honorificSuffix'] as String? ?? '',
    ),
    emails: values('emailAddresses'),
    phones: values('phoneNumbers'),
    urls: values('urls'),
    organization: ContactOrganization(
      name: org['name'] as String? ?? '',
      title: org['title'] as String? ?? '',
      department: org['department'] as String? ?? '',
    ),
    addresses: objects('addresses').indexed
        .map(
          (e) => ContactAddress(
            street: e.$2['streetAddress'] as String? ?? '',
            extended: e.$2['extendedAddress'] as String? ?? '',
            poBox: e.$2['poBox'] as String? ?? '',
            city: e.$2['city'] as String? ?? '',
            region: e.$2['region'] as String? ?? '',
            postcode: e.$2['postalCode'] as String? ?? '',
            country: e.$2['country'] as String? ?? '',
            label: e.$2['type'] as String? ?? '',
            nativeId: e.$1.toString(),
          ),
        )
        .toList(),
    dates: [
      for (final pair in [('birthdays', 'birthday'), ('events', 'anniversary')])
        for (final indexed in objects(pair.$1).indexed)
          if (indexed.$2['date'] is Map &&
              (indexed.$2['date'] as Map)['month'] != null &&
              (indexed.$2['date'] as Map)['day'] != null)
            ContactDate(
              month: (indexed.$2['date'] as Map)['month'] as int,
              day: (indexed.$2['date'] as Map)['day'] as int,
              year: (indexed.$2['date'] as Map)['year'] == 0
                  ? null
                  : (indexed.$2['date'] as Map)['year'] as int?,
              nativeId: '${pair.$1}:${indexed.$1}',
              label: pair.$1 == 'birthdays'
                  ? 'birthday'
                  : indexed.$2['type'] as String? ?? pair.$2,
            ),
    ],
    notes: objects('biographies').firstOrNull?['value'] as String? ?? '',
    labels: objects('memberships')
        .map(
          (m) =>
              (m['contactGroupMembership'] as Map?)?['contactGroupResourceName']
                  as String?,
        )
        .whereType<String>()
        .toList(),
    readOnlyFields: {
      if (['birthdays', 'events'].any(
        (field) => objects(field).any(
          (value) =>
              value['date'] is! Map ||
              (value['date'] as Map)['month'] == null ||
              (value['date'] as Map)['day'] == null ||
              value['text'] != null,
        ),
      ))
        ContactField.dates,
      for (final entry in const {
        'names': ContactField.name,
        'emailAddresses': ContactField.emails,
        'phoneNumbers': ContactField.phones,
        'organizations': ContactField.organization,
        'addresses': ContactField.addresses,
        'birthdays': ContactField.dates,
        'events': ContactField.dates,
        'urls': ContactField.urls,
        'biographies': ContactField.notes,
      }.entries)
        if (objects(entry.key).any(
          (value) =>
              (value['metadata'] as Map?)?['source'] is Map &&
              (((value['metadata'] as Map)['source']) as Map)['type'] !=
                  'CONTACT',
        ))
          entry.value,
    },
    photo: photo == null || photo['default'] == true || photo['url'] == null
        ? null
        : ContactPhoto(url: Uri.parse(photo['url'] as String)),
    preservedPropertyNames: json.keys
        .where(
          (key) => !const {
            'resourceName',
            'etag',
            'metadata',
            'names',
            'emailAddresses',
            'phoneNumbers',
            'organizations',
            'addresses',
            'birthdays',
            'events',
            'urls',
            'biographies',
            'memberships',
            'photos',
          }.contains(key),
        )
        .toList(),
  );
}

Map<String, dynamic> googlePatch(
  ContactPatch patch, {
  Map<String, dynamic>? base,
}) {
  final body = <String, dynamic>{};
  List<Map<String, dynamic>> old(String field) => (base?[field] as List? ?? [])
      .map((v) => (v as Map).cast<String, dynamic>())
      .toList();
  Map<String, dynamic> editable(Map<String, dynamic> json) => Map.of(json)
    ..remove('metadata')
    ..remove('formattedType');
  if (patch.name.changed) {
    final name = patch.name.value;
    body['names'] = name == null
        ? <Object>[]
        : [
            {
              ...editable(old('names').firstOrNull ?? {})
                ..remove('displayName')
                ..remove('displayNameLastFirst'),
              'givenName': name.given,
              'middleName': name.middle,
              'familyName': name.family,
              'honorificPrefix': name.prefix,
              'honorificSuffix': name.suffix,
              if (name.given.isEmpty && name.family.isEmpty)
                'unstructuredName': name.display,
            },
          ];
  }
  void repeated(String field, FieldEdit<List<ContactValue>> edit) {
    if (!edit.changed) return;
    final previous = old(field);
    body[field] = (edit.value ?? []).map((v) {
      final index = int.tryParse(v.nativeId ?? '');
      return {
        ...editable(
          index != null && index >= 0 && index < previous.length
              ? previous[index]
              : {},
        ),
        'value': v.value,
        'type': v.label.isNotEmpty ? v.label : v.types.firstOrNull ?? 'other',
      };
    }).toList();
  }

  repeated('emailAddresses', patch.emails);
  repeated('phoneNumbers', patch.phones);
  repeated('urls', patch.urls);
  if (patch.organization.changed) {
    final org = patch.organization.value;
    final previous = old('organizations');
    body['organizations'] = org == null
        ? previous.skip(1).map(editable).toList()
        : [
            {
              ...editable(previous.firstOrNull ?? {}),
              'name': org.name,
              'title': org.title,
              'department': org.department,
            },
            ...previous.skip(1).map(editable),
          ];
  }
  if (patch.addresses.changed) {
    final previous = old('addresses');
    body['addresses'] = (patch.addresses.value ?? []).map((a) {
      final index = int.tryParse(a.nativeId ?? '');
      return {
        ...editable(
          index != null && index >= 0 && index < previous.length
              ? previous[index]
              : {},
        ),
        'streetAddress': a.street,
        'extendedAddress': a.extended,
        'poBox': a.poBox,
        'city': a.city,
        'region': a.region,
        'postalCode': a.postcode,
        'country': a.country,
        'type': a.label,
      };
    }).toList();
  }
  if (patch.dates.changed) {
    Map<String, dynamic> replacement(String field, ContactDate d) {
      final parts = d.nativeId?.split(':');
      final index = parts?.length == 2 && parts!.first == field
          ? int.tryParse(parts.last)
          : null;
      final previous = old(field);
      final original = index != null && index >= 0 && index < previous.length
          ? previous[index]
          : <String, dynamic>{};
      return {
        ...editable(original),
        if (field == 'events') 'type': d.label,
        'date': {
          ...?original['date'] as Map?,
          'year': d.year ?? 0,
          'month': d.month,
          'day': d.day,
        },
      };
    }

    body['birthdays'] = (patch.dates.value ?? [])
        .where((d) => d.label == 'birthday')
        .map((d) => replacement('birthdays', d))
        .toList();
    body['events'] = (patch.dates.value ?? [])
        .where((d) => d.label != 'birthday')
        .map((d) => replacement('events', d))
        .toList();
  }
  if (patch.notes.changed)
    body['biographies'] =
        patch.notes.value == null || patch.notes.value!.isEmpty
        ? []
        : [
            {'value': patch.notes.value, 'contentType': 'TEXT_PLAIN'},
          ];
  return body;
}
