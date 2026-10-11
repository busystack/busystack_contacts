import 'dart:async';
import 'dart:typed_data';

import 'package:busystack_graph/busystack_graph.dart';

import '../domain/models.dart';
import '../domain/records.dart';
import '../persistence/contacts_store.dart';
import 'provider.dart';

enum MicrosoftFolderOperation { create, rename, delete }

final class MicrosoftFolderAction implements ContactProviderAction {
  const MicrosoftFolderAction(
    this.operation, {
    this.folderId,
    this.parentId,
    this.name,
  });
  final MicrosoftFolderOperation operation;
  final String? folderId, parentId, name;
  @override
  Map<String, Object?> toJson() => {
    'type': 'microsoftFolder',
    'operation': operation.name,
    'folder': folderId,
    'parent': parentId,
    'name': name,
  };
}

final class MicrosoftFieldsAction implements ContactProviderAction {
  const MicrosoftFieldsAction({
    required this.identity,
    required this.baseRevision,
    this.assistantName = const FieldEdit.unchanged(),
    this.spouseName = const FieldEdit.unchanged(),
    this.children = const FieldEdit.unchanged(),
    this.imAddresses = const FieldEdit.unchanged(),
  });
  final ContactIdentity identity;
  final String baseRevision;
  final FieldEdit<String> assistantName, spouseName;
  final FieldEdit<List<String>> children, imAddresses;
  @override
  Map<String, Object?> toJson() => {
    'type': 'microsoftFields',
    'identity': identity.toJson(),
    'revision': baseRevision,
    'assistant': {
      'kind': assistantName.kind.name,
      'value': assistantName.value,
    },
    'spouse': {'kind': spouseName.kind.name, 'value': spouseName.value},
    'children': {'kind': children.kind.name, 'value': children.value},
    'im': {'kind': imAddresses.kind.name, 'value': imAddresses.value},
  };
}

/// Personal contacts; authorization and the Graph transport are injected.
final class MicrosoftContactsProvider implements ContactsProvider {
  MicrosoftContactsProvider({
    required this.accountId,
    required this.graph,
    required this.grantedScopes,
    required this.personalAccount,
  });
  @override
  final String accountId;
  final GraphClient graph;
  final Set<String> grantedScopes;
  final bool personalAccount;
  @override
  ContactProviderKind get kind => ContactProviderKind.microsoft;
  final _sources = <String, ContactSource>{};
  static const immutableHeaders = {'Prefer': 'IdType="ImmutableId"'};
  bool get _write =>
      grantedScopes.any((s) => s.toLowerCase() == 'contacts.readwrite');
  bool get _read =>
      _write || grantedScopes.any((s) => s.toLowerCase() == 'contacts.read');
  String _segment(String id) => Uri.encodeComponent(id);
  String _folderPath(String id) => 'me/contactFolders/' + _segment(id);

