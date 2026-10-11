import 'dart:convert';
import 'dart:typed_data';

enum ContactProviderKind { google, microsoft, carddav }

enum ContactSourceKind { googlePersonal, microsoftFolder, carddavAddressBook }

enum ContactField {
  name,
  emails,
  phones,
  organization,
  addresses,
  dates,
  urls,
  notes,
  labels,
}

enum FieldEditKind { unchanged, set, clear }

/// An omitted field is never an instruction to clear it.
final class FieldEdit<T> {
  const FieldEdit.unchanged() : kind = FieldEditKind.unchanged, value = null;
  const FieldEdit.set(T this.value) : kind = FieldEditKind.set;
  const FieldEdit.clear() : kind = FieldEditKind.clear, value = null;
  final FieldEditKind kind;
  final T? value;
  bool get changed => kind != FieldEditKind.unchanged;
}

final class ContactIdentity {
  const ContactIdentity({
    required this.accountId,
    required this.provider,
    required this.sourceId,
    required this.remoteId,
  });
  final String accountId, sourceId, remoteId;
  final ContactProviderKind provider;
  String get key => jsonEncode([accountId, provider.name, sourceId, remoteId]);
  Map<String, Object?> toJson() => {
    'account': accountId,
    'provider': provider.name,
    'source': sourceId,
    'remote': remoteId,
  };
  factory ContactIdentity.fromJson(Map<String, dynamic> json) =>
      ContactIdentity(
        accountId: json['account'] as String,
        provider: ContactProviderKind.values.byName(json['provider'] as String),
        sourceId: json['source'] as String,
        remoteId: json['remote'] as String,
      );
  @override
  bool operator ==(Object other) =>
      other is ContactIdentity && key == other.key;
  @override
  int get hashCode => key.hashCode;
}

final class ContactName {
  const ContactName({
    this.display = '',
    this.given = '',
    this.middle = '',
    this.family = '',
    this.prefix = '',
    this.suffix = '',
  });
  final String display, given, middle, family, prefix, suffix;
  Map<String, Object?> toJson() => {
    'display': display,
    'given': given,
    'middle': middle,
    'family': family,
    'prefix': prefix,
    'suffix': suffix,
  };
  factory ContactName.fromJson(Map<String, dynamic> j) => ContactName(
    display: j['display'] as String? ?? '',
    given: j['given'] as String? ?? '',
    middle: j['middle'] as String? ?? '',
    family: j['family'] as String? ?? '',
    prefix: j['prefix'] as String? ?? '',
    suffix: j['suffix'] as String? ?? '',
  );
}

final class ContactValue {
  const ContactValue(
    this.value, {
    this.label = '',
    this.types = const [],
    this.nativeId,
  });
  final String value, label;
  final List<String> types;
  final String? nativeId;
  Map<String, Object?> toJson() => {
    'value': value,
    'label': label,
    'types': types,
    'nativeId': nativeId,
  };
  factory ContactValue.fromJson(Map<String, dynamic> j) => ContactValue(
    j['value'] as String,
    label: j['label'] as String? ?? '',
    types: (j['types'] as List? ?? []).cast<String>(),
    nativeId: j['nativeId'] as String?,
  );
}

final class ContactOrganization {
  const ContactOrganization({
    this.name = '',
    this.title = '',
    this.department = '',
  });
  final String name, title, department;
  Map<String, Object?> toJson() => {
    'name': name,
    'title': title,
    'department': department,
  };
  factory ContactOrganization.fromJson(Map<String, dynamic> j) =>
      ContactOrganization(
        name: j['name'] as String? ?? '',
        title: j['title'] as String? ?? '',
        department: j['department'] as String? ?? '',
      );
}

final class ContactAddress {
  const ContactAddress({
    this.street = '',
    this.extended = '',
    this.poBox = '',
    this.city = '',
    this.region = '',
    this.postcode = '',
    this.country = '',
    this.label = '',
    this.nativeId,
  });
  final String street, extended, poBox, city, region, postcode, country, label;
  final String? nativeId;
  Map<String, Object?> toJson() => {
    'street': street,
    'extended': extended,
    'poBox': poBox,
    'city': city,
    'region': region,
    'postcode': postcode,
    'country': country,
    'label': label,
    'nativeId': nativeId,
  };
  factory ContactAddress.fromJson(Map<String, dynamic> j) => ContactAddress(
    street: j['street'] as String? ?? '',
    extended: j['extended'] as String? ?? '',
    poBox: j['poBox'] as String? ?? '',
    city: j['city'] as String? ?? '',
    region: j['region'] as String? ?? '',
    postcode: j['postcode'] as String? ?? '',
    country: j['country'] as String? ?? '',
    label: j['label'] as String? ?? '',
    nativeId: j['nativeId'] as String?,
  );
}

