import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:busystack_contacts/google.dart';
import 'package:busystack_contacts/microsoft.dart';
import 'package:busystack_graph/busystack_graph.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:googleapis/people/v1.dart' as people;
import 'package:test/test.dart';

http.Response json(Object value, {int status = 200}) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
Map<String, dynamic> googleDocument() => {
  'resourceName': 'people/g1',
  'etag': 'person-etag',
  'metadata': {
    'sources': [
      {'type': 'CONTACT', 'id': 'g1', 'etag': 'contact-etag'},
    ],
  },
  'names': [
    {
      'displayName': 'Zoë 李',
      'givenName': 'Zoë',
      'familyName': '李',
      'phoneticGivenName': 'Zo',
      'futureNameProperty': 'preserve',
    },
  ],
  'emailAddresses': [
    {
      'value': 'one@example.test',
      'type': 'home',
      'displayName': 'Email name',
      'futureEmailProperty': 'keep',
    },
    {'value': 'two@example.test', 'type': 'work'},
  ],
  'phoneNumbers': [
    {'value': '+1 555', 'type': 'home'},
  ],
  'biographies': [
    {'value': 'base note', 'contentType': 'TEXT_PLAIN'},
  ],
  'organizations': [
    {
      'name': 'Busy',
      'title': 'Engineer',
      'department': 'Research',
      'location': 'Vancouver',
    },
    {'name': 'Second org'},
  ],
  'addresses': [
    {
      'streetAddress': 'Main',
      'poBox': 'PO',
      'extendedAddress': 'Suite',
      'city': 'Vancouver',
      'countryCode': 'CA',
      'type': 'work',
    },
  ],
  'nicknames': [
    {'value': 'preserved nickname'},
  ],
  'futureTopLevel': {'opaque': 'preserve'},
  'photos': [
    {'url': 'https://lh3.googleusercontent.com/photo', 'default': false},
  ],
};

final class GoogleFixture {
  Map<String, dynamic> document = googleDocument();
  final requests = <http.Request>[];
  bool failure = false, partialMembership = false;
  String groupType = 'USER_CONTACT_GROUP';
  late final http.Client client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (failure) throw TimeoutException('fixture timeout');
    if (path.endsWith('/connections')) {
      if (request.url.queryParameters['syncToken'] == 'expired')
        return json({
          'error': {
            'code': 400,
            'message': 'expired',
            'details': [
              {
                '@type': 'type.googleapis.com/google.rpc.ErrorInfo',
                'reason': 'EXPIRED_SYNC_TOKEN',
                'domain': 'people.googleapis.com',
              },
            ],
          },
        }, status: 400);
      final incremental = request.url.queryParameters['syncToken'] != null;
      if (request.url.queryParameters['pageToken'] == null)
        return json({
          'connections': [document],
          'nextPageToken': incremental ? 'incremental-page' : 'opaque-page',
        });
      return json({
        'connections': [
          {
            'resourceName': 'people/deleted',
            'metadata': {'deleted': true},
          },
        ],
        'nextSyncToken': incremental ? 'rotated-sync-token' : 'sync-token',
      });
    }
    if (path.endsWith(':createContact')) {
      final body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
      document = {
        ...body,
        'resourceName': 'people/created',
        'metadata': {
          'sources': [
            {'type': 'CONTACT', 'etag': 'created-etag'},
          ],
        },
      };
      return json(document, status: 200);
    }
    if (path.endsWith(':updateContact')) {
      final body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
      document = {
        ...document,
        ...body,
        'metadata': {
          'sources': [
            {'type': 'CONTACT', 'etag': 'updated-etag'},
          ],
        },
      };
      return json(document);
    }
    if (path.endsWith(':deleteContact')) return json({});
    if (path.endsWith(':updateContactPhoto') ||
        path.endsWith(':deleteContactPhoto'))
      return json({'person': document});
    if (path.endsWith('/members:modify'))
      return json(
        partialMembership
            ? {
                'notFoundResourceNames': ['people/missing'],
              }
            : {},
      );
    if (path == '/v1/contactGroups' && request.method == 'GET')
      return json({
        'contactGroups': [
          {
            'resourceName': 'contactGroups/friends',
            'name': 'Friends',
            'groupType': 'USER_CONTACT_GROUP',
            'etag': 'group-etag',
          },
          {
            'resourceName': 'contactGroups/family',
            'name': 'Family',
            'groupType': 'SYSTEM_CONTACT_GROUP',
          },
        ],
      });
    if (path == '/v1/contactGroups' && request.method == 'POST')
      return json({
        'resourceName': 'contactGroups/new',
        'name': 'New',
        'groupType': 'USER_CONTACT_GROUP',
      });
    if (path.startsWith('/v1/contactGroups/'))
      return request.method == 'DELETE'
          ? json({})
          : json({
              'resourceName': path.substring(4),
              'name': 'Group',
              'groupType': groupType,
              'etag': 'group-etag',
            });
    if (path.startsWith('/v1/people/')) return json(document);
    throw StateError('Unhandled People fixture route ' + path);
  });
}

