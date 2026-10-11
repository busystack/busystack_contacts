import 'package:busystack_contacts/google.dart';
import 'package:busystack_contacts/microsoft.dart';
import 'package:busystack_contacts/carddav.dart';

void main() {
  const identity = ContactIdentity(
    accountId: 'example',
    provider: ContactProviderKind.carddav,
    sourceId: 'book',
    remoteId: 'one.vcf',
  );
  final card = newVcard(
    const ContactPatch(
      name: FieldEdit.set(ContactName(given: 'Zoë', family: '李')),
      emails: FieldEdit.set([ContactValue('zoe@example.test', label: 'work')]),
    ),
  );
  final projection = projectVcard(identity, card);
  print(projection.displayName);
  print([
    GoogleContactsProvider,
    MicrosoftContactsProvider,
    CardDavContactsProvider,
  ]);
  final edited = applyVcardPatch(
    card,
    const ContactPatch(notes: FieldEdit.clear()),
  );
  if (edited.text('UID') != card.text('UID'))
    throw StateError('Identity must survive edits');
}