  @override
  Future<List<ContactSource>> discover(
    ContactsCancellationToken cancellation,
  ) => _guard(cancellation, (token) async {
    if (!_read)
      throw const ContactsException(
        ContactsFailure.authentication,
        'contacts-scope-missing',
      );
    final sources = <ContactSource>[
      _source('default', 'Contacts', 'me/contacts', null, false),
    ];
    final visited = <String>{};
    Future<void> folders(String path, String? parent, int depth) async {
      if (depth > 32)
        throw const ContactsException(
          ContactsFailure.protocol,
          'folder-depth-limit',
        );
      String? next = path;
      while (next != null) {
        _validateLink(next, path);
        if (!visited.add(next))
          throw const ContactsException(
            ContactsFailure.protocol,
            'folder-paging-loop',
          );
        final json = await (await graph.get(
          next,
          cancellation: token,
        )).jsonObjectAsync();
        for (final value in json['value'] as List? ?? []) {
          if (sources.length >= 512)
            throw const ContactsException(
              ContactsFailure.protocol,
              'folder-count-limit',
            );
          final folder = (value as Map).cast<String, dynamic>(),
              id = folder['id'] as String;
          final source = _source(
            id,
            folder['displayName'] as String? ?? '',
            _folderPath(id) + '/contacts',
            parent ?? folder['parentFolderId'] as String?,
            true,
          );
          if (sources.any((s) => s.id == id)) continue;
          sources.add(source);
          await folders(_folderPath(id) + '/childFolders', id, depth + 1);
        }
        next = json['@odata.nextLink'] as String?;
      }
    }

    await folders('me/contactFolders', null, 0);
    _sources.clear();
    _sources.addAll({for (final s in sources) s.id: s});
    return sources;
  });
  ContactSource _source(
    String id,
    String name,
    String contactsPath,
    String? parent,
    bool delta,
  ) => ContactSource(
    accountId: accountId,
    id: id,
    provider: kind,
    kind: ContactSourceKind.microsoftFolder,
    name: name,
    capabilities: ContactCapabilities(
      read: _read,
      create: _write,
      update: _write,
      delete: _write,
      photoRead: _read,
      photoWrite: _write && !personalAccount,
      fields: ContactField.values.toSet(),
      limits: const {
        ContactField.emails: 3,
        ContactField.urls: 1,
        ContactField.dates: 1,
      },
    ),
    remotePath: contactsPath,
    parentId: parent,
    supportsSync: delta,
    canRename: _write && id != 'default',
    canRemove: _write && id != 'default',
  );
  @override
  Future<ContactsPage> page(
    ContactSource source, {
    String? cursor,
    String? page,
    required ContactsCancellationToken cancellation,
  }) => _guard(cancellation, (token) async {
    _owned(source);
    final path = source.remotePath + (source.supportsSync ? '/delta' : '');
    final link = page ?? cursor ?? path;
    _validateLink(link, path);
    final response = await graph.get(
      link,
      headers: immutableHeaders,
      cancellation: token,
    );
    final json = await response.jsonObjectAsync(),
        records = <ContactRecord>[],
        deleted = <ContactIdentity>[];
    for (final value in json['value'] as List? ?? []) {
      final native = (value as Map).cast<String, dynamic>();
      final id = ContactIdentity(
        accountId: accountId,
        provider: kind,
        sourceId: source.id,
        remoteId: native['id'] as String,
      );
      if (native.containsKey('@removed')) {
        deleted.add(id);
        continue;
      }
      // Delta may omit unchanged properties. A full GET retains the full source,
      // open extensions and fields outside the editor; never save a delta projection.
      records.add(await _get(source, id, token));
    }
    final next = json['@odata.nextLink'] as String?,
        delta = json['@odata.deltaLink'] as String?;
    if (next != null) _validateLink(next, path);
    if (delta != null) _validateLink(delta, path);
    if (source.supportsSync && next == null && delta == null)
      throw const ContactsException(
        ContactsFailure.protocol,
        'delta-link-missing',
      );
    return ContactsPage(
      records: records,
      deleted: deleted,
      nextPage: next,
      cursor: delta,
      fullEnumeration: cursor == null,
    );
  });
  @override
  Future<ContactRecord> get(
    ContactSource source,
    ContactIdentity id,
    ContactsCancellationToken cancellation,
  ) => _guard(cancellation, (token) => _get(source, id, token));
  Future<MicrosoftContactRecord> _get(
    ContactSource source,
    ContactIdentity id,
    GraphCancellationToken token,
  ) async {
    _owned(source);
    if (id.accountId != accountId || id.sourceId != source.id)
      throw const ContactsException(
        ContactsFailure.permission,
        'contact-ownership',
      );
    final response = await graph.get(
      source.remotePath + '/' + _segment(id.remoteId) + r'?$expand=extensions',
      headers: immutableHeaders,
      cancellation: token,
    );
    return _record(source, (await response.jsonObjectAsync()).cast());
  }