final class ContactDate {
  const ContactDate({
    required this.month,
    required this.day,
    this.year,
    this.label = 'birthday',
    this.nativeId,
  });
  final int? year;
  final int month, day;
  final String label;
  final String? nativeId;
  Map<String, Object?> toJson() => {
    'year': year,
    'month': month,
    'day': day,
    'label': label,
    'nativeId': nativeId,
  };
  factory ContactDate.fromJson(Map<String, dynamic> j) => ContactDate(
    month: j['month'] as int,
    day: j['day'] as int,
    year: j['year'] as int?,
    label: j['label'] as String? ?? 'birthday',
    nativeId: j['nativeId'] as String?,
  );
}

final class ContactPhoto {
  const ContactPhoto({this.url, this.mediaType, this.embedded});
  final Uri? url;
  final String? mediaType;
  final Uint8List? embedded;
  Map<String, Object?> toJson() => {
    'url': url?.toString(),
    'type': mediaType,
    'embedded': embedded == null ? null : base64Encode(embedded!),
  };
  factory ContactPhoto.fromJson(Map<String, dynamic> j) => ContactPhoto(
    url: j['url'] == null ? null : Uri.parse(j['url'] as String),
    mediaType: j['type'] as String?,
    embedded: j['embedded'] == null
        ? null
        : base64Decode(j['embedded'] as String),
  );
}

/// Read projection, never the full document submitted for saving.
final class ContactProjection {
  const ContactProjection({
    required this.identity,
    this.name = const ContactName(),
    this.emails = const [],
    this.phones = const [],
    this.organization = const ContactOrganization(),
    this.addresses = const [],
    this.dates = const [],
    this.urls = const [],
    this.notes = '',
    this.labels = const [],
    this.photo,
    this.preservedPropertyNames = const [],
    this.readOnlyFields = const {},
  });
  final ContactIdentity identity;
  final ContactName name;
  final List<ContactValue> emails, phones, urls;
  final ContactOrganization organization;
  final List<ContactAddress> addresses;
  final List<ContactDate> dates;
  final String notes;
  final List<String> labels, preservedPropertyNames;
  final ContactPhoto? photo;
  final Set<ContactField> readOnlyFields;
  String get displayName => name.display.isNotEmpty
      ? name.display
      : [
          name.given,
          name.middle,
          name.family,
        ].where((v) => v.isNotEmpty).join(' ').isNotEmpty
      ? [
          name.given,
          name.middle,
          name.family,
        ].where((v) => v.isNotEmpty).join(' ')
      : emails.firstOrNull?.value ?? organization.name;
  String get searchText => [
    displayName,
    name.family,
    name.given,
    organization.name,
    organization.title,
    ...emails.map((v) => v.value),
    ...phones.map((v) => v.value),
    ...labels,
  ].join(' ').toLowerCase();
  Map<String, Object?> toJson() => {
    'identity': identity.toJson(),
    'name': name.toJson(),
    'emails': emails.map((v) => v.toJson()).toList(),
    'phones': phones.map((v) => v.toJson()).toList(),
    'organization': organization.toJson(),
    'addresses': addresses.map((v) => v.toJson()).toList(),
    'dates': dates.map((v) => v.toJson()).toList(),
    'urls': urls.map((v) => v.toJson()).toList(),
    'notes': notes,
    'labels': labels,
    'photo': photo?.toJson(),
    'preserved': preservedPropertyNames,
    'readOnlyFields': readOnlyFields.map((field) => field.name).toList(),
  };
  factory ContactProjection.fromJson(Map<String, dynamic> j) =>
      ContactProjection(
        identity: ContactIdentity.fromJson(
          j['identity'] as Map<String, dynamic>,
        ),
        name: ContactName.fromJson(j['name'] as Map<String, dynamic>),
        emails: _objects(j['emails'], ContactValue.fromJson),
        phones: _objects(j['phones'], ContactValue.fromJson),
        organization: ContactOrganization.fromJson(
          j['organization'] as Map<String, dynamic>,
        ),
        addresses: _objects(j['addresses'], ContactAddress.fromJson),
        dates: _objects(j['dates'], ContactDate.fromJson),
        urls: _objects(j['urls'], ContactValue.fromJson),
        notes: j['notes'] as String? ?? '',
        labels: (j['labels'] as List? ?? []).cast<String>(),
        preservedPropertyNames: (j['preserved'] as List? ?? []).cast<String>(),
        readOnlyFields: (j['readOnlyFields'] as List? ?? [])
            .map((v) => ContactField.values.byName(v as String))
            .toSet(),
        photo: j['photo'] == null
            ? null
            : ContactPhoto.fromJson(j['photo'] as Map<String, dynamic>),
      );
}

