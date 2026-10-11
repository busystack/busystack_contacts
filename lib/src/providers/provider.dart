import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../domain/models.dart';
import '../domain/records.dart';
import '../persistence/contacts_store.dart';

final class ContactsCancellationToken {
  final _signal = Completer<void>();
  final _stream = StreamController<void>.broadcast(sync: true);
  bool get isCancelled => _signal.isCompleted;
  Future<void> get whenCancelled => _signal.future;
  Stream<void> get cancellations => _stream.stream;
  void cancel() {
    if (!isCancelled) {
      _signal.complete();
      _stream.add(null);
      unawaited(_stream.close());
    }
  }

  void throwIfCancelled() {
    if (isCancelled)
      throw const ContactsException(ContactsFailure.cancelled, 'cancelled');
  }
}

final class ContactsPage {
  const ContactsPage({
    required this.records,
    this.deleted = const [],
    this.nextPage,
    this.cursor,
    this.fullEnumeration = false,
  });
  final List<ContactRecord> records;
  final List<ContactIdentity> deleted;
  final String? nextPage, cursor;
  final bool fullEnumeration;
}

abstract interface class ContactProviderAction {
  Map<String, Object?> toJson();
}

final class ContactActionResult {
  const ContactActionResult({
    this.records = const [],
    this.discoverSources = false,
  });
  final List<ContactRecord> records;
  final bool discoverSources;
}

abstract interface class ContactsProvider {
  String get accountId;
  ContactProviderKind get kind;
  Future<List<ContactSource>> discover(ContactsCancellationToken cancellation);
  Future<ContactsPage> page(
    ContactSource source, {
    String? cursor,
    String? page,
    required ContactsCancellationToken cancellation,
  });
  Future<ContactRecord> get(
    ContactSource source,
    ContactIdentity identity,
    ContactsCancellationToken cancellation,
  );
  Future<ContactRecord> create(
    ContactSource source,
    ContactPatch patch,
    String mutationId,
    ContactsCancellationToken cancellation, {
    String? fullVcard,
  });
  Future<ContactRecord> update(
    ContactSource source,
    ContactRecord base,
    ContactPatch patch,
    ContactsCancellationToken cancellation,
  );
  Future<void> delete(
    ContactSource source,
    ContactRecord base,
    ContactsCancellationToken cancellation,
  );
  Future<Uint8List?> photo(
    ContactSource source,
    ContactRecord record,
    ContactsCancellationToken cancellation,
  );
  Future<ContactRecord> setPhoto(
    ContactSource source,
    ContactRecord base,
    Uint8List? bytes,
    String mediaType,
    ContactsCancellationToken cancellation,
  );
  Future<ContactActionResult> action(
    ContactProviderAction action,
    ContactsCancellationToken cancellation,
  );
  ContactProviderAction decodeAction(Map<String, dynamic> json);

  /// Returns only a confirmed matching result. null leaves an ambiguous create
  /// unresolved; it is never permission to replay that create.
  Future<ContactRecord?> findCreated(
    ContactSource source,
    ContactMutation mutation,
    ContactsCancellationToken cancellation,
  );
  void close();
}

/// Anonymous HTTPS photo reads. The provider validates its own destination
/// policy; no account bearer or DAV credential is ever attached to this path.
Future<Uint8List> readContactPhoto(
  http.Client client,
  Uri uri,
  ContactsCancellationToken cancellation,
) async {
  cancellation.throwIfCancelled();
  final abort = Completer<void>();
  final sub = cancellation.cancellations.listen((_) {
    if (!abort.isCompleted) abort.complete();
  });
  Future<T> wait<T>(Future<T> pending) => Future.any([
    pending,
    abort.future.then<T>(
      (_) => throw const ContactsException(
        ContactsFailure.cancelled,
        'photo-cancelled',
      ),
    ),
  ]);
  StreamIterator<List<int>>? iterator;
  try {
    final request = http.AbortableRequest(
      'GET',
      uri,
      abortTrigger: abort.future,
    )..followRedirects = false;
    final response = await wait(
      client.send(request).timeout(const Duration(seconds: 30)),
    );
    if (response.statusCode != 200)
      throw const ContactsException(
        ContactsFailure.server,
        'photo-request-rejected',
      );
    if ((response.contentLength ?? 0) > 2 * 1024 * 1024)
      throw const ContactsException(ContactsFailure.protocol, 'photo-limit');
    final bytes = BytesBuilder(copy: false);
    iterator = StreamIterator(response.stream);
    while (await wait(
      iterator.moveNext().timeout(const Duration(seconds: 30)),
    )) {
      if (bytes.length + iterator.current.length > 2 * 1024 * 1024)
        throw const ContactsException(ContactsFailure.protocol, 'photo-limit');
      bytes.add(iterator.current);
    }
    return bytes.takeBytes();
  } finally {
    if (!abort.isCompleted) abort.complete();
    await iterator?.cancel();
    await sub.cancel();
  }
}