Map<String, dynamic> microsoftDocument() => {
  'id': 'contact/opaque',
  'changeKey': 'change-one',
  'displayName': 'Zoë 李',
  'givenName': 'Zoë',
  'surname': '李',
  'emailAddresses': [
    {'address': 'one@example.test', 'name': 'Work'},
  ],
  'businessPhones': ['+1 555'],
  'mobilePhone': '+1 777',
  'personalNotes': 'base note',
  'categories': ['Friends'],
  'businessAddress': {
    'street': 'Main',
    'city': 'Vancouver',
    'state': 'BC',
    'postalCode': 'V1V',
    'countryOrRegion': 'Canada',
    'futurePostal': 'keep',
  },
  'assistantName': 'Assistant',
  'children': ['Child'],
  'yomiGivenName': 'Zo',
  'extensions': [
    {'id': 'custom', 'opaque': 'retained'},
  ],
  'futureProperty': {'value': 'preserved'},
};

final class MicrosoftFixture {
  Map<String, dynamic> document = microsoftDocument();
  final requests = <http.Request>[];
  String? maliciousLink;
  bool changed = false;
  late final http.Client client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (path == '/v1.0/me/contactFolders' && request.method == 'GET')
      return json({
        'value': [
          {'id': 'Fa', 'displayName': 'Folder'},
        ],
      });
    if (path.endsWith('/childFolders') && request.method == 'GET')
      return json({'value': []});
    if (path.endsWith('/contacts/delta') || path == '/v1.0/me/contacts') {
      if (request.url.queryParameters.containsKey(r'$skiptoken'))
        return json({
          'value': [
            {
              'id': 'deleted',
              '@removed': {'reason': 'deleted'},
            },
          ],
          '@odata.deltaLink':
              'https://graph.microsoft.com' + path + r'?$deltatoken=A%2fB',
        });
      return json({
        'value': [
          {'id': 'contact/opaque', 'changeKey': 'partial'},
        ],
        if (path.endsWith('/delta'))
          '@odata.nextLink':
              maliciousLink ??
              'https://graph.microsoft.com' + path + r'?$skiptoken=A%2fB',
      });
    }
    if (path.endsWith(r'/photo/$value'))
      return request.method == 'GET'
          ? http.Response('', 404)
          : http.Response('', 200);
    if (path.contains('/contacts/')) {
      if (request.method == 'DELETE') return http.Response('', 204);
      if (request.method == 'PATCH') {
        document = {
          ...document,
          ...(jsonDecode(request.body) as Map).cast<String, dynamic>(),
          'changeKey': 'change-new',
        };
        return json(document);
      }
      return json({...document, if (changed) 'changeKey': 'remote-change'});
    }
    if (request.method == 'POST' && path.endsWith('/contacts')) {
      document = {
        ...document,
        ...(jsonDecode(request.body) as Map).cast<String, dynamic>(),
        'changeKey': 'created',
      };
      return json(document, status: 201);
    }
    if (request.method == 'DELETE') return http.Response('', 204);
    return json({'id': 'new-folder', 'displayName': 'New'});
  });
  GraphClient graph() => GraphClient(
    httpClient: client,
    tokenProvider: ({String? claims}) async =>
        const GraphAuthorization('fixture-access'),
  );
}