List<T> _objects<T>(dynamic value, T Function(Map<String, dynamic>) read) =>
    (value as List? ?? [])
        .map((v) => read((v as Map).cast<String, dynamic>()))
        .toList();

final class ContactPatch {
  const ContactPatch({
    this.name = const FieldEdit.unchanged(),
    this.emails = const FieldEdit.unchanged(),
    this.phones = const FieldEdit.unchanged(),
    this.organization = const FieldEdit.unchanged(),
    this.addresses = const FieldEdit.unchanged(),
    this.dates = const FieldEdit.unchanged(),
    this.urls = const FieldEdit.unchanged(),
    this.notes = const FieldEdit.unchanged(),
    this.labels = const FieldEdit.unchanged(),
  });
  final FieldEdit<ContactName> name;
  final FieldEdit<List<ContactValue>> emails, phones, urls;
  final FieldEdit<ContactOrganization> organization;
  final FieldEdit<List<ContactAddress>> addresses;
  final FieldEdit<List<ContactDate>> dates;
  final FieldEdit<String> notes;
  final FieldEdit<List<String>> labels;
  Set<ContactField> get changedFields => {
    if (name.changed) ContactField.name,
    if (emails.changed) ContactField.emails,
    if (phones.changed) ContactField.phones,
    if (organization.changed) ContactField.organization,
    if (addresses.changed) ContactField.addresses,
    if (dates.changed) ContactField.dates,
    if (urls.changed) ContactField.urls,
    if (notes.changed) ContactField.notes,
    if (labels.changed) ContactField.labels,
  };
  Map<String, Object?> toJson() {
    Map<String, Object?> edit<T>(
      FieldEdit<T> field,
      Object? Function(T) encode,
    ) => {
      'kind': field.kind.name,
      'value': field.value == null ? null : encode(field.value as T),
    };
    return {
      'name': edit(name, (v) => v.toJson()),
      'emails': edit(emails, (v) => v.map((e) => e.toJson()).toList()),
      'phones': edit(phones, (v) => v.map((e) => e.toJson()).toList()),
      'organization': edit(organization, (v) => v.toJson()),
      'addresses': edit(addresses, (v) => v.map((e) => e.toJson()).toList()),
      'dates': edit(dates, (v) => v.map((e) => e.toJson()).toList()),
      'urls': edit(urls, (v) => v.map((e) => e.toJson()).toList()),
      'notes': edit(notes, (v) => v),
      'labels': edit(labels, (v) => v),
    };
  }

  factory ContactPatch.fromJson(Map<String, dynamic> json) {
    FieldEdit<T> edit<T>(String key, T Function(dynamic) decode) {
      final field = json[key] as Map?;
      if (field == null || field['kind'] == 'unchanged')
        return const FieldEdit.unchanged();
      if (field['kind'] == 'clear') return const FieldEdit.clear();
      return FieldEdit.set(decode(field['value']));
    }

    return ContactPatch(
      name: edit('name', (v) => ContactName.fromJson((v as Map).cast())),
      emails: edit('emails', (v) => _objects(v, ContactValue.fromJson)),
      phones: edit('phones', (v) => _objects(v, ContactValue.fromJson)),
      organization: edit(
        'organization',
        (v) => ContactOrganization.fromJson((v as Map).cast()),
      ),
      addresses: edit('addresses', (v) => _objects(v, ContactAddress.fromJson)),
      dates: edit('dates', (v) => _objects(v, ContactDate.fromJson)),
      urls: edit('urls', (v) => _objects(v, ContactValue.fromJson)),
      notes: edit('notes', (v) => v as String),
      labels: edit('labels', (v) => (v as List).cast<String>()),
    );
  }
}

