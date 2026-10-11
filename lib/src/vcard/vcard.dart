import 'dart:convert';
import 'dart:typed_data';

/// Lossless source properties, including groups, parameter ordering and unknown
/// fields. Editing selected properties never rebuilds the rest of the card.
final class VCardParameter {
  const VCardParameter(this.name, this.values);
  final String name;
  final List<String> values;

  /// The containing card chooses parameter syntax. RFC 6868 updates vCard 4.0,
  /// not vCard 3.0's RFC 2425 parameter grammar.
  String encode({String version = '4.0'}) =>
      name +
      '=' +
      values
          .map((value) {
            if (!const {'3.0', '4.0'}.contains(version)) {
              throw const FormatException('Unsupported vCard version');
            }
            if (value.contains(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]')) ||
                version == '3.0' && value.contains(RegExp('["\r\n]'))) {
              // RFC 2425 has no parameter escape for DQUOTE or line breaks.
              // Reject an unrepresentable edit instead of changing its data or
              // silently upgrading the containing card.
              throw const FormatException('Unrepresentable vCard parameter');
            }
            final escaped = version == '4.0'
                ? value
                      .replaceAll('^', '^^')
                      .replaceAll('\r\n', '\n')
                      .replaceAll('\r', '\n')
                      .replaceAll('\n', '^n')
                      .replaceAll('"', '^\'')
                : value;
            return escaped.contains(RegExp(r'[:;,]'))
                ? '"' + escaped + '"'
                : escaped;
          })
          .join(',');
}

final class VCardProperty {
  const VCardProperty({
    required this.name,
    required this.rawValue,
    this.group,
    this.parameters = const [],
    this.originalLine,
  });
  final String name, rawValue;
  final String? group, originalLine;
  final List<VCardParameter> parameters;
  String get text => vcardUnescape(rawValue);
  List<String> structured({String separator = ';'}) =>
      splitVcard(rawValue, separator).map(vcardUnescape).toList();
  List<String> parameter(String name) => parameters
      .where((p) => p.name.toUpperCase() == name.toUpperCase())
      .expand((p) => p.values)
      .toList();
  String line({String version = '4.0'}) =>
      originalLine ??
      (group == null ? '' : '$group.') +
          name +
          parameters.map((p) => ';' + p.encode(version: version)).join() +
          ':' +
          rawValue;
  VCardProperty withValue(String value) => VCardProperty(
    name: name,
    group: group,
    parameters: parameters,
    rawValue: value,
  );
}

final class VCardLimits {
  const VCardLimits({
    this.maximumResourceBytes = 4 * 1024 * 1024,
    this.maximumPhotoBytes = 2 * 1024 * 1024,
    this.maximumProperties = 2000,
    this.maximumCards = 10000,
    this.maximumImportBytes = 32 * 1024 * 1024,
  });
  final int maximumResourceBytes,
      maximumPhotoBytes,
      maximumProperties,
      maximumCards,
      maximumImportBytes;
}

final class VCardDocument {
  const VCardDocument({
    required this.properties,
    required this.version,
    required this.complete,
    this.original,
  });
  final List<VCardProperty> properties;
  final String version;
  final bool complete;
  final String? original;
  Iterable<VCardProperty> values(String name) =>
      properties.where((p) => p.name.toUpperCase() == name.toUpperCase());
  String? text(String name) => values(name).firstOrNull?.text;
  VCardDocument replace(String name, Iterable<VCardProperty> replacements) {
    if (!complete) throw StateError('A partial card cannot replace a resource');
    final result = <VCardProperty>[];
    var inserted = false;
    for (final p in properties) {
      if (p.name.toUpperCase() == name.toUpperCase()) {
        if (!inserted) result.addAll(replacements);
        inserted = true;
      } else {
        if (p.name == 'END' && !inserted) {
          result.addAll(replacements);
          inserted = true;
        }
        result.add(p);
      }
    }
    return VCardDocument(
      properties: List.unmodifiable(result),
      version: version,
      complete: true,
    );
  }

  String serialize({bool preserveOriginal = true}) {
    if (preserveOriginal && original != null) return original!;
    return properties
            .map((p) => foldVcardLine(p.line(version: version)))
            .join('\r\n') +
        '\r\n';
  }

