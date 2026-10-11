import 'package:googleapis/people/v1.dart' as people;

import '../vcard/vcard.dart';
import 'models.dart';

sealed class ContactRecord {
  const ContactRecord();
  ContactIdentity get identity;
  String get revision;
  bool get complete;
  ContactProjection get projection;
  Map<String, Object?> toJson();
}

final class GoogleContactRecord extends ContactRecord {
  GoogleContactRecord({
    required this.identity,
    required Map<String, dynamic> nativeDocument,
    required this.projection,
    this.complete = true,
  }) : nativeDocument = Map.unmodifiable(nativeDocument),
       person = people.Person.fromJson(nativeDocument);
  @override
  final ContactIdentity identity;
  final people.Person person;

  /// Original provider document, retained separately from generated known types.
  final Map<String, dynamic> nativeDocument;
  @override
  final ContactProjection projection;
  @override
  final bool complete;
  @override
  String get revision =>
      person.metadata?.sources
          ?.where((s) => s.type == 'CONTACT')
          .firstOrNull
          ?.etag ??
      person.etag ??
      '';
  @override
  Map<String, Object?> toJson() => {
    'type': 'google',
    'identity': identity.toJson(),
    'native': nativeDocument,
    'projection': projection.toJson(),
    'complete': complete,
  };
}

final class MicrosoftContact {
  MicrosoftContact(Map<String, dynamic> document)
    : document = Map.unmodifiable(document);
  final Map<String, dynamic> document;
  String get id => document['id'] as String;
  String? get changeKey => document['changeKey'] as String?;
  String? get assistantName => document['assistantName'] as String?;
  String? get spouseName => document['spouseName'] as String?;
  List<String> get children =>
      (document['children'] as List? ?? []).cast<String>();
  List<String> get imAddresses =>
      (document['imAddresses'] as List? ?? []).cast<String>();
  List<Map<String, dynamic>> get extensions =>
      (document['extensions'] as List? ?? [])
          .map((v) => (v as Map).cast<String, dynamic>())
          .toList();
}

final class MicrosoftContactRecord extends ContactRecord {
  MicrosoftContactRecord({
    required this.identity,
    required Map<String, dynamic> nativeDocument,
    required this.projection,
    this.complete = true,
  }) : contact = MicrosoftContact(nativeDocument);
  @override
  final ContactIdentity identity;
  final MicrosoftContact contact;
  @override
  final ContactProjection projection;
  @override
  final bool complete;
  @override
  String get revision =>
      contact.changeKey ?? contact.document['@odata.etag'] as String? ?? '';
  @override
  Map<String, Object?> toJson() => {
    'type': 'microsoft',
    'identity': identity.toJson(),
    'native': contact.document,
    'projection': projection.toJson(),
    'complete': complete,
  };
}

final class CardDavContactRecord extends ContactRecord {
  const CardDavContactRecord({
    required this.identity,
    required this.vcard,
    required this.revision,
    required this.projection,
  });
  @override
  final ContactIdentity identity;
  final VCardDocument vcard;
  @override
  final String revision;
  @override
  final ContactProjection projection;
  @override
  bool get complete => vcard.complete;
  @override
  Map<String, Object?> toJson() => {
    'type': 'carddav',
    'identity': identity.toJson(),
    'native': vcard.serialize(),
    'revision': revision,
    'projection': projection.toJson(),
    'complete': complete,
  };
}

ContactRecord contactRecordFromJson(Map<String, dynamic> json) {
  final identity = ContactIdentity.fromJson((json['identity'] as Map).cast());
  final projection = ContactProjection.fromJson(
    (json['projection'] as Map).cast(),
  );
  return switch (json['type']) {
    'google' => GoogleContactRecord(
      identity: identity,
      nativeDocument: (json['native'] as Map).cast(),
      projection: projection,
      complete: json['complete'] as bool? ?? true,
    ),
    'microsoft' => MicrosoftContactRecord(
      identity: identity,
      nativeDocument: (json['native'] as Map).cast(),
      projection: projection,
      complete: json['complete'] as bool? ?? true,
    ),
    'carddav' => CardDavContactRecord(
      identity: identity,
      projection: projection,
      revision: json['revision'] as String,
      vcard: parseVcard(
        json['native'] as String,
        complete: json['complete'] as bool? ?? true,
      ),
    ),
    _ => throw const FormatException('Unknown contact record provider'),
  };
}
