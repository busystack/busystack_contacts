import 'dart:typed_data';

import 'package:busystack_contacts/carddav.dart';
import 'package:busystack_dav/carddav.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support/transaction_store.dart';

final server = Uri.parse('https://cloud.example.test/nextcloud/');
String multistatus(String content) =>
    '<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:carddav">' +
    content +
    '</d:multistatus>';
String response(String href, String props) =>
    '<d:response><d:href>' +
    davText(href) +
    '</d:href><d:propstat><d:prop>' +
    props +
    '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
const rawCard =
    'BEGIN:VCARD\r\nVERSION:3.0\r\nUID:uid-one\r\nFN:Zoë 李\r\nN:李;Zoë;;;\r\n'
    'EMAIL;TYPE=HOME:one@example.test\r\nEMAIL;TYPE=WORK:two@example.test\r\nNOTE:Original\r\nX-FUTURE;X-PARAM=opaque:keep\r\nEND:VCARD\r\n';

final class DavFixture {
  final requests = <http.Request>[];
  String card = rawCard, etag = '"one"';
  bool sync = true,
      rejectSync = false,
      conflict = false,
      failConfirmation = false,
      unknownCreate = false;
  int gets = 0, puts = 0;
  late final http.Client httpClient = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    http.Response xml(String text) => http.Response(
      multistatus(text),
      207,
      headers: {'content-type': 'application/xml; charset=utf-8'},
    );
    if (request.method == 'OPTIONS')
      return http.Response(
        '',
        200,
        headers: {
          'allow': 'GET, PUT, DELETE, REPORT, MKCOL, PROPPATCH',
          'dav': '1, 3, extended-mkcol',
        },
      );
    if (request.method == 'MKCOL') return http.Response('', 201);
    if (request.method == 'PROPPATCH')
      return xml(response(path, '<d:displayname>Renamed</d:displayname>'));
    if (request.method == 'DELETE') return http.Response('', 204);
    if (request.method == 'PUT') {
      puts++;
      if (conflict) return http.Response('', 412);
      card = request.body;
      etag = '"new"';
      if (unknownCreate)
        throw const FormatException('Response interrupted after remote write');
      return http.Response('', 201);
    }
    if (request.method == 'GET') {
      gets++;
      if (failConfirmation) return http.Response('', 503);
      return http.Response(
        card,
        200,
        headers: {'etag': etag, 'content-type': 'text/vcard; charset=utf-8'},
      );
    }
    if (request.method == 'REPORT') {
      if (request.body.contains('sync-collection')) {
        if (rejectSync) return http.Response('', 405);
        return xml(
          response(
                '/nextcloud/books/u/book/one.vcf',
                '<d:getetag>' + davText(etag) + '</d:getetag>',
              ) +
              '<d:sync-token>cursor-one</d:sync-token>',
        );
      }
      return xml(
        response(
          '/nextcloud/books/u/book/one.vcf',
          '<d:getetag>' +
              davText(etag) +
              '</d:getetag><c:address-data>' +
              davText(card) +
              '</c:address-data>',
        ),
      );
    }
    if (path == '/.well-known/carddav')
      return http.Response('', 301, headers: {'location': '/nextcloud/dav/'});
    if (path == '/nextcloud/dav/')
      return xml(
        response(
          path,
          '<d:current-user-principal><d:href>/nextcloud/principals/u/</d:href></d:current-user-principal>',
        ),
      );
    if (path == '/nextcloud/principals/u/')
      return xml(
        response(
          path,
          '<c:addressbook-home-set><d:href>/nextcloud/books/u/</d:href></c:addressbook-home-set>',
        ),
      );
    if (path == '/nextcloud/books/u/')
      return xml(
        response(
              path,
              '<d:current-user-privilege-set><d:privilege><d:bind/></d:privilege><d:privilege><d:unbind/></d:privilege></d:current-user-privilege-set>',
            ) +
            response(
              path + 'book/',
              '<d:displayname>Personal</d:displayname><d:resourcetype><d:collection/><c:addressbook/></d:resourcetype>'
                      '<d:current-user-privilege-set><d:privilege><d:read/></d:privilege><d:privilege><d:write/></d:privilege></d:current-user-privilege-set>' +
                  (sync
                      ? '<d:supported-report-set><d:supported-report><d:report><d:sync-collection/></d:report></d:supported-report></d:supported-report-set>'
                      : '') +
                  '<c:supported-address-data><c:address-data-type content-type="text/vcard" version="3.0"/><c:address-data-type content-type="text/vcard" version="4.0"/></c:supported-address-data>',
            ) +
            response(
              path + 'readonly/',
              '<d:displayname>Read only</d:displayname><d:resourcetype><d:collection/><c:addressbook/></d:resourcetype>'
              '<d:current-user-privilege-set><d:privilege><d:read/></d:privilege></d:current-user-privilege-set>',
            ),
      );
    return xml(
      response(
            path,
            '<d:resourcetype><d:collection/><c:addressbook/></d:resourcetype>',
          ) +
          response(
            path + 'one.vcf',
            '<d:getetag>' + davText(etag) + '</d:getetag>',
          ),
    );
  });
  CardDavContactsProvider provider({
    bool readOnly = false,
    Future<ContactRecord?> Function(ContactIdentity)? cached,
  }) {
    const policy = DavProviderProfile.nextcloud();
    final resources = DavResourceClient(
      streaming: DavTransferClient(
        client: httpClient,
        authority: server,
        profile: policy,
      ),
      transport: DavHttpTransport(
        client: httpClient,
        profile: policy,
        accountAuthority: server,
      ),
      credentialProvider: () async => DavBasicCredential(
        username: 'actual-user',
        password: ' fixture password ',
      ),
      authority: server,
      accountId: 'cloud',
      profile: policy,
    );
    return CardDavContactsProvider(
      accountId: 'cloud',
      client: CardDavClient(resources),
      cachedRecord: cached ?? (_) async => null,
      readOnly: readOnly,
    );
  }
}

