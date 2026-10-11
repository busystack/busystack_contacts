import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import '../domain/records.dart';
import 'vcard.dart';

ContactProjection projectVcard(ContactIdentity identity, VCardDocument card) {
  List<String> structured(String name, int length) {
    final parts = card.values(name).firstOrNull?.structured() ?? <String>[];
    return [...parts, ...List.filled(length, '')].take(length).toList();
  }

  ContactValue value(VCardProperty p, int index) => ContactValue(
    p.text,
    types: p.parameter('TYPE'),
    label:
        p.parameter('LABEL').firstOrNull ??
        (p.group == null
            ? null
            : card.properties
                  .where((x) => x.group == p.group && x.name == 'X-ABLABEL')
                  .firstOrNull
                  ?.text) ??
        p.parameter('TYPE').firstOrNull ??
        '',
    nativeId: p.group ?? '$index',
  );
  final name = structured('N', 5), org = structured('ORG', 2);
  final dates = <ContactDate>[];
  for (final property in card.properties.where(
    (p) => p.name == 'BDAY' || p.name == 'ANNIVERSARY',
  )) {
    final text = property.text.split('T').first;
    final date = RegExp(r'^(\d{4})-?(\d{2})-?(\d{2})$').firstMatch(text);
    final yearless = RegExp(r'^--(\d{2})-?(\d{2})$').firstMatch(text);
    if (date != null)
      dates.add(
        ContactDate(
          year: int.parse(date.group(1)!),
          month: int.parse(date.group(2)!),
          day: int.parse(date.group(3)!),
          label: property.name == 'BDAY' ? 'birthday' : 'anniversary',
        ),
      );
    if (yearless != null)
      dates.add(
        ContactDate(
          month: int.parse(yearless.group(1)!),
          day: int.parse(yearless.group(2)!),
          label: property.name == 'BDAY' ? 'birthday' : 'anniversary',
        ),
      );
  }
  final photoProperty = card.values('PHOTO').firstOrNull;
  final embedded = card.embeddedPhoto();
  final known = {
    'BEGIN',
    'END',
    'VERSION',
    'UID',
    'FN',
    'N',
    'EMAIL',
    'TEL',
    'ORG',
    'TITLE',
    'ADR',
    'BDAY',
    'ANNIVERSARY',
    'URL',
    'NOTE',
    'CATEGORIES',
    'PHOTO',
    'REV',
    'PRODID',
    'X-ABLABEL',
  };
  return ContactProjection(
    identity: identity,
    name: ContactName(
      display: card.text('FN') ?? '',
      family: name[0],
      given: name[1],
      middle: name[2],
      prefix: name[3],
      suffix: name[4],
    ),
    emails: card.values('EMAIL').indexed.map((e) => value(e.$2, e.$1)).toList(),
    phones: card.values('TEL').indexed.map((e) => value(e.$2, e.$1)).toList(),
    urls: card.values('URL').indexed.map((e) => value(e.$2, e.$1)).toList(),
    organization: ContactOrganization(
      name: org[0],
      department: org[1],
      title: card.text('TITLE') ?? '',
    ),
    addresses: card.values('ADR').indexed.map((e) {
      final p = [...e.$2.structured(), ...List.filled(7, '')].take(7).toList();
      return ContactAddress(
        poBox: p[0],
        extended: p[1],
        street: p[2],
        city: p[3],
        region: p[4],
        postcode: p[5],
        country: p[6],
        label: e.$2.parameter('TYPE').firstOrNull ?? '',
        nativeId: e.$2.group ?? e.$1.toString(),
      );
    }).toList(),
    dates: dates,
    readOnlyFields: {
      if (card.properties
                  .where((p) => p.name == 'BDAY' || p.name == 'ANNIVERSARY')
                  .length !=
              dates.length ||
          card.properties.any(
            (p) =>
                (p.name == 'BDAY' || p.name == 'ANNIVERSARY') &&
                (p.rawValue.contains('T') ||
                    p.parameter('VALUE').any((v) => v.toLowerCase() == 'text')),
          ) ||
          dates.where((d) => d.label == 'birthday').length > 1 ||
          dates.where((d) => d.label == 'anniversary').length > 1 ||
          card.version == '3.0' &&
              dates.any((d) => d.year == null || d.label == 'anniversary'))
        ContactField.dates,
    },
    notes: card.text('NOTE') ?? '',
    labels: card
        .values('CATEGORIES')
        .expand((p) => p.structured(separator: ','))
        .toList(),
    photo: photoProperty == null
        ? null
        : ContactPhoto(
            embedded: embedded,
            mediaType: photoProperty.rawValue.startsWith('data:')
                ? photoProperty.rawValue.substring(5).split(';').first
                : photoProperty.parameter('MEDIATYPE').firstOrNull ??
                      switch (photoProperty
                          .parameter('TYPE')
                          .firstOrNull
                          ?.toUpperCase()) {
                        'PNG' => 'image/png',
                        'JPEG' || 'JPG' => 'image/jpeg',
                        _ => null,
                      },
            url:
                embedded == null &&
                    Uri.tryParse(photoProperty.rawValue)?.hasScheme == true
                ? Uri.parse(photoProperty.rawValue)
                : null,
          ),
    preservedPropertyNames: card.properties
        .where((p) => !known.contains(p.name))
        .map((p) => p.name)
        .toSet()
        .toList(),
  );
}