final class ContactCapabilities {
  const ContactCapabilities({
    this.read = true,
    this.create = false,
    this.update = false,
    this.delete = false,
    this.photoRead = false,
    this.photoWrite = false,
    this.fields = const {},
    this.limits = const {},
  });
  final bool read, create, update, delete, photoRead, photoWrite;
  final Set<ContactField> fields;
  final Map<ContactField, int> limits;
  void validate(ContactPatch patch) {
    if (patch.changedFields.difference(fields).isNotEmpty)
      throw const ContactsException(
        ContactsFailure.unsupported,
        'unsupported-field',
      );
    final counts = {
      ContactField.emails: patch.emails.value?.length ?? 0,
      ContactField.phones: patch.phones.value?.length ?? 0,
      ContactField.addresses: patch.addresses.value?.length ?? 0,
      ContactField.dates: patch.dates.value?.length ?? 0,
      ContactField.urls: patch.urls.value?.length ?? 0,
      ContactField.labels: patch.labels.value?.length ?? 0,
    };
    for (final entry in counts.entries) {
      if (limits.containsKey(entry.key) && entry.value > limits[entry.key]!)
        throw ContactsException(
          ContactsFailure.validation,
          'field-cardinality-' + entry.key.name,
        );
    }
    for (final email in patch.emails.value ?? <ContactValue>[]) {
      if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email.value))
        throw const ContactsException(
          ContactsFailure.validation,
          'invalid-email',
        );
    }
    for (final date in patch.dates.value ?? <ContactDate>[]) {
      final normalized = DateTime(date.year ?? 2000, date.month, date.day);
      if (normalized.month != date.month ||
          normalized.day != date.day ||
          date.year != null &&
              (normalized.year != date.year ||
                  date.year! < 1 ||
                  date.year! > 9999))
        throw const ContactsException(
          ContactsFailure.validation,
          'invalid-date',
        );
    }
  }

  Map<String, Object?> toJson() => {
    'read': read,
    'create': create,
    'update': update,
    'delete': delete,
    'photoRead': photoRead,
    'photoWrite': photoWrite,
    'fields': fields.map((v) => v.name).toList(),
    'limits': {for (final e in limits.entries) e.key.name: e.value},
  };
  factory ContactCapabilities.fromJson(Map<String, dynamic> j) =>
      ContactCapabilities(
        read: j['read'] as bool? ?? true,
        create: j['create'] as bool? ?? false,
        update: j['update'] as bool? ?? false,
        delete: j['delete'] as bool? ?? false,
        photoRead: j['photoRead'] as bool? ?? false,
        photoWrite: j['photoWrite'] as bool? ?? false,
        fields: (j['fields'] as List? ?? [])
            .map((v) => ContactField.values.byName(v as String))
            .toSet(),
        limits: {
          for (final e in (j['limits'] as Map? ?? {}).entries)
            ContactField.values.byName(e.key as String): e.value as int,
        },
      );
}

final class ContactSource {
  const ContactSource({
    required this.accountId,
    required this.id,
    required this.provider,
    required this.kind,
    required this.name,
    required this.capabilities,
    required this.remotePath,
    this.parentId,
    this.versions = const [],
    this.supportsSync = false,
    this.maximumResourceBytes,
    this.canRename = false,
    this.canRemove = false,
  });
  final String accountId, id, name, remotePath;
  final String? parentId;
  final ContactProviderKind provider;
  final ContactSourceKind kind;
  final ContactCapabilities capabilities;
  final List<String> versions;
  final bool supportsSync, canRename, canRemove;
  final int? maximumResourceBytes;
  String get key => jsonEncode([accountId, provider.name, id]);
  Map<String, Object?> toJson() => {
    'account': accountId,
    'id': id,
    'provider': provider.name,
    'kind': kind.name,
    'name': name,
    'capabilities': capabilities.toJson(),
    'path': remotePath,
    'parent': parentId,
    'versions': versions,
    'sync': supportsSync,
    'maxBytes': maximumResourceBytes,
    'rename': canRename,
    'remove': canRemove,
  };
  factory ContactSource.fromJson(Map<String, dynamic> j) => ContactSource(
    accountId: j['account'] as String,
    id: j['id'] as String,
    provider: ContactProviderKind.values.byName(j['provider'] as String),
    kind: ContactSourceKind.values.byName(j['kind'] as String),
    name: j['name'] as String,
    capabilities: ContactCapabilities.fromJson(
      (j['capabilities'] as Map).cast(),
    ),
    remotePath: j['path'] as String,
    parentId: j['parent'] as String?,
    versions: (j['versions'] as List? ?? []).cast<String>(),
    supportsSync: j['sync'] as bool? ?? false,
    maximumResourceBytes: j['maxBytes'] as int?,
    canRename: j['rename'] as bool? ?? false,
    canRemove: j['remove'] as bool? ?? false,
  );
}

enum ContactsFailure {
  cancelled,
  offline,
  authentication,
  permission,
  validation,
  unsupported,
  conflict,
  unknownOutcome,
  expiredCursor,
  protocol,
  throttled,
  server,
  notFound,
}

final class ContactsException implements Exception {
  const ContactsException(this.kind, this.code, {this.retryAt, this.claims});
  final ContactsFailure kind;
  final String code;
  final DateTime? retryAt;
  final String? claims;
  @override
  String toString() => 'ContactsException($kind, $code)';
}