  Uint8List? embeddedPhoto({VCardLimits limits = const VCardLimits()}) {
    final photo = values('PHOTO').firstOrNull;
    if (photo == null) return null;
    String? payload;
    final value = photo.rawValue;
    if (value.startsWith('data:') && value.contains(';base64,')) {
      payload = value.substring(value.indexOf(';base64,') + 8);
    } else if (photo
        .parameter('ENCODING')
        .any((v) => v.toUpperCase() == 'B' || v.toUpperCase() == 'BASE64')) {
      payload = value;
    }
    if (payload == null) return null;
    if (payload.length > ((limits.maximumPhotoBytes + 2) ~/ 3) * 4)
      throw const FormatException('vCard photo limit');
    final bytes = base64.decode(payload);
    if (bytes.length > limits.maximumPhotoBytes)
      throw const FormatException('vCard photo limit');
    return bytes;
  }
}

VCardDocument parseVcard(
  String source, {
  bool complete = true,
  VCardLimits limits = const VCardLimits(),
}) {
  if (utf8.encode(source).length > limits.maximumResourceBytes ||
      source.contains('\u0000')) {
    throw const FormatException('vCard resource limit');
  }
  final unfolded = source
      .replaceAll(RegExp(r'\r?\n[ \t]'), '')
      .split(RegExp(r'\r?\n'))
      .where((line) => line.isNotEmpty)
      .toList();
  if (unfolded.length > limits.maximumProperties) {
    throw const FormatException('vCard property limit');
  }
  // vCard 3.0 allows VERSION after other properties. Determine it before
  // decoding any parameters so an ordinary ^n never becomes a line break.
  final versionLines = unfolded.where(
    (line) => RegExp(
      r'^(?:[A-Za-z0-9-]+\.)?VERSION(?:;|:)',
      caseSensitive: false,
    ).hasMatch(line),
  );
  if (versionLines.length != 1) {
    throw const FormatException('Invalid vCard cardinality');
  }
  final versionLine = versionLines.single;
  final versionColon = _delimiter(versionLine, ':');
  final version = versionColon < 0
      ? null
      : versionLine.substring(versionColon + 1);
  if (!const {'3.0', '4.0'}.contains(version)) {
    throw const FormatException('Unsupported vCard version');
  }
  final properties = <VCardProperty>[];
  for (final line in unfolded) {
    if (properties.length >= limits.maximumProperties)
      throw const FormatException('vCard property limit');
    final colon = _delimiter(line, ':');
    if (colon < 1)
      throw const FormatException('vCard content line missing colon');
    final header = splitVcard(line.substring(0, colon), ';', quoted: true);
    final identity = header.first.split('.');
    if (identity.length > 2 ||
        !RegExp(r'^[A-Za-z0-9-]+$').hasMatch(identity.last)) {
      throw const FormatException('Invalid vCard property name');
    }
    final parameters = <VCardParameter>[];
    for (final part in header.skip(1)) {
      final equal = part.indexOf('=');
      if (equal < 1 ||
          !RegExp(r'^[A-Za-z0-9-]+$').hasMatch(part.substring(0, equal))) {
        throw const FormatException('Invalid vCard parameter');
      }
      parameters.add(
        VCardParameter(
          part.substring(0, equal).toUpperCase(),
          splitVcard(part.substring(equal + 1), ',', quoted: true).map((value) {
            final unquoted = value.startsWith('"') && value.endsWith('"')
                ? value.substring(1, value.length - 1)
                : value;
            if (version == '3.0') return unquoted;
            return unquoted.replaceAllMapped(
              RegExp(r"\^([\^n'])"),
              (match) => switch (match.group(1)) {
                '^' => '^',
                "'" => '"',
                _ => '\n',
              },
            );
          }).toList(),
        ),
      );
    }
    properties.add(
      VCardProperty(
        name: identity.last.toUpperCase(),
        group: identity.length == 2 ? identity.first : null,
        parameters: List.unmodifiable(parameters),
        rawValue: line.substring(colon + 1),
        originalLine: line,
      ),
    );
  }
  String? value(String name) =>
      properties.where((p) => p.name == name).firstOrNull?.rawValue;
  if (value('BEGIN') != 'VCARD' ||
      value('END') != 'VCARD' ||
      properties.first.name != 'BEGIN' ||
      properties.last.name != 'END' ||
      properties.where((p) => p.name == 'BEGIN' || p.name == 'END').length !=
          2) {
    throw const FormatException('Invalid vCard envelope');
  }
  if (complete &&
      (value('FN') == null || version == '3.0' && value('N') == null)) {
    throw const FormatException('Required vCard name missing');
  }
  if (properties.where((p) => p.name == 'VERSION').length != 1 ||
      properties.where((p) => p.name == 'UID').length > 1)
    throw const FormatException('Invalid vCard cardinality');
  final doc = VCardDocument(
    properties: List.unmodifiable(properties),
    version: version!,
    complete: complete,
    original: source,
  );
  doc.embeddedPhoto(limits: limits);
  return doc;
}

