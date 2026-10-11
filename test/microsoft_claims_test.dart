import 'dart:async';
import 'dart:convert';

import 'package:busystack_contacts/microsoft.dart';
import 'package:busystack_graph/busystack_graph.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support/transaction_store.dart';

const challengeClaims =
    '{"access_token":{"acrs":{"essential":true,"value":"c1"}}}';
http.Response challenge() => http.Response(
  '{}',
  401,
  headers: {
    'www-authenticate':
        'Bearer error="insufficient_claims", '
        'authorization_uri="https://login.microsoftonline.com/common/oauth2/authorize", '
        'claims="${base64.encode(utf8.encode(challengeClaims))}"',
    'request-id': 'claims-request',
  },
);

void main() {
  test('production Microsoft provider and directory acquire claims token before durable synchronization', () async {
    final store = TransactionStore(), acquired = <String?>[];
    var listRequests = 0;
    final graph = GraphClient(
      tokenProvider: ({String? claims}) async {
        acquired.add(claims);
        return GraphAuthorization(
          claims == null ? 'initial' : 'satisfying',
          grantedScopes: {'Contacts.ReadWrite'},
        );
      },
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1.0/me/contactFolders')
          return http.Response('{"value":[]}', 200);
        if (request.url.path == '/v1.0/me/contacts') {
          listRequests++;
          if (listRequests == 1) return challenge();
          expect(request.headers['authorization'], 'Bearer satisfying');
          expect(request.headers['prefer'], 'IdType="ImmutableId"');
          return http.Response('{"value":[{"id":"one"}]}', 200);
        }
        expect(request.url.path, '/v1.0/me/contacts/one');
        return http.Response(
          '{"id":"one","changeKey":"revision","displayName":"Zoë","emailAddresses":[{"address":"zoe@example.test"}],"extensions":[{"id":"retained","value":"native"}]}',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final directory = ContactsDirectory(store: store);
    directory.bind(
      MicrosoftContactsProvider(
        accountId: 'account',
        graph: graph,
        grantedScopes: {'Contacts.ReadWrite'},
        personalAccount: false,
      ),
    );
    await store.write(
      (tx) async => tx.putAccount(
        const ContactAccount(
          id: 'account',
          provider: ContactProviderKind.microsoft,
          displayName: 'Account',
          subject: 'subject',
          grantedScopes: {'Contacts.ReadWrite'},
        ),
      ),
    );
    final source = (await directory.discover('account')).single;
    await directory.synchronize(source.key);
    expect(acquired, [null, null, challengeClaims, null]);
    expect(listRequests, 2);
    final results = await directory.search('Zoë', accountId: 'account');
    expect(results.single.projection.displayName, 'Zoë');
    expect(
      (results.single as MicrosoftContactRecord).contact.document['extensions'],
      isNotEmpty,
    );
    expect(
      (await store.read((tx) async => tx.syncState(source.key)))!.scanId,
      isNull,
    );
    await directory.close();
    await store.close();
  });

  test('account removal during claims acquisition fences replay and durable data while companion remains', () async {
    final store = TransactionStore(),
        entered = Completer<void>(),
        release = Completer<GraphAuthorization>();
    var sends = 0;
    final graph = GraphClient(
      tokenProvider: ({String? claims}) async {
        if (claims != null) {
          entered.complete();
          return release.future;
        }
        return const GraphAuthorization('initial');
      },
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1.0/me/contactFolders')
          return http.Response('{"value":[]}', 200);
        sends++;
        return challenge();
      }),
    );
    final directory = ContactsDirectory(store: store);
    directory.bind(
      MicrosoftContactsProvider(
        accountId: 'account',
        graph: graph,
        grantedScopes: {'Contacts.Read'},
        personalAccount: false,
      ),
    );
    await store.write((tx) async {
      for (final id in ['account', 'companion']) {
        await tx.putAccount(
          ContactAccount(
            id: id,
            provider: ContactProviderKind.microsoft,
            displayName: id,
            subject: id,
            grantedScopes: {'Contacts.Read'},
          ),
        );
      }
    });
    final source = (await directory.discover('account')).single;
    final syncing = directory.synchronize(source.key);
    final observed = expectLater(
      syncing,
      throwsA(
        isA<ContactsException>().having(
          (error) => error.kind,
          'kind',
          ContactsFailure.cancelled,
        ),
      ),
    );
    await entered.future;
    await directory.disconnect('account', remove: true);
    await observed;
    release.complete(const GraphAuthorization('stale'));
    await Future<void>.delayed(Duration.zero);
    expect(sends, 1);
    expect(await store.read((tx) async => tx.account('account')), isNull);
    expect(await store.read((tx) async => tx.account('companion')), isNotNull);
    expect(await store.read((tx) async => tx.count()), 0);
    await directory.close();
    await store.close();
  });

  test('failed claims acquisition becomes actionable authentication failure without unknown mutation outcome', () async {
    var sends = 0;
    final graph = GraphClient(
      tokenProvider: ({String? claims}) async {
        if (claims != null) throw StateError('identity fixture failure');
        return const GraphAuthorization('initial');
      },
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1.0/me/contactFolders')
          return http.Response('{"value":[]}', 200);
        sends++;
        return challenge();
      }),
    );
    final provider = MicrosoftContactsProvider(
      accountId: 'account',
      graph: graph,
      grantedScopes: {'Contacts.ReadWrite'},
      personalAccount: false,
    );
    final source = (await provider.discover(ContactsCancellationToken()))
        .single;
    await expectLater(
      provider.create(
        source,
        const ContactPatch(),
        'mutation',
        ContactsCancellationToken(),
      ),
      throwsA(
        isA<ContactsException>()
            .having(
              (error) => error.kind,
              'kind',
              ContactsFailure.authentication,
            )
            .having((error) => error.claims, 'claims', challengeClaims)
            .having((error) => error.code, 'code', 'token-acquisition-failed'),
      ),
    );
    expect(sends, 1);
    provider.close();
  });
}
