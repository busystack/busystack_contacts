import 'package:busystack_contacts/busystack_contacts.dart';
import 'package:test/test.dart';

ContactProjection contact(
  int index, {
  List<String> emails = const [],
  String account = 'a',
  String source = 'book',
}) => ContactProjection(
  identity: ContactIdentity(
    accountId: account,
    provider: ContactProviderKind.carddav,
    sourceId: source,
    remoteId: '$index',
  ),
  name: ContactName(display: 'Match ${index.toString().padLeft(4, '0')}'),
  emails: emails.map(ContactValue.new).toList(),
);

// A read-only store makes page requests observable, including overlapping or
// repeated pages that a faulty adapter could return. Other operations fail.
class SuggestionStore implements ContactsStore, ContactsReadTransaction {
  SuggestionStore(this.records);
  final List<ContactProjection> records;
  final requests =
      <({String? account, String? source, int offset, int limit})>[];
  final counts = <String?>[];
  List<ContactProjection> Function(int offset, int limit)? page;
  final selectedSources = <ContactSource>[];

  @override
  Future<T> read<T>(Future<T> Function(ContactsReadTransaction) action) =>
      action(this);

  List<ContactProjection> matching(
    String? account,
    String? source,
    String query,
  ) => records
      .where(
        (record) =>
            (account == null || record.identity.accountId == account) &&
            (source == null ||
                selectedSources.any(
                  (value) =>
                      value.key == source &&
                      value.id == record.identity.sourceId &&
                      value.accountId == record.identity.accountId,
                )) &&
            record.searchText.contains(query.toLowerCase()),
      )
      .toList();

  @override
  Future<List<ContactProjection>> projections({
    String? accountId,
    String? sourceKey,
    String query = '',
    int limit = 100,
    int offset = 0,
  }) async {
    requests.add((
      account: accountId,
      source: sourceKey,
      offset: offset,
      limit: limit,
    ));
    return page?.call(offset, limit) ??
        matching(accountId, sourceKey, query).skip(offset).take(limit).toList();
  }

  @override
  Future<int> count({
    String? accountId,
    String? sourceKey,
    String query = '',
  }) async {
    counts.add(sourceKey);
    return matching(accountId, sourceKey, query).length;
  }

  @override
  Future<List<ContactSource>> sources({String? accountId}) async =>
      selectedSources
          .where((source) => accountId == null || source.accountId == accountId)
          .toList();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected store operation: ${invocation.memberName}',
  );
}