VCardDocument newVcard(
  ContactPatch patch, {
  String version = '4.0',
  String? uid,
}) {
  final empty = VCardDocument(
    version: version,
    complete: true,
    properties: [
      const VCardProperty(name: 'BEGIN', rawValue: 'VCARD'),
      VCardProperty(name: 'VERSION', rawValue: version),
      VCardProperty(name: 'UID', rawValue: uid ?? const Uuid().v7()),
      const VCardProperty(name: 'FN', rawValue: ''),
      const VCardProperty(name: 'N', rawValue: ';;;;'),
      const VCardProperty(name: 'END', rawValue: 'VCARD'),
    ],
  );
  final result = applyVcardPatch(empty, patch);
  if ((result.text('FN') ?? '').isEmpty) {
    final fallback =
        patch.emails.value?.firstOrNull?.value ??
        patch.organization.value?.name ??
        'Unnamed contact';
    return result.replace('FN', [
      VCardProperty(name: 'FN', rawValue: vcardEscape(fallback)),
    ]);
  }
  return result;
}

VCardDocument applyVcardPatch(VCardDocument card, ContactPatch patch) {
  var result = card;
  VCardProperty property(
    String name,
    String raw, {
    List<VCardParameter> parameters = const [],
    String? group,
  }) => VCardProperty(
    name: name,
    rawValue: raw,
    parameters: parameters,
    group: group,
  );
  void scalar<T>(String name, FieldEdit<T> edit, String Function(T) encode) {
    if (!edit.changed) return;
    final values = result.values(name).toList();
    final existing = values.firstOrNull;
    final retained = values.skip(1);
    result = result.replace(
      name,
      edit.kind == FieldEditKind.clear
          ? [
              // The projection edits the first value. Keep its empty position
              // when language variants or additional values must survive.
              if (values.length > 1) existing!.withValue(''),
              ...retained,
            ]
          : [
              existing?.withValue(encode(edit.value as T)) ??
                  property(name, encode(edit.value as T)),
              ...retained,
            ],
    );
  }

  if (patch.name.changed) {
    final name = patch.name.value ?? const ContactName();
    final display = name.display.isEmpty
        ? [
            name.given,
            name.middle,
            name.family,
          ].where((s) => s.isNotEmpty).join(' ')
        : name.display;
    result = result.replace('FN', [
      card.values('FN').firstOrNull?.withValue(vcardEscape(display)) ??
          property('FN', vcardEscape(display)),
      ...card.values('FN').skip(1),
    ]);
    result = result.replace('N', [
      card
              .values('N')
              .firstOrNull
              ?.withValue(
                [
                  name.family,
                  name.given,
                  name.middle,
                  name.prefix,
                  name.suffix,
                ].map(vcardEscape).join(';'),
              ) ??
          property(
            'N',
            [
              name.family,
              name.given,
              name.middle,
              name.prefix,
              name.suffix,
            ].map(vcardEscape).join(';'),
          ),
      ...card.values('N').skip(1),
    ]);
  }
  void repeated(String name, FieldEdit<List<ContactValue>> edit) {
    if (!edit.changed) return;
    final old = result.values(name).toList();
    final replacements = (edit.value ?? []).indexed.map((entry) {
      final value = entry.$2;
      final previous = value.nativeId == null
          ? null
          : old.indexed
                .where((p) => (p.$2.group ?? p.$1.toString()) == value.nativeId)
                .firstOrNull
                ?.$2;
      final extras =
          previous?.parameters
              .where((p) => p.name != 'TYPE' && p.name != 'LABEL')
              .toList() ??
          <VCardParameter>[];
      var group = previous?.group;
      final previousLabel =
          previous?.parameter('LABEL').firstOrNull ??
          (group == null
              ? null
              : card
                    .values('X-ABLABEL')
                    .where((p) => p.group == group)
                    .firstOrNull
                    ?.text) ??
          previous?.parameter('TYPE').firstOrNull ??
          '';
      // A grouped label may belong to several fields. Changing one field gives
      // it its own group instead of relabeling another preserved property.
      if (value.label != previousLabel ||
          previous == null && value.label.isNotEmpty) {
        if (group == null ||
            card.properties
                    .where((p) => p.group == group && p.name != 'X-ABLABEL')
                    .length >
                1) {
          var index = 1;
          while (result.properties.any(
            (p) => p.group == 'busycards' + index.toString(),
          )) {
            index++;
          }
          group = 'busycards' + index.toString();
        }
        final labels = result
            .values('X-ABLABEL')
            .where((p) => p.group != group)
            .toList();
        if (value.label.isNotEmpty)
          labels.add(
            property('X-ABLABEL', vcardEscape(value.label), group: group),
          );
        result = result.replace('X-ABLABEL', labels);
      }
      // Keep an existing LABEL parameter when its value did not change.
      return property(
        name,
        vcardEscape(value.value),
        group: group,
        parameters: [
          ...extras,
          if (value.types.isNotEmpty) VCardParameter('TYPE', value.types),
          if (value.label == previousLabel)
            ...?previous?.parameters.where((p) => p.name == 'LABEL'),
        ],
      );
    }).toList();
    result = result.replace(name, replacements);
  }

  repeated('EMAIL', patch.emails);
  repeated('TEL', patch.phones);
  repeated('URL', patch.urls);
  if (patch.organization.changed) {
    final org = patch.organization.value;
    result = result.replace(
      'ORG',
      org == null
          ? card.values('ORG').skip(1)
          : [
              card
                      .values('ORG')
                      .firstOrNull
                      ?.withValue(
                        [
                          org.name,
                          org.department,
                          ...?card
                              .values('ORG')
                              .firstOrNull
                              ?.structured()
                              .skip(2),
                        ].map(vcardEscape).join(';'),
                      ) ??
                  property(
                    'ORG',
                    [org.name, org.department].map(vcardEscape).join(';'),
                  ),
              ...card.values('ORG').skip(1),
            ],
    );
    result = result.replace(
      'TITLE',
      org == null
          ? card.values('TITLE').skip(1)
          : [
              card
                      .values('TITLE')
                      .firstOrNull
                      ?.withValue(vcardEscape(org.title)) ??
                  property('TITLE', vcardEscape(org.title)),
              ...card.values('TITLE').skip(1),
            ],
    );
  }
  if (patch.addresses.changed) {
    final old = result.values('ADR').toList();
    result = result.replace(
      'ADR',
      (patch.addresses.value ?? []).map((address) {
        final previous = old.indexed
            .where((p) => (p.$2.group ?? p.$1.toString()) == address.nativeId)
            .firstOrNull
            ?.$2;
        return property(
          'ADR',
          [
            address.poBox,
            address.extended,
            address.street,
            address.city,
            address.region,
            address.postcode,
            address.country,
          ].map(vcardEscape).join(';'),
          group: previous?.group,
          parameters: [
            ...?previous?.parameters.where((p) => p.name != 'TYPE'),
            if (address.label.isNotEmpty)
              VCardParameter('TYPE', [address.label]),
          ],
        );
      }),
    );
  }
  if (patch.dates.changed) {
    final dates = patch.dates.value ?? <ContactDate>[];
    if (dates.any(
          (date) => !const {'birthday', 'anniversary'}.contains(date.label),
        ) ||
        dates.where((date) => date.label == 'birthday').length > 1 ||
        dates.where((date) => date.label == 'anniversary').length > 1 ||
        card.version == '3.0' &&
            dates.any(
              (date) => date.year == null || date.label == 'anniversary',
            )) {
      throw const ContactsException(
        ContactsFailure.validation,
        'vcard-date-representation-not-supported',
      );
    }
    for (final kind in ['BDAY', 'ANNIVERSARY']) {
      result = result.replace(
        kind,
        (patch.dates.value ?? [])
            .where(
              (d) => d.label == (kind == 'BDAY' ? 'birthday' : 'anniversary'),
            )
            .map((date) {
              final prefix = date.year == null
                  ? '--'
                  : date.year.toString().padLeft(4, '0') + '-';
              return card
                      .values(kind)
                      .firstOrNull
                      ?.withValue(
                        prefix +
                            date.month.toString().padLeft(2, '0') +
                            '-' +
                            date.day.toString().padLeft(2, '0'),
                      ) ??
                  property(
                    kind,
                    prefix +
                        date.month.toString().padLeft(2, '0') +
                        '-' +
                        date.day.toString().padLeft(2, '0'),
                  );
            }),
      );
    }
  }
  scalar('NOTE', patch.notes, vcardEscape);
  if (patch.labels.changed)
    result = result.replace(
      'CATEGORIES',
      patch.labels.value?.isNotEmpty == true
          ? [
              property(
                'CATEGORIES',
                patch.labels.value!.map(vcardEscape).join(','),
              ),
            ]
          : [],
    );
  return result;
}