  @override
  Future<ContactRecord> create(
    ContactSource source,
    ContactPatch patch,
    String mutationId,
    ContactsCancellationToken cancellation, {
    String? fullVcard,
  }) => _guard(cancellation, (token) async {
    _requireWrite(source);
    _validate(patch);
    final response = await graph.post(
      source.remotePath,
      json: microsoftPatch(patch),
      headers: immutableHeaders,
      cancellation: token,
    );
    return _writeResult(source, response);
  });
  @override
  Future<ContactRecord> update(
    ContactSource source,
    ContactRecord base,
    ContactPatch patch,
    ContactsCancellationToken cancellation,
  ) => _guard(cancellation, (token) async {
    _requireWrite(source);
    _validate(patch);
    final latest = await _get(source, base.identity, token);
    // changeKey supports comparison, not a documented If-Match contract.
    if (latest.revision != base.revision)
      throw const ContactsException(
        ContactsFailure.conflict,
        'microsoft-preflight-change',
      );
    final body = microsoftPatch(patch, base: latest.contact.document);
    final response = await graph.patch(
      source.remotePath + '/' + _segment(base.identity.remoteId),
      body,
      headers: immutableHeaders,
      cancellation: token,
    );
    final confirmed = await _writeResult(
      source,
      response,
      retained: {...latest.contact.document, ...body},
    );
    // PATCH preserves omitted properties. Merge response into the retained
    // native representation, including extension navigation values.
    return confirmed;
  });
  @override
  Future<void> delete(
    ContactSource source,
    ContactRecord base,
    ContactsCancellationToken cancellation,
  ) => _guard(cancellation, (token) async {
    _requireWrite(source);
    final latest = await _get(source, base.identity, token);
    if (latest.revision != base.revision)
      throw const ContactsException(
        ContactsFailure.conflict,
        'microsoft-preflight-change',
      );
    await graph.delete(
      source.remotePath + '/' + _segment(base.identity.remoteId),
      headers: immutableHeaders,
      cancellation: token,
    );
  });
  @override
  Future<Uint8List?> photo(
    ContactSource source,
    ContactRecord record,
    ContactsCancellationToken cancellation,
  ) => _guard(cancellation, (token) async {
    try {
      return (await graph.get(
        source.remotePath +
            '/' +
            _segment(record.identity.remoteId) +
            r'/photo/$value',
        headers: immutableHeaders,
        cancellation: token,
        maximumBytes: 2 * 1024 * 1024,
      )).bodyBytes;
    } on GraphException catch (error) {
      if (error.kind == GraphFailure.notFound) return null;
      rethrow;
    }
  });
  @override
  Future<ContactRecord> setPhoto(
    ContactSource source,
    ContactRecord base,
    Uint8List? bytes,
    String type,
    ContactsCancellationToken cancellation,
  ) => _guard(cancellation, (token) async {
    _requireWrite(source);
    if (personalAccount || bytes == null || type != 'image/jpeg')
      throw const ContactsException(
        ContactsFailure.unsupported,
        'microsoft-contact-photo-operation-unsupported',
      );
    if (bytes.length > 2 * 1024 * 1024)
      throw const ContactsException(ContactsFailure.validation, 'photo-limit');
    final latest = await _get(source, base.identity, token);
    if (latest.revision != base.revision)
      throw const ContactsException(
        ContactsFailure.conflict,
        'microsoft-photo-preflight-change',
      );
    await graph.request(
      'PUT',
      source.remotePath +
          '/' +
          _segment(base.identity.remoteId) +
          r'/photo/$value',
      bytes: bytes,
      headers: {...immutableHeaders, 'content-type': 'image/jpeg'},
      cancellation: token,
    );
    try {
      return await _get(source, base.identity, token);
    } catch (_) {
      throw const ContactsException(
        ContactsFailure.unknownOutcome,
        'photo-write-confirmation-unavailable',
      );
    }
  });
  @override
  Future<ContactActionResult> action(
    ContactProviderAction action,
    ContactsCancellationToken cancellation,
  ) => _guard(cancellation, (token) async {
    if (!_write)
      throw const ContactsException(
        ContactsFailure.permission,
        'contacts-read-only',
      );
    if (action is MicrosoftFolderAction) {
      if (action.operation != MicrosoftFolderOperation.create &&
          (action.folderId == null || action.folderId == 'default')) {
        throw const ContactsException(
          ContactsFailure.permission,
          'default-folder-protected',
        );
      }
      switch (action.operation) {
        case MicrosoftFolderOperation.create:
          if (action.name?.trim().isNotEmpty != true)
            throw const ContactsException(
              ContactsFailure.validation,
              'folder-name-required',
            );
          await graph.post(
            action.parentId == null
                ? 'me/contactFolders'
                : _folderPath(action.parentId!) + '/childFolders',
            json: {'displayName': action.name},
            cancellation: token,
          );
        case MicrosoftFolderOperation.rename:
          if (action.name?.trim().isNotEmpty != true)
            throw const ContactsException(
              ContactsFailure.validation,
              'folder-name-required',
            );
          await graph.patch(_folderPath(action.folderId!), {
            'displayName': action.name,
          }, cancellation: token);
        case MicrosoftFolderOperation.delete:
          await graph.delete(
            _folderPath(action.folderId!),
            cancellation: token,
          );
      }
      return const ContactActionResult(discoverSources: true);
    }
    if (action is MicrosoftFieldsAction) {
      final source = _sources[action.identity.sourceId];
      if (source == null)
        throw const ContactsException(
          ContactsFailure.notFound,
          'folder-not-found',
        );
      final latest = await _get(source, action.identity, token);
      if (latest.revision != action.baseRevision)
        throw const ContactsException(
          ContactsFailure.conflict,
          'microsoft-preflight-change',
        );
      final body = <String, Object?>{
        'displayName': latest.projection.name.display,
      };
      void put<T>(String name, FieldEdit<T> edit, Object clear) {
        if (edit.changed)
          body[name] = edit.kind == FieldEditKind.clear ? clear : edit.value;
      }

      put('assistantName', action.assistantName, '');
      put('spouseName', action.spouseName, '');
      put('children', action.children, <String>[]);
      put('imAddresses', action.imAddresses, <String>[]);
      final response = await graph.patch(
        source.remotePath + '/' + _segment(action.identity.remoteId),
        body,
        headers: immutableHeaders,
        cancellation: token,
      );
      return ContactActionResult(
        records: [
          await _writeResult(
            source,
            response,
            retained: {...latest.contact.document, ...body},
          ),
        ],
      );
    }
    throw const ContactsException(
      ContactsFailure.unsupported,
      'wrong-provider-action',
    );
  });
  @override
  ContactProviderAction decodeAction(Map<String, dynamic> json) {
    if (json['type'] == 'microsoftFolder')
      return MicrosoftFolderAction(
        MicrosoftFolderOperation.values.byName(json['operation'] as String),
        folderId: json['folder'] as String?,
        parentId: json['parent'] as String?,
        name: json['name'] as String?,
      );
    FieldEdit<T> edit<T>(String key) {
      final value = json[key] as Map;
      return switch (value['kind']) {
        'clear' => const FieldEdit.clear(),
        'unchanged' => const FieldEdit.unchanged(),
        _ => FieldEdit.set(
          (value['value'] is List
                  ? (value['value'] as List).cast<String>()
                  : value['value'])
              as T,
        ),
      };
    }

    return MicrosoftFieldsAction(
      identity: ContactIdentity.fromJson((json['identity'] as Map).cast()),
      baseRevision: json['revision'] as String,
      assistantName: edit('assistant'),
      spouseName: edit('spouse'),
      children: edit('children'),
      imAddresses: edit('im'),
    );
  }