void main() {
  late DavFixture fixture;
  late CardDavContactsProvider provider;
  late List<ContactSource> books;
  final token = ContactsCancellationToken();
  setUp(() async {
    fixture = DavFixture();
    provider = fixture.provider();
    books = await provider.discover(token);
  });
  tearDown(() => provider.close());
  test('unrepresentable v3 parameter edits fail validation before PUT and do not become uncertain journal entries', () async {
    final base = (await provider.page(
      books.first,
      cancellation: token,
    )).records.single;
    final patch = ContactPatch(
      addresses: FieldEdit.set([
        const ContactAddress(street: 'Main', label: 'Work "quoted"'),
      ]),
    );
    await expectLater(
      provider.update(books.first, base, patch, token),
      throwsA(
        isA<ContactsException>()
            .having((e) => e.kind, 'kind', ContactsFailure.validation)
            .having((e) => e.code, 'code', 'invalid-vcard'),
      ),
    );
    expect(fixture.puts, 0);
    expect(fixture.card, rawCard);
    final store = TransactionStore();
    final directory = ContactsDirectory(store: store)..bind(provider);
    await store.write((tx) async {
      await tx.putAccount(
        const ContactAccount(
          id: 'cloud',
          provider: ContactProviderKind.carddav,
          displayName: 'Cloud',
          subject: 'cloud',
          grantedScopes: {},
        ),
      );
      await tx.putSource(books.first);
      await tx.putContact(base);
    });
    final failed = await directory.update(base, patch);
    expect(failed.state, ContactMutationState.failed);
    expect(failed.errorCode, 'invalid-vcard');
    expect(fixture.puts, 0);
    expect(
      await store.read(
        (tx) async => (await tx.contact(base.identity))?.toJson(),
      ),
      base.toJson(),
    );
    await directory.close();
    await store.close();
  });
  for (final version in ['3.0', '4.0']) {
    test(
      'v$version full-resource edit preserves version-specific caret parameters through conditional PUT',
      () async {
        final encoded = version == '3.0'
            ? "literal^,^n,^^,^',^N,Zoë李"
            : "literal^^,^n,^^,^',^N,Zoë李";
        fixture.card = rawCard
            .replaceFirst('VERSION:3.0', 'VERSION:$version')
            .replaceFirst(
              'EMAIL;TYPE=HOME:',
              'EMAIL;TYPE=HOME;X-CARET="$encoded":',
            )
            .replaceFirst(
              'X-FUTURE;X-PARAM=opaque:',
              'X-FUTURE;X-PARAM="literal^n,^N,李":',
            );
        final base =
            (await provider.page(
                  books.first,
                  cancellation: token,
                )).records.single
                as CardDavContactRecord;
        final originalParameters = base.vcard
            .values('EMAIL')
            .first
            .parameter('X-CARET');
        final originalUnknown = base.vcard.values('X-FUTURE').single.line();
        final first = base.projection.emails.first;
        final result = await provider.update(
          books.first,
          base,
          ContactPatch(
            emails: FieldEdit.set([
              ContactValue(
                'edited@example.test',
                label: first.label,
                types: first.types,
                nativeId: first.nativeId,
              ),
              base.projection.emails.last,
            ]),
          ),
          token,
        ) as CardDavContactRecord;
        final put = fixture.requests.where((r) => r.method == 'PUT').single;
        expect(put.headers['if-match'], '"one"');
        expect(put.body, contains('VERSION:$version'));
        expect(result.vcard.version, version);
        expect(result.vcard.values('EMAIL').first.text, 'edited@example.test');
        expect(
          result.vcard.values('EMAIL').first.parameter('X-CARET'),
          originalParameters,
        );
        expect(result.vcard.values('X-FUTURE').single.line(), originalUnknown);
        expect(result.vcard.text('UID'), base.vcard.text('UID'));
        expect(result.projection.emails.last.value, 'two@example.test');
        expect(result.vcard.values('EMAIL').first.parameter('TYPE'), ['HOME']);
      },
    );
  }
  test('proper discovery follows principal/home, multiple books and actual permission/version advertisements', () {
    expect(books, hasLength(2));
    expect(books.first.versions, ['3.0', '4.0']);
    expect(books.last.versions, ['3.0']);
    expect(books.first.capabilities.update, isTrue);
    expect(books.last.capabilities.update, isFalse);
    expect(provider.creatableHomes.single.path, '/nextcloud/books/u/');
    expect(books.first.canRemove, isTrue);
    expect(
      fixture.requests.every(
        (r) => r.url.host == 'cloud.example.test' && !r.followRedirects,
      ),
      isTrue,
    );
    expect(
      fixture.requests.any((r) => r.url.path.contains('/files/')),
      isFalse,
    );
  });
  test('negotiated RFC6578 changes obtain complete resources, UID, ETag and unknown source fields', () async {
    final page = await provider.page(books.first, cancellation: token);
    final contact = page.records.single as CardDavContactRecord;
    expect(page.fullEnumeration, isTrue);
    expect(page.cursor, 'cursor-one');
    expect(contact.complete, isTrue);
    expect(contact.revision, '"one"');
    expect(contact.vcard.text('UID'), 'uid-one');
    expect(contact.vcard.values('X-FUTURE').single.parameter('X-PARAM'), [
      'opaque',
    ]);
    expect(fixture.gets, 1);
    expect(
      contactRecordFromJson(contact.toJson().cast()).toJson(),
      contact.toJson(),
    );
  });
  test('optional synchronization rejection switches to standards-based ETag enumeration', () async {
    fixture.rejectSync = true;
    await provider.page(books.first, cancellation: token);
    expect(
      fixture.requests.any(
        (r) =>
            r.method == 'PROPFIND' &&
            r.url.path.endsWith('/book/') &&
            r.headers['depth'] == '1',
      ),
      isTrue,
    );
    final before = fixture.requests.where((r) => r.method == 'REPORT').length;
    await provider.page(books.first, cancellation: token);
    expect(fixture.requests.where((r) => r.method == 'REPORT').length, before);
  });
  test(
    'ETag inventory reuses complete cache without downloading unchanged cards',
    () async {
      final contact = (await provider.page(
        books.first,
        cancellation: token,
      )).records.single;
      final before = fixture.gets;
      final cached = fixture.provider(
        cached: (id) async => id == contact.identity ? contact : null,
      );
      final source = (await cached.discover(token)).first;
      final result = await cached.page(source, cancellation: token);
      expect(result.records.single.revision, contact.revision);
      expect(fixture.gets, before);
      cached.close();
    },
  );
  test('full replacement preserves unknown lines, parameters, repeated fields and UID, using If-Match', () async {
    final base = (await provider.page(
      books.first,
      cancellation: token,
    )).records.single;
    final updated = await provider.update(
      books.first,
      base,
      const ContactPatch(notes: FieldEdit.clear()),
      token,
    ) as CardDavContactRecord;
    final put = fixture.requests.where((r) => r.method == 'PUT').single;
    expect(put.headers['if-match'], '"one"');
    expect(put.body, contains('X-FUTURE;X-PARAM=opaque:keep'));
    expect(updated.vcard.text('UID'), 'uid-one');
    expect(updated.projection.emails, hasLength(2));
    expect(updated.projection.notes, '');
  });
  test(
    'conflict keeps original resource and revision; no silent overwrite',
    () async {
      final base =
          (await provider.page(books.first, cancellation: token)).records.single
              as CardDavContactRecord;
      fixture.conflict = true;
      await expectLater(
        provider.update(
          books.first,
          base,
          const ContactPatch(notes: FieldEdit.set('local')),
          token,
        ),
        throwsA(
          isA<ContactsException>().having(
            (e) => e.kind,
            'kind',
            ContactsFailure.conflict,
          ),
        ),
      );
      expect(base.vcard.serialize(), rawCard);
      expect(base.revision, '"one"');
      expect(fixture.puts, 1);
      expect(fixture.card, rawCard);
    },
  );
  test('create uses conditional absence, deterministic mutation path and UID reconciliation', () async {
    fixture.unknownCreate = true;
    await expectLater(
      provider.create(
        books.first,
        const ContactPatch(
          name: FieldEdit.set(ContactName(display: 'Created')),
        ),
        'mutation-uuid',
        token,
      ),
      throwsA(
        isA<ContactsException>().having(
          (e) => e.kind,
          'kind',
          ContactsFailure.unknownOutcome,
        ),
      ),
    );
    final put = fixture.requests.where((r) => r.method == 'PUT').single;
    expect(put.headers['if-none-match'], '*');
    expect(put.url.path, endsWith('/mutation-uuid.vcf'));
    final result = await provider.findCreated(
      books.first,
      ContactMutation(
        id: 'mutation-uuid',
        accountId: 'cloud',
        sourceKey: books.first.key,
        kind: ContactMutationKind.create,
        state: ContactMutationState.unknown,
        createdAt: DateTime.now(),
        patch: const ContactPatch(),
      ),
      token,
    );
    expect((result as CardDavContactRecord).vcard.text('UID'), 'mutation-uuid');
    expect(fixture.puts, 1);
  });
  test(
    'write succeeded but confirmation is unavailable remains unknown',
    () async {
      final base = (await provider.page(
        books.first,
        cancellation: token,
      )).records.single;
      fixture.failConfirmation = true;
      await expectLater(
        provider.update(
          books.first,
          base,
          const ContactPatch(notes: FieldEdit.clear()),
          token,
        ),
        throwsA(
          isA<ContactsException>().having(
            (e) => e.kind,
            'kind',
            ContactsFailure.unknownOutcome,
          ),
        ),
      );
      expect(fixture.puts, 1);
    },
  );
  test('partial vCard cannot replace a full resource and cross-account IDs never receive credentials', () async {
    final base =
        (await provider.page(books.first, cancellation: token)).records.single
            as CardDavContactRecord;
    final partial = CardDavContactRecord(
      identity: base.identity,
      vcard: parseVcard(base.vcard.serialize(), complete: false),
      revision: base.revision,
      projection: base.projection,
    );
    await expectLater(
      provider.update(
        books.first,
        partial,
        const ContactPatch(notes: FieldEdit.clear()),
        token,
      ),
      throwsA(isA<ContactsException>()),
    );
    final wrong = ContactIdentity(
      accountId: 'other',
      provider: ContactProviderKind.carddav,
      sourceId: books.first.id,
      remoteId: 'https://evil.test/resource.vcf',
    );
    await expectLater(
      provider.get(books.first, wrong, token),
      throwsA(isA<ContactsException>()),
    );
    expect(fixture.puts, 0);
  });
  test(
    'embedded photo writes are bounded and preserve all source properties',
    () async {
      final base = (await provider.page(
        books.first,
        cancellation: token,
      )).records.single;
      final updated = await provider.setPhoto(
        books.first,
        base,
        Uint8List.fromList([1, 2, 3]),
        'image/png',
        token,
      ) as CardDavContactRecord;
      expect(await provider.photo(books.first, updated, token), [1, 2, 3]);
      expect(updated.vcard.text('X-FUTURE'), 'keep');
      await expectLater(
        provider.setPhoto(
          books.first,
          updated,
          Uint8List(2 * 1024 * 1024 + 1),
          'image/png',
          token,
        ),
        throwsA(isA<ContactsException>()),
      );
      final removed = await provider.setPhoto(
        books.first,
        updated,
        null,
        'image/png',
        token,
      ) as CardDavContactRecord;
      expect(removed.vcard.values('PHOTO'), isEmpty);
    },
  );
  test('address-book operations require advertised capability and parent privileges', () async {
    await provider.action(
      CardDavBookAction(
        CardDavBookOperation.create,
        uri: server.resolve('books/u/new/'),
        name: 'New',
      ),
      token,
    );
    expect(fixture.requests.last.method, 'MKCOL');
    expect(fixture.requests.last.body, contains('addressbook'));
    await provider.action(
      CardDavBookAction(
        CardDavBookOperation.rename,
        uri: Uri.parse(books.first.id),
        name: 'Renamed',
      ),
      token,
    );
    expect(fixture.requests.last.method, 'PROPPATCH');
    await provider.action(
      CardDavBookAction(
        CardDavBookOperation.delete,
        uri: Uri.parse(books.first.id),
      ),
      token,
    );
    expect(fixture.requests.last.method, 'DELETE');
    await expectLater(
      provider.action(
        CardDavBookAction(
          CardDavBookOperation.rename,
          uri: Uri.parse(books.last.id),
          name: 'No',
        ),
        token,
      ),
      throwsA(isA<ContactsException>()),
    );
  });
  test(
    'lookup-only connection disables writes despite server write permissions',
    () async {
      final reader = fixture.provider(readOnly: true);
      final sources = await reader.discover(token);
      expect(
        sources.every(
          (s) => !s.capabilities.create && !s.capabilities.photoWrite,
        ),
        isTrue,
      );
      expect(reader.creatableHomes, isEmpty);
      await expectLater(
        reader.create(sources.first, const ContactPatch(), 'id', token),
        throwsA(isA<ContactsException>()),
      );
      reader.close();
    },
  );
  test('import negotiates supported vCard version and full-source export remains exact', () async {
    final created = await provider.create(
      books.first,
      const ContactPatch(),
      'import-id',
      token,
      fullVcard: rawCard,
    );
    expect(exportContactVcard(created), rawCard);
    expect(fixture.requests.where((r) => r.method == 'PUT').last.body, rawCard);
    final noV4 = ContactSource.fromJson({
      ...books.first.toJson(),
      'versions': ['3.0'],
    });
    await expectLater(
      provider.create(
        noV4,
        const ContactPatch(),
        'id',
        token,
        fullVcard: newVcard(const ContactPatch()).serialize(),
      ),
      throwsA(isA<ContactsException>()),
    );
  });
}
