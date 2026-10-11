import 'dart:convert';

import 'package:busystack_contacts/busystack_contacts.dart';
import 'package:test/test.dart';

const sourceCard =
    'BEGIN:VCARD\r\nVERSION:3.0\r\nUID:opaque-uid\r\nFN;LANGUAGE=fr:Zoë 李\r\n'
    'N;LANGUAGE=fr:李;Zoë;;;\r\nitem1.EMAIL;TYPE=HOME;X-PRIVATE="a,b":one@example.test\r\n'
    'item1.X-ABLABEL:Family\r\nEMAIL;TYPE=WORK:two@example.test\r\n'
    'TEL;TYPE=HOME,VOICE:+1 555 0100\r\nORG:Busy;Research;Division\r\nORG:Other;Team\r\nTITLE:Engineer\r\n'
    'ADR;TYPE=WORK:PO;Suite;Main\\; Lane;Vancouver;BC;V1V;Canada\r\n'
    'NOTE:Line one\\nLine two\\, punctuation\r\nX-FUTURE;X-PARAM=opaque:keep\\;raw\r\nEND:VCARD\r\n';
const identity = ContactIdentity(
  accountId: 'account',
  provider: ContactProviderKind.carddav,
  sourceId: 'book',
  remoteId: 'resource',
);
void main() {
  for (final version in ['3.0', '4.0']) {
    test(
      'v$version decodes parameters using its own grammar and preserves folded source',
      () {
        final encoded = version == '3.0'
            ? 'literal^,^n,^^,^\',^N,^x,Zoë李'
            : 'literal^^,^n,^^,^\',^N,^x,Zoë李';
        final source =
            'BEGIN:VCARD\r\nVERSION:$version\r\nUID:parameters-$version\r\n'
            'FN:Zoë "李", Example\r\nN:李;Zoë;;;\r\n'
            'item1.EMAIL;TYPE=HOME,VOICE;X-CARET="$encoded";'
            'X-DELIMITERS="comma,semi;colon:";X-FOLDED="Zoë\r\n 李,^n":one@exam\r\n ple.test\r\n'
            'item1.X-ABLABEL:Quote "label"; literal ^n\r\n'
            'X-UNKNOWN;X-UNKNOWN-PARAM=literal^n:Keep\\;all\\,Unicode李\r\nEND:VCARD\r\n';
        final card = parseVcard(source);
        final email = card.values('EMAIL').single;
        expect(email.parameter('X-CARET'), [
          version == '3.0'
              ? "literal^,^n,^^,^',^N,^x,Zoë李"
              : 'literal^,\n,^,",^N,^x,Zoë李',
        ]);
        expect(email.parameter('X-DELIMITERS'), ['comma,semi;colon:']);
        expect(email.parameter('X-FOLDED'), [
          version == '3.0' ? 'Zoë李,^n' : 'Zoë李,\n',
        ]);
        expect(email.parameter('TYPE'), ['HOME', 'VOICE']);
        expect(email.text, 'one@example.test');
        expect(card.serialize(), source);
        final edited = applyVcardPatch(
          card,
          const ContactPatch(notes: FieldEdit.set('Edited "note", ^n; 李')),
        );
        expect(edited.version, version);
        expect(edited.values('EMAIL').single.line(), email.line());
        expect(
          edited.values('X-UNKNOWN').single.line(),
          card.values('X-UNKNOWN').single.line(),
        );
        final restored = parseVcard(edited.serialize());
        expect(
          restored.values('EMAIL').single.parameter('X-CARET'),
          email.parameter('X-CARET'),
        );
        expect(restored.text('NOTE'), 'Edited "note", ^n; 李');
        expect(restored.text('UID'), 'parameters-$version');
        expect(restored.values('EMAIL').single.parameter('TYPE'), [
          'HOME',
          'VOICE',
        ]);
      },
    );
    test(
      'v$version generated and edited fields serialize parameters for the actual card version',
      () {
        const value = 'literal^ ^n ^^ ^N ^x, semi; colon: Zoë李';
        final card =
            newVcard(
              const ContactPatch(),
              version: version,
              uid: 'generated',
            ).replace('EMAIL', [
              const VCardProperty(
                name: 'EMAIL',
                rawValue: 'old@example.test',
                parameters: [
                  VCardParameter('TYPE', ['HOME', 'VOICE']),
                  VCardParameter('X-UNKNOWN', [value]),
                ],
              ),
            ]);
        final serialized = card.serialize();
        expect(serialized, contains('VERSION:$version'));
        expect(
          serialized,
          contains(version == '3.0' ? 'literal^ ^n ^^' : 'literal^^ ^^n ^^^^'),
        );
        final parsed = parseVcard(serialized);
        expect(parsed.values('EMAIL').single.parameter('X-UNKNOWN'), [value]);
        final projection = projectVcard(identity, parsed);
        final edited = applyVcardPatch(
          parsed,
          ContactPatch(
            emails: FieldEdit.set([
              ContactValue(
                'new@example.test',
                label: projection.emails.single.label,
                types: projection.emails.single.types,
                nativeId: projection.emails.single.nativeId,
              ),
            ]),
          ),
        );
        final restored = parseVcard(edited.serialize());
        expect(restored.version, version);
        expect(restored.values('EMAIL').single.text, 'new@example.test');
        expect(restored.values('EMAIL').single.parameter('X-UNKNOWN'), [value]);
        expect(restored.values('EMAIL').single.parameter('TYPE'), [
          'HOME',
          'VOICE',
        ]);
      },
    );
    test('v$version treats backslashes as ordinary parameter characters', () {
      final card = parseVcard(
        'BEGIN:VCARD\r\nVERSION:$version\r\nFN:One\r\nN:;One;;;\r\n'
        'EMAIL;X-PARAM="Zoë\\,李;tail\\":one@example.test\r\nEND:VCARD\r\n',
      );
      expect(card.values('EMAIL').single.parameter('X-PARAM'), [
        r'Zoë\,李;tail\',
      ]);
      expect(
        parseVcard(card.serialize(preserveOriginal: false))
            .values('EMAIL')
            .single
            .parameter('X-PARAM'),
        [r'Zoë\,李;tail\'],
      );
    });
  }
  test(
    'v3 determines its version before decoding earlier property parameters',
    () {
      final card = parseVcard(
        'BEGIN:VCARD\r\nEMAIL;X-PARAM=^n:one@example.test\r\n'
        'FN:One\r\nVERSION:3.0\r\nN:;One;;;\r\nEND:VCARD\r\n',
      );
      expect(card.values('EMAIL').single.parameter('X-PARAM'), ['^n']);
    },
  );
  test('v3 rejects unrepresentable parameter quotes and line breaks without upgrading or changing source', () {
    final card = parseVcard(sourceCard);
    for (final value in ['Double "quote"', 'line\nfeed', 'line\rreturn']) {
      final edited = card.replace('X-FUTURE', [
        VCardProperty(
          name: 'X-FUTURE',
          rawValue: 'keep',
          parameters: [
            VCardParameter('X-PARAM', [value]),
          ],
        ),
      ]);
      expect(() => edited.serialize(), throwsFormatException);
      expect(card.serialize(), sourceCard);
      expect(edited.version, '3.0');
    }
    // Contact labels are property text in this app's v3 representation, so
    // quotes and newlines remain representable without an invented param escape.
    final generated = newVcard(
      const ContactPatch(
        emails: FieldEdit.set([
          ContactValue('one@example.test', label: 'A,"B"\n^n; 李'),
        ]),
      ),
      version: '3.0',
    );
    expect(
      projectVcard(
        identity,
        parseVcard(generated.serialize()),
      ).emails.single.label,
      'A,"B"\n^n; 李',
    );
  });
  test(
    'v4 generates RFC6868 quoted parameters and folds them at UTF8 boundaries',
    () {
      final value = 'comma, semi; "quote"\n ^ ^n ^^ ^N 李' * 5;
      final card = newVcard(const ContactPatch()).replace('X-FUTURE', [
        VCardProperty(
          name: 'X-FUTURE',
          rawValue: 'Unknown, "text" ^n',
          parameters: [
            VCardParameter('X-PARAM', [value]),
          ],
        ),
      ]);
      final serialized = card.serialize();
      expect(serialized, contains("^'quote^'"));
      expect(serialized, contains('^n'));
      expect(serialized, contains('\r\n '));
      for (final line in serialized.split('\r\n')) {
        expect(utf8.encode(line).length, lessThanOrEqualTo(75));
      }
      expect(
        parseVcard(serialized).values('X-FUTURE').single.parameter('X-PARAM'),
        [value],
      );
    },
  );
  test('primary edits and clears retain alternate names and notes, and lossy import warns', () {
    final card = parseVcard(
      'BEGIN:VCARD\r\nVERSION:4.0\r\nUID:variants\r\n'
      'FN;LANGUAGE=en:First Original\r\nFN;LANGUAGE=fr:Prénom Original\r\n'
      'N;ALTID=1;LANGUAGE=en:Original;First;;;\r\n'
      'N;ALTID=1;LANGUAGE=fr:Original;Prénom;;;\r\n'
      'NOTE;LANGUAGE=en:First note\r\nNOTE;LANGUAGE=fr;X-FUTURE=keep:Autre note\r\n'
      'END:VCARD\r\n',
    );
    final changed = applyVcardPatch(
      card,
      const ContactPatch(
        name: FieldEdit.set(ContactName(display: 'Edited', given: 'Edited')),
        notes: FieldEdit.set('Edited note'),
      ),
    );
    final restored = parseVcard(changed.serialize());
    expect(restored.values('FN').last.text, 'Prénom Original');
    expect(restored.values('N').last.structured()[1], 'Prénom');
    expect(restored.values('NOTE').last.text, 'Autre note');
    expect(restored.values('NOTE').last.parameter('X-FUTURE'), ['keep']);
    final cleared = applyVcardPatch(
      restored,
      const ContactPatch(notes: FieldEdit.clear()),
    );
    expect(projectVcard(identity, cleared).notes, '');
    expect(cleared.values('NOTE'), hasLength(2));
    expect(cleared.values('NOTE').last.text, 'Autre note');
    expect(cleared.values('NOTE').last.parameter('LANGUAGE'), ['fr']);
    final destination = ContactSource(
      accountId: 'a',
      id: 'personal',
      provider: ContactProviderKind.google,
      kind: ContactSourceKind.googlePersonal,
      name: 'Personal',
      remotePath: 'people/me',
      capabilities: ContactCapabilities(fields: ContactField.values.toSet()),
    );
    final losses = importConversionWarnings(card, destination);
    expect(losses, contains('Additional name variants require conversion'));
    expect(losses, contains('Additional notes require conversion'));
  });
  test('text and timestamp vCard dates remain preserved and do not expose lossy date editors', () {
    const identity = ContactIdentity(
      accountId: 'card',
      provider: ContactProviderKind.carddav,
      sourceId: 'book',
      remoteId: 'one.vcf',
    );
    for (final value in [
      'BDAY;VALUE=text:Springtime',
      'BDAY:19961022T140000Z',
    ]) {
      final card = parseVcard(
        'BEGIN:VCARD\r\nVERSION:4.0\r\nUID:one\r\nFN:One\r\n$value\r\nEND:VCARD\r\n',
      );
      expect(
        projectVcard(identity, card).readOnlyFields,
        contains(ContactField.dates),
      );
      expect(
        applyVcardPatch(
          card,
          const ContactPatch(notes: FieldEdit.set('new')),
        ).serialize(),
        contains(value),
      );
    }
  });
  test('clearing the visible primary organization retains additional source organizations', () {
    final edited = applyVcardPatch(
      parseVcard(sourceCard),
      const ContactPatch(organization: FieldEdit.clear()),
    );
    expect(edited.values('ORG').single.text, 'Other;Team');
  });
  test('vCard 3 dates reject yearless and v4-only representations before a replacement', () {
    expect(
      () => applyVcardPatch(
        parseVcard(sourceCard),
        const ContactPatch(
          dates: FieldEdit.set([ContactDate(month: 2, day: 3)]),
        ),
      ),
      throwsA(
        isA<ContactsException>().having(
          (e) => e.kind,
          'kind',
          ContactsFailure.validation,
        ),
      ),
    );
  });
  test('same-format source export is byte-for-byte and unknown fields remain private source', () {
    final card = parseVcard(sourceCard);
    final record = CardDavContactRecord(
      identity: identity,
      vcard: card,
      revision: '"etag"',
      projection: projectVcard(identity, card),
    );
    expect(exportContactVcard(record), sourceCard);
    expect(
      contactRecordFromJson(record.toJson().cast()).toJson(),
      record.toJson(),
    );
    expect(record.projection.preservedPropertyNames, contains('X-FUTURE'));
    expect(record.projection.addresses.single.street, 'Main; Lane');
    expect(record.projection.notes, 'Line one\nLine two, punctuation');
  });
  test('unchanged is not clear, and clearing notes preserves names, UID and unknown content', () {
    final card = parseVcard(sourceCard);
    expect(
      applyVcardPatch(card, const ContactPatch()).serialize(),
      contains('X-FUTURE;X-PARAM=opaque:keep\\;raw'),
    );
    final cleared = applyVcardPatch(
      card,
      const ContactPatch(notes: FieldEdit.clear()),
    );
    expect(cleared.values('NOTE'), isEmpty);
    expect(cleared.text('UID'), 'opaque-uid');
    expect(cleared.values('FN').single.line(), 'FN;LANGUAGE=fr:Zoë 李');
  });
  test(
    'structured name edits retain name parameters and every unrelated line',
    () {
      final updated = applyVcardPatch(
        parseVcard(sourceCard),
        const ContactPatch(
          name: FieldEdit.set(
            ContactName(display: 'New 李', given: 'New', family: '李'),
          ),
        ),
      );
      expect(updated.values('FN').single.parameter('LANGUAGE'), ['fr']);
      expect(updated.values('N').single.structured(), ['李', 'New', '', '', '']);
      expect(updated.values('EMAIL').first.line(), contains('X-PRIVATE="a,b"'));
    },
  );
  test('repeated email edit retains native parameters and all other repeated values', () {
    final card = parseVcard(sourceCard),
        p = projectVcard(identity, parseVcard(sourceCard));
    final edited = applyVcardPatch(
      card,
      ContactPatch(
        emails: FieldEdit.set([
          ContactValue(
            'changed@example.test',
            label: p.emails.first.label,
            types: p.emails.first.types,
            nativeId: p.emails.first.nativeId,
          ),
          p.emails.last,
        ]),
      ),
    );
    expect(edited.values('EMAIL').first.parameter('X-PRIVATE'), ['a,b']);
    expect(edited.values('EMAIL').last.text, 'two@example.test');
    expect(
      edited.values('X-FUTURE').single.line(),
      card.values('X-FUTURE').single.line(),
    );
  });
  test('organization edit retains additional organizations and structured components', () {
    final edited = applyVcardPatch(
      parseVcard(sourceCard),
      const ContactPatch(
        organization: FieldEdit.set(
          ContactOrganization(name: 'New', department: 'R&D', title: 'Lead'),
        ),
      ),
    );
    expect(edited.values('ORG').first.structured(), ['New', 'R&D', 'Division']);
    expect(edited.values('ORG').last.text, 'Other;Team');
  });
  test('Unicode lines fold at UTF-8 octets and unfold without splitting characters', () {
    final note = List.filled(100, '李🙂é').join();
    final card = newVcard(ContactPatch(notes: FieldEdit.set(note)));
    final serialized = card.serialize();
    for (final line in serialized.split('\r\n')) {
      expect(utf8.encode(line).length, lessThanOrEqualTo(75));
    }
    expect(parseVcard(serialized).text('NOTE'), note);
  });
  test('parameter quotes, newlines and literal caret escape round-trip', () {
    final card = newVcard(
      const ContactPatch(
        emails: FieldEdit.set([
          ContactValue('one@example.test', label: 'A,"B"\n^n'),
        ]),
      ),
    );
    expect(
      projectVcard(identity, parseVcard(card.serialize())).emails.single.label,
      'A,"B"\n^n',
    );
  });
  test(
    'editing a grouped label preserves unknown parameters and unrelated groups',
    () {
      final card = parseVcard(sourceCard), p = projectVcard(identity, card);
      final edited = applyVcardPatch(
        card,
        ContactPatch(
          emails: FieldEdit.set([
            ContactValue(
              p.emails.first.value,
              label: 'Trusted family',
              types: p.emails.first.types,
              nativeId: p.emails.first.nativeId,
            ),
            p.emails.last,
          ]),
        ),
      );
      expect(
        projectVcard(identity, edited).emails.first.label,
        'Trusted family',
      );
      expect(edited.values('EMAIL').first.parameter('X-PRIVATE'), ['a,b']);
      expect(edited.text('X-FUTURE'), card.text('X-FUTURE'));
    },
  );
  test('editing a shared group label never relabels another property', () {
    final card = parseVcard(
      sourceCard.replaceFirst(
        'item1.X-ABLABEL',
        'item1.TEL;TYPE=HOME:555\r\nitem1.X-ABLABEL',
      ),
    );
    final p = projectVcard(identity, card);
    final edited = applyVcardPatch(
      card,
      ContactPatch(
        emails: FieldEdit.set([
          ContactValue(
            p.emails.first.value,
            label: 'Changed',
            types: p.emails.first.types,
            nativeId: p.emails.first.nativeId,
          ),
          p.emails.last,
        ]),
      ),
    );
    expect(projectVcard(identity, edited).emails.first.label, 'Changed');
    expect(projectVcard(identity, edited).phones.first.label, 'Family');
  });
  test('v3 requires structured N while v4 does not; partial cards cannot be replaced', () {
    expect(
      () => parseVcard('BEGIN:VCARD\nVERSION:3.0\nFN:Name\nEND:VCARD\n'),
      throwsFormatException,
    );
    expect(
      parseVcard('BEGIN:VCARD\nVERSION:4.0\nFN:Name\nEND:VCARD\n').version,
      '4.0',
    );
    final partial = parseVcard(
      'BEGIN:VCARD\nVERSION:3.0\nEMAIL:one@example.test\nEND:VCARD\n',
      complete: false,
    );
    expect(
      () => applyVcardPatch(
        partial,
        const ContactPatch(notes: FieldEdit.set('x')),
      ),
      throwsStateError,
    );
  });
  test('resource, properties, photos and import cardinality are independently bounded', () async {
    expect(
      () => parseVcard(
        sourceCard,
        limits: const VCardLimits(maximumResourceBytes: 10),
      ),
      throwsFormatException,
    );
    expect(
      () => parseVcard(
        sourceCard,
        limits: const VCardLimits(maximumProperties: 2),
      ),
      throwsFormatException,
    );
    final photo = newVcard(const ContactPatch()).replace('PHOTO', [
      VCardProperty(
        name: 'PHOTO',
        rawValue: 'data:image/png;base64,' + base64Encode(List.filled(10, 1)),
      ),
    ]);
    expect(
      () => parseVcard(
        photo.serialize(),
        limits: const VCardLimits(maximumPhotoBytes: 4),
      ),
      throwsFormatException,
    );
    await expectLater(
      importVcards(
        Stream.value(utf8.encode(sourceCard + sourceCard)),
        limits: const VCardLimits(maximumCards: 1),
      ),
      throwsFormatException,
    );
  });
  test('import reports malformed items, and partial trailing cards never silently pass', () async {
    final items = await importVcards(
      Stream.value(
        utf8.encode(sourceCard + 'BEGIN:VCARD\nVERSION:4.0\nEND:VCARD\n'),
      ),
    );
    expect(items.length, 2);
    expect(items.first.card, isNotNull);
    expect(items.last.error, isNotNull);
    final interrupted = await importVcards(
      Stream.value(utf8.encode('BEGIN:VCARD\nVERSION:4.0\n')),
    );
    expect(interrupted.single.error, isNotNull);
  });
  test('qualified identity distinguishes accounts and resources with identical emails', () {
    const other = ContactIdentity(
      accountId: 'other',
      provider: ContactProviderKind.carddav,
      sourceId: 'book',
      remoteId: 'resource',
    );
    expect(identity, isNot(other));
    expect(ContactIdentity.fromJson(identity.toJson().cast()), identity);
  });
  test(
    'patch serialization retains unchanged, set-empty and explicit clear',
    () {
      const patch = ContactPatch(
        notes: FieldEdit.clear(),
        emails: FieldEdit.set([]),
      );
      final restored = ContactPatch.fromJson(patch.toJson().cast());
      expect(restored.notes.kind, FieldEditKind.clear);
      expect(restored.emails.kind, FieldEditKind.set);
      expect(restored.phones.kind, FieldEditKind.unchanged);
    },
  );
  test(
    'field limits, unsupported fields and invalid dates fail before a write',
    () {
      const caps = ContactCapabilities(
        fields: {ContactField.dates, ContactField.emails},
        limits: {ContactField.emails: 1},
      );
      for (final patch in [
        const ContactPatch(notes: FieldEdit.clear()),
        const ContactPatch(
          dates: FieldEdit.set([ContactDate(month: 2, day: 30)]),
        ),
        const ContactPatch(
          emails: FieldEdit.set([
            ContactValue('a@example.test'),
            ContactValue('b@example.test'),
          ]),
        ),
      ]) {
        expect(() => caps.validate(patch), throwsA(isA<ContactsException>()));
      }
      caps.validate(
        const ContactPatch(
          dates: FieldEdit.set([ContactDate(year: 2000, month: 2, day: 29)]),
        ),
      );
    },
  );
}