  @override
  Future<ContactRecord?> findCreated(
    ContactSource source,
    ContactMutation mutation,
    ContactsCancellationToken cancellation,
  ) async {
    // Graph contact POST has no documented idempotency/reconciliation key.
    // Cached candidates can be selected explicitly; absence is never success.
    cancellation.throwIfCancelled();
    return null;
  }

  Future<MicrosoftContactRecord> _writeResult(
    ContactSource source,
    GraphResponse response, {
    Map<String, dynamic> retained = const {},
  }) async {
    try {
      return _record(source, {
        ...retained,
        ...(await response.jsonObjectAsync()),
      });
    } catch (_) {
      throw const ContactsException(
        ContactsFailure.unknownOutcome,
        'microsoft-write-confirmation-unavailable',
      );
    }
  }

  void _owned(ContactSource source) {
    if (source.accountId != accountId || source.provider != kind)
      throw const ContactsException(
        ContactsFailure.permission,
        'source-ownership',
      );
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
    ContactCapabilities(
      fields: ContactField.values.toSet(),
      limits: const {
        ContactField.emails: 3,
        ContactField.urls: 1,
        ContactField.dates: 1,
      },
    ).validate(patch);
    if (patch.phones.changed) {
      final phones = patch.phones.value ?? [];
      if (phones
                  .where(
                    (p) =>
                        p.types.contains('mobile') ||
                        p.label.toLowerCase() == 'mobile',
                  )
                  .length >
              1 ||
          phones.any(
            (p) =>
                !const {
                  'home',
                  'work',
                  'mobile',
                  '',
                }.contains(p.label.toLowerCase()) &&
                !p.types.any(
                  (t) => const {
                    'home',
                    'work',
                    'mobile',
                  }.contains(t.toLowerCase()),
                ),
          )) {
        throw const ContactsException(
          ContactsFailure.validation,
          'microsoft-phone-types',
        );
      }
    }
    if (patch.addresses.changed) {
      final labels = (patch.addresses.value ?? [])
          .map((a) => a.label.toLowerCase())
          .toList();
      if (labels.toSet().length != labels.length ||
          labels.any((a) => !const {'home', 'work', 'other'}.contains(a))) {
        throw const ContactsException(
          ContactsFailure.validation,
          'microsoft-address-types',
        );
      }
    }
    if (patch.dates.value?.any(
          (d) => d.year == null || d.label != 'birthday',
        ) ==
        true) {
      throw const ContactsException(
        ContactsFailure.validation,
        'microsoft-birthday-format',
      );
    }
    if (patch.addresses.value?.any(
          (address) => address.poBox.isNotEmpty || address.extended.isNotEmpty,
        ) ==
        true) {
      throw const ContactsException(
        ContactsFailure.validation,
        'microsoft-postal-subfields-unsupported',
      );
    }
  }