void main() {
  test('Google repeated date edits retain native properties when reordered and drafts preserve their identity', () {
    final source = googleDocument()
      ..['events'] = [
        {
          'type': 'anniversary',
          'date': {'year': 2020, 'month': 3, 'day': 4, 'futureDate': 'retain'},
          'futureEvent': 'one',
        },
        {
          'type': 'custom',
          'date': {'year': 2021, 'month': 5, 'day': 6},
          'futureEvent': 'two',
        },
      ];
    const identity = ContactIdentity(
      accountId: 'google',
      provider: ContactProviderKind.google,
      sourceId: 'personal',
      remoteId: 'people/g1',
    );
    final projection = projectGoogleContact(identity, source);
    final second = projection.dates.last;
    final first = projection.dates.first;
    final edit = ContactPatch(
      dates: FieldEdit.set([
        second,
        ContactDate(
          year: first.year,
          month: first.month,
          day: 7,
          label: first.label,
          nativeId: first.nativeId,
        ),
      ]),
    );
    final restored = ContactPatch.fromJson(edit.toJson());
    final body = googlePatch(restored, base: source);
    expect(body['events'][0]['futureEvent'], 'two');
    expect(body['events'][1]['futureEvent'], 'one');
    expect(body['events'][1]['date']['futureDate'], 'retain');
    expect(body['events'][1]['date']['day'], 7);
  });
  test('Google dates outside the common editor representation remain preserved and read only', () {
    final source = googleDocument()
      ..['birthdays'] = [
        {'text': 'Springtime'},
      ];
    const identity = ContactIdentity(
      accountId: 'google',
      provider: ContactProviderKind.google,
      sourceId: 'personal',
      remoteId: 'people/g1',
    );
    expect(
      projectGoogleContact(identity, source).readOnlyFields,
      contains(ContactField.dates),
    );
    expect(
      googlePatch(
        const ContactPatch(notes: FieldEdit.set('new')),
        base: source,
      ).containsKey('birthdays'),
      false,
    );
  });
  test('Google primary organization clear preserves additional source organizations', () {
    final body = googlePatch(
      const ContactPatch(organization: FieldEdit.clear()),
      base: googleDocument(),
    );
    expect(body['organizations'], [
      {'name': 'Second org'},
    ]);
  });
  for (final mutation in [false, true]) {
    test(
      'Google stalled response cancellation retains mutation uncertainty: $mutation',
      () async {
        final client = StalledGoogleClient();
        final provider = GoogleContactsProvider(
          accountId: 'stalled',
          authorizedClient: client,
          grantedScopes: {people.PeopleServiceApi.contactsScope},
        );
        final token = ContactsCancellationToken();
        final future = mutation
            ? provider.create(
                provider.personalSource,
                const ContactPatch(notes: FieldEdit.set('Local')),
                'fixture-marker',
                token,
              )
            : provider.page(provider.personalSource, cancellation: token);
        final outcome = expectLater(
          future,
          throwsA(
            isA<ContactsException>().having(
              (e) => e.kind,
              'kind',
              mutation
                  ? ContactsFailure.unknownOutcome
                  : ContactsFailure.cancelled,
            ),
          ),
        );
        await client.entered.future;
        token.cancel();
        await outcome.timeout(const Duration(seconds: 1));
        provider.close();
        await client.body.close();
      },
    );
  }
  group('Google generated People API', () {
    late GoogleFixture fixture;
    late GoogleContactsProvider provider;
    late ContactSource source;
    final token = ContactsCancellationToken();
    setUp(() async {
      fixture = GoogleFixture();
      provider = GoogleContactsProvider(
        accountId: 'google',
        authorizedClient: fixture.client,
        grantedScopes: {people.PeopleServiceApi.contactsScope},
        publicPhotoClient: MockClient((request) async {
          expect(request.headers.containsKey('authorization'), isFalse);
          return http.Response.bytes([1, 2, 3], 200);
        }),
      );
      source = (await provider.discover(token)).single;
    });
    tearDown(() => provider.close());
    test('full sync requests a token and paginates with identical non-page parameters', () async {
      final first = await provider.page(source, cancellation: token);
      expect(fixture.requests.single.url.queryParameters, {
        'pageSize': '100',
        'personFields': GoogleContactsProvider.readMask,
        'requestSyncToken': 'true',
        'sources': 'READ_SOURCE_TYPE_CONTACT',
        'alt': 'json',
      });
      final second = await provider.page(
        source,
        page: first.nextPage,
        cancellation: token,
      );
      final initial = Map.of(fixture.requests[0].url.queryParameters)
        ..remove('pageToken');
      final paged = Map.of(fixture.requests[1].url.queryParameters)
        ..remove('pageToken');
      expect(paged, initial);
      expect(first.fullEnumeration, isTrue);
      expect(second.fullEnumeration, isTrue);
      expect(first.cursor, isNull);
      expect(second.nextPage, isNull);
      expect(second.deleted.single.remoteId, 'people/deleted');
      expect(second.cursor, 'sync-token');
    });
    test('incremental sync uses the stored token on every page and requests its replacement', () async {
      final first = await provider.page(
        source,
        cursor: 'sync-token',
        cancellation: token,
      );
      expect(fixture.requests.single.url.queryParameters, {
        'pageSize': '100',
        'personFields': GoogleContactsProvider.readMask,
        // Per the REST endpoint contract, requesting a replacement token is
        // independent of supplying the token that selects incremental changes.
        'requestSyncToken': 'true',
        'sources': 'READ_SOURCE_TYPE_CONTACT',
        'syncToken': 'sync-token',
        'alt': 'json',
      });
      expect(first.fullEnumeration, isFalse);
      expect(first.nextPage, 'incremental-page');
      expect(first.cursor, isNull);
      final last = await provider.page(
        source,
        cursor: 'sync-token',
        page: first.nextPage,
        cancellation: token,
      );
      final paged = Map.of(fixture.requests.last.url.queryParameters)
        ..remove('pageToken');
      expect(paged, fixture.requests.first.url.queryParameters);
      expect(last.fullEnumeration, isFalse);
      expect(last.deleted.single.remoteId, 'people/deleted');
      expect(last.nextPage, isNull);
      expect(last.cursor, 'rotated-sync-token');
      await provider.page(source, cursor: last.cursor, cancellation: token);
      expect(
        fixture.requests.last.url.queryParameters['syncToken'],
        'rotated-sync-token',
      );
    });
    test(
      'profile-owned fields remain readable and are rejected before mutation',
      () async {
        fixture.document['emailAddresses'] = [
          {
            'value': 'profile@example.test',
            'metadata': {
              'source': {'type': 'PROFILE'},
            },
          },
        ];
        final base = await provider.get(
          source,
          const ContactIdentity(
            accountId: 'google',
            provider: ContactProviderKind.google,
            sourceId: 'personal',
            remoteId: 'people/g1',
          ),
          token,
        );
        expect(base.projection.readOnlyFields, contains(ContactField.emails));
        await expectLater(
          provider.update(
            source,
            base,
            const ContactPatch(emails: FieldEdit.clear()),
            token,
          ),
          throwsA(
            isA<ContactsException>().having(
              (e) => e.kind,
              'kind',
              ContactsFailure.permission,
            ),
          ),
        );
        expect(
          fixture.requests.where((r) => r.url.path.endsWith(':updateContact')),
          isEmpty,
        );
      },
    );
    test('complete source uses contact-source ETag and preserves unknown/native records', () async {
      final contact =
          (await provider.page(source, cancellation: token)).records.single
              as GoogleContactRecord;
      expect(contact.revision, 'contact-etag');
      expect(contact.nativeDocument['futureTopLevel'], {'opaque': 'preserve'});
      expect(contact.person.nicknames!.single.value, 'preserved nickname');
      expect(
        contactRecordFromJson(contact.toJson().cast()).toJson(),
        contact.toJson(),
      );
    });
    test('update replaces only intended fields and carries CONTACT source revision', () async {
      final contact = (await provider.page(
        source,
        cancellation: token,
      )).records.single;
      final updated = await provider.update(
        source,
        contact,
        const ContactPatch(notes: FieldEdit.clear()),
        token,
      ) as GoogleContactRecord;
      final request = fixture.requests.last;
      final body = jsonDecode(request.body) as Map;
      expect(request.url.queryParameters['updatePersonFields'], 'biographies');
      expect(body.keys.toSet(), {'biographies', 'metadata'});
      expect(body['biographies'], isEmpty);
      expect((body['metadata'] as Map)['sources'], [
        {'type': 'CONTACT', 'id': 'g1', 'etag': 'contact-etag'},
      ]);
      expect(updated.nativeDocument['futureTopLevel'], {'opaque': 'preserve'});
      expect(updated.person.emailAddresses, hasLength(2));
    });
    test('editing known repeated value preserves native subfields the generated projection does not know', () async {
      final base = (await provider.page(
        source,
        cancellation: token,
      )).records.single;
      final first = base.projection.emails.first,
          last = base.projection.emails.last;
      await provider.update(
        source,
        base,
        ContactPatch(
          emails: FieldEdit.set([
            ContactValue(
              'new@example.test',
              label: first.label,
              types: first.types,
              nativeId: first.nativeId,
            ),
            last,
          ]),
        ),
        token,
      );
      final body = jsonDecode(fixture.requests.last.body) as Map;
      expect(
        (body['emailAddresses'] as List).first['futureEmailProperty'],
        'keep',
      );
      expect(
        (body['emailAddresses'] as List).first['displayName'],
        'Email name',
      );
      expect(
        (body['emailAddresses'] as List).last['value'],
        'two@example.test',
      );
    });
    test('structured names preserve phonetics, organizations preserve additional entries', () async {
      final base = (await provider.page(
        source,
        cancellation: token,
      )).records.single;
      await provider.update(
        source,
        base,
        const ContactPatch(
          name: FieldEdit.set(ContactName(given: 'New', family: '李')),
          organization: FieldEdit.set(
            ContactOrganization(
              name: 'New org',
              title: 'Lead',
              department: 'Team',
            ),
          ),
        ),
        token,
      );
      final body = jsonDecode(fixture.requests.last.body) as Map;
      expect(body['names'][0]['phoneticGivenName'], 'Zo');
      expect(body['names'][0]['futureNameProperty'], 'preserve');
      expect(body['organizations'][0]['location'], 'Vancouver');
      expect(body['organizations'][1]['name'], 'Second org');
    });
    test('create/delete and photos go through generated methods; photo download sends no bearer', () async {
      final initial = (await provider.page(
        source,
        cancellation: token,
      )).records.single;
      final created = await provider.create(
        source,
        const ContactPatch(name: FieldEdit.set(ContactName(display: 'Create'))),
        'mutation-id',
        token,
      );
      expect(fixture.requests.last.url.path, endsWith(':createContact'));
      expect(
        (jsonDecode(fixture.requests.last.body)
            as Map)['clientData'][0]['value'],
        'mutation-id',
      );
      expect(await provider.photo(source, initial, token), [1, 2, 3]);
      await provider.setPhoto(
        source,
        created,
        Uint8List.fromList([1, 2, 3]),
        'image/jpeg',
        token,
      );
      expect(fixture.requests.last.url.path, endsWith(':updateContactPhoto'));
      await provider.setPhoto(source, created, null, 'image/jpeg', token);
      expect(fixture.requests.last.url.path, endsWith(':deleteContactPhoto'));
      await provider.delete(source, created, token);
      expect(fixture.requests.last.url.path, endsWith(':deleteContact'));
    });
    test(
      'expired ErrorInfo token reason is recognized without erasing data',
      () async {
        await expectLater(
          provider.page(source, cursor: 'expired', cancellation: token),
          throwsA(
            isA<ContactsException>().having(
              (e) => e.kind,
              'kind',
              ContactsFailure.expiredCursor,
            ),
          ),
        );
      },
    );
    test(
      'user groups and system restrictions remain their own concepts',
      () async {
        expect(await provider.groups(token), hasLength(2));
        await provider.action(
          const GoogleGroupAction(GoogleGroupOperation.create, name: 'New'),
          token,
        );
        expect(fixture.requests.last.method, 'POST');
        await provider.action(
          const GoogleGroupAction(
            GoogleGroupOperation.rename,
            resourceName: 'contactGroups/friends',
            name: 'Rename',
            etag: 'group-etag',
          ),
          token,
        );
        expect(
          (jsonDecode(fixture.requests.last.body)
              as Map)['contactGroup']['name'],
          'Rename',
        );
        await provider.action(
          const GoogleGroupAction(
            GoogleGroupOperation.delete,
            resourceName: 'contactGroups/friends',
          ),
          token,
        );
        expect(
          fixture.requests.last.url.queryParameters['deleteContacts'],
          'false',
        );
        fixture.groupType = 'SYSTEM_CONTACT_GROUP';
        await expectLater(
          provider.action(
            const GoogleGroupAction(
              GoogleGroupOperation.rename,
              resourceName: 'contactGroups/family',
              name: 'No',
              etag: 'group-etag',
            ),
            token,
          ),
          throwsA(isA<ContactsException>()),
        );
        await expectLater(
          provider.action(
            const GoogleGroupAction(
              GoogleGroupOperation.membership,
              resourceName: 'contactGroups/family',
              add: ['people/g1'],
            ),
            token,
          ),
          throwsA(isA<ContactsException>()),
        );
        await provider.action(
          const GoogleGroupAction(
            GoogleGroupOperation.membership,
            resourceName: 'contactGroups/starred',
            add: ['people/g1'],
          ),
          token,
        );
        expect(
          fixture.requests.any((r) => r.url.path.endsWith('/members:modify')),
          isTrue,
        );
      },
    );
    test('provider-specific known fields use the same revision-aware result contract', () async {
      final base = (await provider.page(
        source,
        cancellation: token,
      )).records.single;
      final result = await provider.action(
        GoogleFieldsAction(
          identity: base.identity,
          baseRevision: base.revision,
          replacement: people.Person(
            nicknames: [people.Nickname(value: 'Changed')],
          ),
          fields: {'nicknames'},
        ),
        token,
      );
      expect(
        result.records.single.projection.preservedPropertyNames,
        contains('nicknames'),
      );
      expect(
        fixture.requests.last.url.queryParameters['updatePersonFields'],
        'nicknames',
      );
    });
    test('read-only authorization, partial membership, photo limits and uncertain writes are distinct', () async {
      final reader = GoogleContactsProvider(
        accountId: 'reader',
        authorizedClient: MockClient((_) async => json(googleDocument())),
        grantedScopes: {people.PeopleServiceApi.contactsReadonlyScope},
      );
      final read = (await reader.discover(token)).single;
      expect(read.capabilities.update, isFalse);
      await expectLater(
        reader.create(read, const ContactPatch(), 'id', token),
        throwsA(
          isA<ContactsException>().having(
            (e) => e.kind,
            'kind',
            ContactsFailure.permission,
          ),
        ),
      );
      reader.close();
      final base = (await provider.page(
        source,
        cancellation: token,
      )).records.single;
      await expectLater(
        provider.setPhoto(
          source,
          base,
          Uint8List(2 * 1024 * 1024 + 1),
          'image/jpeg',
          token,
        ),
        throwsA(isA<ContactsException>()),
      );
      fixture.partialMembership = true;
      await expectLater(
        provider.action(
          const GoogleGroupAction(
            GoogleGroupOperation.membership,
            resourceName: 'contactGroups/friends',
            add: ['people/missing'],
          ),
          token,
        ),
        throwsA(isA<ContactsException>()),
      );
      fixture.failure = true;
      await expectLater(
        provider.create(source, const ContactPatch(), 'id', token),
        throwsA(
          isA<ContactsException>().having(
            (e) => e.kind,
            'kind',
            ContactsFailure.unknownOutcome,
          ),
        ),
      );
    });
  });
  group('Microsoft personal contacts', () {
    late MicrosoftFixture fixture;
    late MicrosoftContactsProvider provider;
    late List<ContactSource> sources;
    final token = ContactsCancellationToken();
    setUp(() async {
      fixture = MicrosoftFixture();
      provider = MicrosoftContactsProvider(
        accountId: 'ms',
        graph: fixture.graph(),
        grantedScopes: {'Contacts.ReadWrite'},
        personalAccount: false,
      );
      sources = await provider.discover(token);
    });
    tearDown(() => provider.close());
    test('folders remain distinct and each supported folder follows opaque delta URLs verbatim', () async {
      expect(sources.map((s) => s.id), ['default', 'Fa']);
      expect(sources.first.supportsSync, isFalse);
      expect(sources.last.supportsSync, isTrue);
      final first = await provider.page(sources.last, cancellation: token);
      final second = await provider.page(
        sources.last,
        page: first.nextPage,
        cancellation: token,
      );
      expect(first.records.single.complete, isTrue);
      expect(second.deleted.single.remoteId, 'deleted');
      expect(second.cursor, endsWith(r'?$deltatoken=A%2fB'));
      expect(
        fixture.requests.any((r) => r.url == Uri.parse(first.nextPage!)),
        isTrue,
      );
      expect(
        fixture.requests
            .where((r) => r.url.path.contains('/contacts'))
            .every((r) => r.headers['prefer'] == 'IdType="ImmutableId"'),
        isTrue,
      );
      expect(
        fixture.requests.every(
          (r) => !(r.headers['prefer'] ?? '').contains('timezone'),
        ),
        isTrue,
      );
    });
    test('full records retain extensions/unknown fields and partial delta is never saved as a full document', () async {
      final contact =
          (await provider.page(
                sources.last,
                cancellation: token,
              )).records.single
              as MicrosoftContactRecord;
      expect(contact.contact.extensions.single['opaque'], 'retained');
      expect(contact.contact.document['futureProperty'], {
        'value': 'preserved',
      });
      expect(contact.revision, 'change-one');
      expect(
        contactRecordFromJson(contact.toJson().cast()).toJson(),
        contact.toJson(),
      );
    });
    test('PATCH changes only intentional fields, retains display name and sends no invented If-Match', () async {
      final base = (await provider.page(
        sources.last,
        cancellation: token,
      )).records.single;
      final updated = await provider.update(
        sources.last,
        base,
        const ContactPatch(notes: FieldEdit.clear()),
        token,
      ) as MicrosoftContactRecord;
      final request = fixture.requests.last,
          body = jsonDecode(fixture.requests.last.body) as Map;
      expect(body, {'displayName': 'Zoë 李', 'personalNotes': ''});
      expect(request.headers.containsKey('if-match'), isFalse);
      expect(updated.contact.extensions.single['opaque'], 'retained');
      expect(updated.contact.document['futureProperty'], {
        'value': 'preserved',
      });
    });
    test('structured postal update sends every documented component and preserves native future subfields', () async {
      final base = (await provider.page(
        sources.last,
        cancellation: token,
      )).records.single;
      await provider.update(
        sources.last,
        base,
        const ContactPatch(
          addresses: FieldEdit.set([
            ContactAddress(
              street: 'New',
              city: 'Vancouver',
              region: 'BC',
              postcode: 'V2V',
              country: 'Canada',
              label: 'work',
            ),
          ]),
        ),
        token,
      );
      final body = jsonDecode(fixture.requests.last.body) as Map;
      expect(body['businessAddress'], {
        'street': 'New',
        'city': 'Vancouver',
        'state': 'BC',
        'postalCode': 'V2V',
        'countryOrRegion': 'Canada',
        'futurePostal': 'keep',
      });
      expect(body['homeAddress'].keys.toSet(), {
        'street',
        'city',
        'state',
        'postalCode',
        'countryOrRegion',
      });
    });
    test('preflight detects an observed changeKey difference without promising atomic conflict prevention', () async {
      final base = (await provider.page(
        sources.last,
        cancellation: token,
      )).records.single;
      fixture.changed = true;
      await expectLater(
        provider.update(
          sources.last,
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
      expect(fixture.requests.where((r) => r.method == 'PATCH'), isEmpty);
    });
    for (final link in [
      'https://evil.test/v1.0/me/contacts/delta',
      'https://graph.microsoft.com/v1.0/me/contactFolders/fA/contacts/delta',
    ]) {
      test('opaque paging URL rejects wrong origin/source, including different opaque ID case', () async {
        fixture.maliciousLink = link;
        await expectLater(
          provider.page(sources.last, cancellation: token),
          throwsA(isA<ContactsException>()),
        );
        expect(
          fixture.requests.every((r) => r.url.host == 'graph.microsoft.com'),
          isTrue,
        );
      });
    }
    test('CRUD, categories, provider-specific fields and folder management use actual endpoints', () async {
      final created = await provider.create(
        sources.last,
        const ContactPatch(labels: FieldEdit.set(['Category'])),
        'mutation',
        token,
      );
      expect((jsonDecode(fixture.requests.last.body) as Map)['categories'], [
        'Category',
      ]);
      final action = await provider.action(
        MicrosoftFieldsAction(
          identity: created.identity,
          baseRevision: created.revision,
          children: const FieldEdit.clear(),
          assistantName: const FieldEdit.set('New assistant'),
        ),
        token,
      );
      expect(
        action.records.single.projection.preservedPropertyNames,
        contains('assistantName'),
      );
      await provider.action(
        const MicrosoftFolderAction(
          MicrosoftFolderOperation.create,
          name: 'New',
          parentId: 'Fa',
        ),
        token,
      );
      expect(
        fixture.requests.last.url.path,
        '/v1.0/me/contactFolders/Fa/childFolders',
      );
      await provider.action(
        const MicrosoftFolderAction(
          MicrosoftFolderOperation.rename,
          folderId: 'Fa',
          name: 'Renamed',
        ),
        token,
      );
      await provider.action(
        const MicrosoftFolderAction(
          MicrosoftFolderOperation.delete,
          folderId: 'Fa',
        ),
        token,
      );
      await provider.delete(sources.last, action.records.single, token);
      expect(fixture.requests.last.method, 'DELETE');
    });
    test('personal-account photos are read only; org photo write and no undocumented removal', () async {
      final base = (await provider.page(
        sources.last,
        cancellation: token,
      )).records.single;
      expect(await provider.photo(sources.last, base, token), isNull);
      await provider.setPhoto(
        sources.last,
        base,
        Uint8List.fromList([1, 2]),
        'image/jpeg',
        token,
      );
      expect(
        fixture.requests.any(
          (r) => r.method == 'PUT' && r.url.path.endsWith(r'/photo/$value'),
        ),
        isTrue,
      );
      await expectLater(
        provider.setPhoto(sources.last, base, null, 'image/jpeg', token),
        throwsA(isA<ContactsException>()),
      );
      final personal = MicrosoftContactsProvider(
        accountId: 'personal',
        graph: GraphClient(
          httpClient: MockClient((_) async => json({'value': []})),
          tokenProvider: ({String? claims}) async =>
              const GraphAuthorization('fixture'),
        ),
        grantedScopes: {'Contacts.ReadWrite'},
        personalAccount: true,
      );
      expect(
        (await personal.discover(token)).single.capabilities.photoWrite,
        isFalse,
      );
      personal.close();
    });
    test('provider cardinality, unsupported structured values and default-folder mutations fail before write', () async {
      await expectLater(
        provider.create(
          sources.last,
          const ContactPatch(
            emails: FieldEdit.set([
              ContactValue('1@example.test'),
              ContactValue('2@example.test'),
              ContactValue('3@example.test'),
              ContactValue('4@example.test'),
            ]),
          ),
          'id',
          token,
        ),
        throwsA(isA<ContactsException>()),
      );
      await expectLater(
        provider.create(
          sources.last,
          const ContactPatch(
            addresses: FieldEdit.set([
              ContactAddress(poBox: 'PO', label: 'work'),
            ]),
          ),
          'id',
          token,
        ),
        throwsA(isA<ContactsException>()),
      );
      await expectLater(
        provider.action(
          const MicrosoftFolderAction(
            MicrosoftFolderOperation.delete,
            folderId: 'default',
          ),
          token,
        ),
        throwsA(isA<ContactsException>()),
      );
    });
  });
}

final class StalledGoogleClient extends http.BaseClient {
  final entered = Completer<void>();
  final body = StreamController<List<int>>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    entered.complete();
    return http.StreamedResponse(body.stream, 200);
  }
}