void main() {
  test(
    'F11 reaches eligible contacts after multiple full ineligible pages',
    () async {
      final store = SuggestionStore([
        ...List.generate(100, (index) => contact(index)),
        ...List.generate(
          100,
          (index) => contact(index + 100, emails: ['excluded@example.test']),
        ),
        contact(200, emails: ['one@example.test']),
        contact(201, emails: ['two@example.test']),
        contact(202, emails: ['three@example.test']),
      ]);
      final results = await ContactsDirectory(store: store).suggestRecipients(
        'MATCH',
        accountIds: {'a'},
        excludedAddresses: {'EXCLUDED@example.test'},
        limit: 2,
      );
      expect(results.map((value) => value.email), [
        'one@example.test',
        'two@example.test',
      ]);
      expect(store.requests.map((value) => value.offset), [0, 100, 200]);
      expect(store.counts, hasLength(1));
    },
  );

  test('overlapping pages deduplicate recipients and retain distinct native identities', () async {
    final first = contact(
      0,
      emails: ['Same@example.test', 'same@example.test'],
    );
    final alias = contact(100, emails: ['SAME@example.test']);
    final second = contact(101, emails: ['next@example.test']);
    final records = [
      first,
      ...List.generate(99, (index) => contact(index + 1)),
      alias,
      second,
    ];
    final store = SuggestionStore(records)
      ..page = (offset, limit) =>
          offset == 0 ? records.take(100).toList() : [first, alias, second];
    final results = await ContactsDirectory(store: store)
        .suggestRecipients('', accountIds: {'a'}, limit: 2);
    expect(results.map((value) => value.email), [
      'SAME@example.test',
      'next@example.test',
    ]);
    expect(results.first.name, first.displayName);
    expect(results.first.identities, [first.identity, alias.identity]);
    expect(store.requests.map((value) => value.offset), [0, 100]);
  });

  for (final size in [0, 1, 99, 100, 101, 199, 200, 201]) {
    test(
      'exhausted $size matching contacts terminate at the pagination boundary',
      () async {
        final store = SuggestionStore(List.generate(size, contact));
        expect(
          await ContactsDirectory(store: store)
              .suggestRecipients('match', accountIds: {'a'}),
          isEmpty,
        );
        expect(store.requests.map((value) => value.offset), [
          for (var offset = 0; offset < (size == 0 ? 1 : size); offset += 100)
            offset,
        ]);
        expect(store.counts.length, size < 100 ? 0 : 1);
      },
    );
  }

  test(
    'empty later page terminates even when the count reports more matches',
    () async {
      final records = List.generate(201, contact);
      final store = SuggestionStore(records)
        ..page = (offset, limit) =>
            offset == 0 ? records.take(limit).toList() : [];
      expect(
        await ContactsDirectory(store: store)
            .suggestRecipients('', accountIds: {'a'}),
        isEmpty,
      );
      expect(store.requests.map((value) => value.offset), [0, 100]);
    },
  );

  test('repeated full pages are bounded by the snapshot count', () async {
    final records = List.generate(301, contact);
    final store = SuggestionStore(records)
      ..page = (offset, limit) => records.take(limit).toList();
    expect(
      await ContactsDirectory(store: store)
          .suggestRecipients('', accountIds: {'a'}),
      isEmpty,
    );
    expect(store.requests.map((value) => value.offset), [0, 100, 200, 300]);
  });

  test('a duplicate-only page does not hide later eligible contacts', () async {
    final records = List.generate(201, contact);
    final last = contact(200, emails: ['later@example.test']);
    final store = SuggestionStore(records)
      ..page = (offset, limit) =>
          offset < 200 ? records.take(limit).toList() : [last];
    final results = await ContactsDirectory(store: store)
        .suggestRecipients('', accountIds: {'a'}, limit: 1);
    expect(results.single.email, 'later@example.test');
    expect(store.requests.map((value) => value.offset), [0, 100, 200]);
  });

  test('a query with no matches returns no suggestions', () async {
    final store = SuggestionStore([
      contact(0, emails: ['person@example.test']),
    ]);
    expect(
      await ContactsDirectory(store: store)
          .suggestRecipients('absent', accountIds: {'a'}),
      isEmpty,
    );
    expect(store.requests, hasLength(1));
    expect(store.counts, isEmpty);
  });

  for (final limit in [1, 8, 100]) {
    test(
      'limit $limit avoids another page, count or account request',
      () async {
        final store = SuggestionStore(
          List.generate(
            201,
            (index) => contact(index, emails: ['$index@example.test']),
          ),
        );
        final results = await ContactsDirectory(store: store)
            .suggestRecipients('', accountIds: {'a', 'b'}, limit: limit);
        expect(results.map((value) => value.email), [
          for (var index = 0; index < limit; index++) '$index@example.test',
        ]);
        expect(store.requests, hasLength(1));
        expect(store.counts, isEmpty);
      },
    );
  }

  test(
    'blank addresses and excluded recipients do not fill the limit',
    () async {
      final store = SuggestionStore([
        contact(0, emails: ['', '  ', 'excluded@example.test']),
        contact(1, emails: ['  Usable@example.test  ']),
      ]);
      final results = await ContactsDirectory(store: store).suggestRecipients(
        '',
        accountIds: {'a'},
        excludedAddresses: {' EXCLUDED@EXAMPLE.TEST '},
      );
      expect(results.single.email, 'Usable@example.test');
    },
  );

  test(
    'account and source selection preserve order and isolation across pages',
    () async {
      ContactSource source(String account, String id) => ContactSource(
        accountId: account,
        id: id,
        provider: ContactProviderKind.carddav,
        kind: ContactSourceKind.carddavAddressBook,
        name: id,
        remotePath: 'https://dav.test/$id/',
        capabilities: const ContactCapabilities(),
      );
      final selected = source('a', 'selected');
      final store =
          SuggestionStore([
              contact(0, source: 'disabled', emails: ['disabled@example.test']),
              ...List.generate(
                100,
                (index) => contact(index, source: 'selected'),
              ),
              contact(
                100,
                source: 'selected',
                emails: ['selected@example.test'],
              ),
              contact(0, account: 'b', emails: ['other@example.test']),
            ])
            ..selectedSources.addAll([
              source('a', 'disabled'),
              selected,
              source('b', 'book'),
            ]);
      final results = await ContactsDirectory(store: store).suggestRecipients(
        'match',
        accountIds: {'a'},
        sourceKeys: {selected.key},
        limit: 1,
      );
      expect(results.single.email, 'selected@example.test');
      expect(results.single.identities.single.sourceId, 'selected');
      expect(store.requests.map((value) => value.source), [
        selected.key,
        selected.key,
      ]);
      expect(store.requests.map((value) => value.offset), [0, 100]);
    },
  );

  test(
    'empty account selection makes no requests and invalid limits still fail',
    () async {
      final store = SuggestionStore([]);
      final directory = ContactsDirectory(store: store);
      expect(await directory.suggestRecipients('', accountIds: {}), isEmpty);
      for (final limit in [0, 101]) {
        await expectLater(
          directory.suggestRecipients('', accountIds: {'a'}, limit: limit),
          throwsRangeError,
        );
      }
      expect(store.requests, isEmpty);
    },
  );
}