  void _validateLink(String value, String path) {
    final resolved = graph.resolve(value), expected = graph.resolve(path);
    if (resolved.path != expected.path) {
      throw const ContactsException(
        ContactsFailure.protocol,
        'paging-source-mismatch',
      );
    }
  }

  MicrosoftContactRecord _record(
    ContactSource source,
    Map<String, dynamic> native,
  ) => MicrosoftContactRecord(
    identity: ContactIdentity(
      accountId: accountId,
      provider: kind,
      sourceId: source.id,
      remoteId: native['id'] as String,
    ),
    nativeDocument: native,
    projection: projectMicrosoftContact(
      ContactIdentity(
        accountId: accountId,
        provider: kind,
        sourceId: source.id,
        remoteId: native['id'] as String,
      ),
      native,
    ),
  );
  Future<T> _guard<T>(
    ContactsCancellationToken token,
    Future<T> Function(GraphCancellationToken) action,
  ) async {
    token.throwIfCancelled();
    final graphToken = GraphCancellationToken();
    final sub = token.cancellations.listen((_) => graphToken.cancel());
    try {
      return await action(graphToken);
    } on GraphException catch (error) {
      throw ContactsException(
        error.statusCode == 410 || error.code == 'syncStateNotFound'
            ? ContactsFailure.expiredCursor
            : switch (error.kind) {
                GraphFailure.authentication => ContactsFailure.authentication,
                GraphFailure.permission => ContactsFailure.permission,
                GraphFailure.conflict => ContactsFailure.conflict,
                GraphFailure.notFound => ContactsFailure.notFound,
                GraphFailure.throttled => ContactsFailure.throttled,
                GraphFailure.unknownOutcome => ContactsFailure.unknownOutcome,
                GraphFailure.cancelled => ContactsFailure.cancelled,
                GraphFailure.protocol => ContactsFailure.protocol,
                GraphFailure.server => ContactsFailure.server,
                GraphFailure.invalidRequest => ContactsFailure.validation,
                _ => ContactsFailure.offline,
              },
        error.statusCode == 410 || error.code == 'syncStateNotFound'
            ? 'expired-cursor'
            : error.code,
        retryAt: error.retryAt,
        claims: error.claims,
      );
    } finally {
      await sub.cancel();
    }
  }

  @override
  void close() => graph.close();
}