ContactPatch patchFromProjection(
  ContactProjection p, {
  bool includeLabels = true,
}) => ContactPatch(
  name: FieldEdit.set(p.name),
  emails: FieldEdit.set(p.emails),
  phones: FieldEdit.set(p.phones),
  organization: FieldEdit.set(p.organization),
  addresses: FieldEdit.set(p.addresses),
  dates: FieldEdit.set(p.dates),
  urls: FieldEdit.set(p.urls),
  notes: FieldEdit.set(p.notes),
  labels: includeLabels ? FieldEdit.set(p.labels) : const FieldEdit.unchanged(),
);

String exportContactVcard(ContactRecord record) =>
    record is CardDavContactRecord
    ? record.vcard.serialize()
    : newVcard(
        patchFromProjection(
          record.projection,
          includeLabels: record is! GoogleContactRecord,
        ),
        uid: record.identity.key,
      ).serialize();

List<String> importConversionWarnings(
  VCardDocument card,
  ContactSource destination,
) {
  if (destination.provider == ContactProviderKind.carddav) {
    return destination.versions.contains(card.version)
        ? []
        : ['Unsupported vCard version ' + card.version];
  }
  final projection = projectVcard(
    ContactIdentity(
      accountId: destination.accountId,
      provider: destination.provider,
      sourceId: destination.id,
      remoteId: 'preview',
    ),
    card,
  );
  final warnings = [
    ...projection.preservedPropertyNames.map(
      (name) => 'Preserved source property requires conversion: $name',
    ),
  ];
  for (final property in card.properties.where(
    (p) => p.parameters.isNotEmpty || p.group != null,
  )) {
    warnings.add(
      'Source parameters/group on ' +
          property.name +
          ' cannot all be represented by this provider',
    );
  }
  if (card.values('ORG').length > 1 ||
      card.values('TITLE').length > 1 ||
      card.values('ORG').any((p) => p.structured().length > 2))
    warnings.add(
      'Additional organizations, titles or organization components require conversion',
    );
  if (card.values('FN').length > 1 || card.values('N').length > 1)
    warnings.add('Additional name variants require conversion');
  if (card.values('NOTE').length > 1)
    warnings.add('Additional notes require conversion');
  if (card.values('BDAY').length + card.values('ANNIVERSARY').length >
      projection.dates.length)
    warnings.add(
      'Some source dates have a representation this editor cannot convert',
    );
  if (projection.dates.where((d) => d.label == 'birthday').length > 1)
    warnings.add('Only one birthday can be represented by this provider');
  if (card.values('PHOTO').isNotEmpty)
    warnings.add('Photo requires a separate supported photo operation');
  if (destination.provider == ContactProviderKind.google &&
      projection.labels.isNotEmpty)
    warnings.add('vCard categories are not Google contact-group memberships');
  if (destination.provider == ContactProviderKind.microsoft) {
    if (projection.emails.length > 3)
      warnings.add('Microsoft supports at most three email addresses');
    if (projection.urls.length > 1)
      warnings.add('Microsoft has one business home-page field');
    if (projection.dates.any((d) => d.year == null || d.label != 'birthday'))
      warnings.add(
        'Microsoft birthday requires a year; other dates are unsupported',
      );
    if (projection.addresses.any(
      (a) => !const {'home', 'work', 'other'}.contains(a.label.toLowerCase()),
    ))
      warnings.add('Microsoft postal addresses use home, work or other types');
    if (projection.addresses.any(
      (a) => a.extended.isNotEmpty || a.poBox.isNotEmpty,
    ))
      warnings.add(
        'Microsoft postal addresses cannot represent separate extended or PO-box fields',
      );
    if (projection.addresses.map((a) => a.label.toLowerCase()).toSet().length !=
        projection.addresses.length)
      warnings.add('Microsoft supports one postal address of each type');
    if (projection.phones.any(
      (p) =>
          !p.types.any(
            (type) => const {
              'home',
              'work',
              'cell',
              'mobile',
            }.contains(type.toLowerCase()),
          ) &&
          !const {'home', 'work', 'mobile'}.contains(p.label.toLowerCase()),
    ))
      warnings.add(
        'Phone labels/types outside Microsoft home, work and mobile require conversion',
      );
    if (projection.phones
            .where(
              (p) =>
                  p.types.any(
                    (t) => const {'cell', 'mobile'}.contains(t.toLowerCase()),
                  ) ||
                  p.label.toLowerCase() == 'mobile',
            )
            .length >
        1)
      warnings.add('Microsoft supports one mobile phone');
  }
  return warnings.toSet().toList();
}