final class VCardImportItem {
  const VCardImportItem(this.index, this.card, this.error);
  final int index;
  final VCardDocument? card;
  final String? error;
}

/// Bounded file import reports an invalid item without silently accepting it.
Future<List<VCardImportItem>> importVcards(
  Stream<List<int>> bytes, {
  VCardLimits limits = const VCardLimits(),
}) async {
  final buffer = BytesBuilder(copy: false);
  await for (final chunk in bytes) {
    if (buffer.length + chunk.length > limits.maximumImportBytes)
      throw const FormatException('vCard import limit');
    buffer.add(chunk);
  }
  final source = utf8.decode(buffer.takeBytes());
  final items = <VCardImportItem>[];
  final lines = source.split(RegExp(r'\r?\n'));
  StringBuffer? current;
  var index = 0;
  for (final line in lines) {
    if (line.toUpperCase() == 'BEGIN:VCARD') {
      if (current != null)
        items.add(VCardImportItem(index++, null, 'Unclosed previous card'));
      current = StringBuffer();
    }
    if (current == null) {
      if (line.trim().isNotEmpty)
        throw const FormatException('Unexpected data outside vCard');
      continue;
    }
    current.write(line + '\r\n');
    if (current.length > limits.maximumResourceBytes)
      throw const FormatException('vCard resource limit');
    if (line.toUpperCase() == 'END:VCARD') {
      if (index >= limits.maximumCards)
        throw const FormatException('vCard count limit');
      try {
        items.add(
          VCardImportItem(
            index++,
            parseVcard(current.toString(), limits: limits),
            null,
          ),
        );
      } on FormatException catch (error) {
        items.add(VCardImportItem(index++, null, error.message));
      }
      current = null;
    }
  }
  if (current != null) items.add(VCardImportItem(index, null, 'Unclosed card'));
  return items;
}

String vcardEscape(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll('\n', r'\n')
    .replaceAll(';', r'\;')
    .replaceAll(',', r'\,');
String vcardUnescape(String value) => value.replaceAllMapped(
  RegExp(r'\\([nN\\;,])'),
  (match) => const {'n': '\n', 'N': '\n'}[match.group(1)] ?? match.group(1)!,
);
List<String> splitVcard(String value, String delimiter, {bool quoted = false}) {
  final result = <String>[];
  var escaped = false, inQuotes = false, start = 0;
  for (var i = 0; i < value.length; i++) {
    final c = value[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (!quoted && c == r'\') {
      escaped = true;
      continue;
    }
    if (quoted && c == '"') inQuotes = !inQuotes;
    if (c == delimiter && !inQuotes) {
      result.add(value.substring(start, i));
      start = i + 1;
    }
  }
  if (inQuotes) throw const FormatException('Unclosed vCard parameter quote');
  result.add(value.substring(start));
  return result;
}

int _delimiter(String line, String delimiter) {
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    // Backslash escapes property text, never parameter syntax (RFC 2425 /
    // RFC 6350). In particular, it cannot hide a closing parameter quote.
    if (line[i] == '"') quoted = !quoted;
    if (line[i] == delimiter && !quoted) return i;
  }
  return -1;
}

String foldVcardLine(String line) {
  final output = StringBuffer();
  var length = 0;
  for (final rune in line.runes) {
    final text = String.fromCharCode(rune);
    final bytes = utf8.encode(text).length;
    if (length + bytes > 75) {
      output.write('\r\n ');
      length = 1;
    }
    output.write(text);
    length += bytes;
  }
  return output.toString();
}