ContactProjection projectMicrosoftContact(
  ContactIdentity identity,
  Map<String, dynamic> json,
) {
  String s(String key) => json[key] as String? ?? '';
  final phones = <ContactValue>[
    for (final value in json['homePhones'] as List? ?? [])
      ContactValue(value as String, label: 'home', types: const ['home']),
    for (final value in json['businessPhones'] as List? ?? [])
      ContactValue(value as String, label: 'work', types: const ['work']),
    if (s('mobilePhone').isNotEmpty)
      ContactValue(s('mobilePhone'), label: 'mobile', types: const ['mobile']),
  ];
  final birthday = DateTime.tryParse(s('birthday'));
  return ContactProjection(
    identity: identity,
    name: ContactName(
      display: s('displayName'),
      given: s('givenName'),
      middle: s('middleName'),
      family: s('surname'),
      prefix: s('title'),
      suffix: s('generation'),
    ),
    emails: (json['emailAddresses'] as List? ?? []).map((v) {
      final e = v as Map;
      return ContactValue(
        e['address'] as String? ?? '',
        label: e['name'] as String? ?? '',
      );
    }).toList(),
    phones: phones,
    organization: ContactOrganization(
      name: s('companyName'),
      title: s('jobTitle'),
      department: s('department'),
    ),
    addresses: [
      for (final pair in [
        ('homeAddress', 'home'),
        ('businessAddress', 'work'),
        ('otherAddress', 'other'),
      ])
        if (json[pair.$1] is Map &&
            (json[pair.$1] as Map).values.any(
              (v) => v is String && v.isNotEmpty,
            ))
          ContactAddress.fromJson({
            ...(json[pair.$1] as Map).cast<String, dynamic>(),
            'postcode': (json[pair.$1] as Map)['postalCode'],
            'region': (json[pair.$1] as Map)['state'],
            'country': (json[pair.$1] as Map)['countryOrRegion'],
            'label': pair.$2,
          }),
    ],
    dates: birthday == null
        ? []
        : [
            ContactDate(
              year: birthday.year,
              month: birthday.month,
              day: birthday.day,
            ),
          ],
    urls: s('businessHomePage').isEmpty
        ? []
        : [ContactValue(s('businessHomePage'), label: 'work')],
    notes: s('personalNotes'),
    labels: (json['categories'] as List? ?? []).cast<String>(),
    preservedPropertyNames: json.keys
        .where(
          (key) =>
              const {
                'assistantName',
                'children',
                'spouseName',
                'imAddresses',
                'extensions',
                'singleValueExtendedProperties',
                'multiValueExtendedProperties',
                'profession',
                'manager',
                'yomiGivenName',
                'yomiSurname',
              }.contains(key) &&
              json[key] != null,
        )
        .toList(),
  );
}

Map<String, Object?> microsoftPatch(
  ContactPatch patch, {
  Map<String, dynamic>? base,
}) {
  final body = <String, Object?>{};
  if (base != null) body['displayName'] = base['displayName'] ?? '';
  if (patch.name.changed) {
    final name = patch.name.value ?? const ContactName();
    body.addAll({
      'displayName': name.display,
      'givenName': name.given,
      'middleName': name.middle,
      'surname': name.family,
      'title': name.prefix,
      'generation': name.suffix,
    });
  }
  if (patch.emails.changed)
    body['emailAddresses'] = (patch.emails.value ?? [])
        .map((v) => {'address': v.value, 'name': v.label})
        .toList();
  if (patch.phones.changed) {
    final phones = patch.phones.value ?? <ContactValue>[];
    bool type(ContactValue value, String name) =>
        value.label.toLowerCase() == name ||
        value.types.any((v) => v.toLowerCase() == name);
    body.addAll({
      'homePhones': phones
          .where((v) => type(v, 'home'))
          .map((v) => v.value)
          .toList(),
      'businessPhones': phones
          .where((v) => type(v, 'work') || v.label.isEmpty && v.types.isEmpty)
          .map((v) => v.value)
          .toList(),
      'mobilePhone':
          phones.where((v) => type(v, 'mobile')).firstOrNull?.value ?? '',
    });
  }
  if (patch.organization.changed) {
    final org = patch.organization.value ?? const ContactOrganization();
    body.addAll({
      'companyName': org.name,
      'jobTitle': org.title,
      'department': org.department,
    });
  }
  if (patch.addresses.changed) {
    for (final pair in [
      ('homeAddress', 'home'),
      ('businessAddress', 'work'),
      ('otherAddress', 'other'),
    ]) {
      final address = (patch.addresses.value ?? <ContactAddress>[])
          .where((a) => a.label.toLowerCase() == pair.$2)
          .firstOrNull;
      body[pair.$1] = {
        ...?(base?[pair.$1] as Map?)?.cast<String, Object?>(),
        'street': address?.street ?? '',
        'city': address?.city ?? '',
        'state': address?.region ?? '',
        'postalCode': address?.postcode ?? '',
        'countryOrRegion': address?.country ?? '',
      };
    }
  }
  if (patch.dates.changed) {
    final date = patch.dates.value?.firstOrNull;
    body['birthday'] = date == null
        ? null
        : DateTime.utc(date.year!, date.month, date.day).toIso8601String();
  }
  if (patch.urls.changed)
    body['businessHomePage'] = patch.urls.value?.firstOrNull?.value ?? '';
  if (patch.notes.changed) body['personalNotes'] = patch.notes.value ?? '';
  if (patch.labels.changed)
    body['categories'] = patch.labels.value ?? <String>[];
  return body;
}
