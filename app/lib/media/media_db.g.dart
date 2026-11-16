// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'media_db.dart';

// ignore_for_file: type=lint
class $CachedMediaTable extends CachedMedia
    with TableInfo<$CachedMediaTable, CachedMediaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedMediaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bytesMeta = const VerificationMeta('bytes');
  @override
  late final GeneratedColumn<Uint8List> bytes = GeneratedColumn<Uint8List>(
    'bytes',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
    'size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastUsedMeta = const VerificationMeta(
    'lastUsed',
  );
  @override
  late final GeneratedColumn<int> lastUsed = GeneratedColumn<int>(
    'last_used',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, bytes, size, lastUsed];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_media';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedMediaRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('bytes')) {
      context.handle(
        _bytesMeta,
        bytes.isAcceptableOrUnknown(data['bytes']!, _bytesMeta),
      );
    } else if (isInserting) {
      context.missing(_bytesMeta);
    }
    if (data.containsKey('size')) {
      context.handle(
        _sizeMeta,
        size.isAcceptableOrUnknown(data['size']!, _sizeMeta),
      );
    } else if (isInserting) {
      context.missing(_sizeMeta);
    }
    if (data.containsKey('last_used')) {
      context.handle(
        _lastUsedMeta,
        lastUsed.isAcceptableOrUnknown(data['last_used']!, _lastUsedMeta),
      );
    } else if (isInserting) {
      context.missing(_lastUsedMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  CachedMediaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedMediaRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      bytes: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}bytes'],
      )!,
      size: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size'],
      )!,
      lastUsed: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_used'],
      )!,
    );
  }

  @override
  $CachedMediaTable createAlias(String alias) {
    return $CachedMediaTable(attachedDatabase, alias);
  }
}

class CachedMediaRow extends DataClass implements Insertable<CachedMediaRow> {
  final String key;
  final Uint8List bytes;
  final int size;
  final int lastUsed;
  const CachedMediaRow({
    required this.key,
    required this.bytes,
    required this.size,
    required this.lastUsed,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['bytes'] = Variable<Uint8List>(bytes);
    map['size'] = Variable<int>(size);
    map['last_used'] = Variable<int>(lastUsed);
    return map;
  }

  CachedMediaCompanion toCompanion(bool nullToAbsent) {
    return CachedMediaCompanion(
      key: Value(key),
      bytes: Value(bytes),
      size: Value(size),
      lastUsed: Value(lastUsed),
    );
  }

  factory CachedMediaRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedMediaRow(
      key: serializer.fromJson<String>(json['key']),
      bytes: serializer.fromJson<Uint8List>(json['bytes']),
      size: serializer.fromJson<int>(json['size']),
      lastUsed: serializer.fromJson<int>(json['lastUsed']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'bytes': serializer.toJson<Uint8List>(bytes),
      'size': serializer.toJson<int>(size),
      'lastUsed': serializer.toJson<int>(lastUsed),
    };
  }

  CachedMediaRow copyWith({
    String? key,
    Uint8List? bytes,
    int? size,
    int? lastUsed,
  }) => CachedMediaRow(
    key: key ?? this.key,
    bytes: bytes ?? this.bytes,
    size: size ?? this.size,
    lastUsed: lastUsed ?? this.lastUsed,
  );
  CachedMediaRow copyWithCompanion(CachedMediaCompanion data) {
    return CachedMediaRow(
      key: data.key.present ? data.key.value : this.key,
      bytes: data.bytes.present ? data.bytes.value : this.bytes,
      size: data.size.present ? data.size.value : this.size,
      lastUsed: data.lastUsed.present ? data.lastUsed.value : this.lastUsed,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedMediaRow(')
          ..write('key: $key, ')
          ..write('bytes: $bytes, ')
          ..write('size: $size, ')
          ..write('lastUsed: $lastUsed')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(key, $driftBlobEquality.hash(bytes), size, lastUsed);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedMediaRow &&
          other.key == this.key &&
          $driftBlobEquality.equals(other.bytes, this.bytes) &&
          other.size == this.size &&
          other.lastUsed == this.lastUsed);
}

class CachedMediaCompanion extends UpdateCompanion<CachedMediaRow> {
  final Value<String> key;
  final Value<Uint8List> bytes;
  final Value<int> size;
  final Value<int> lastUsed;
  final Value<int> rowid;
  const CachedMediaCompanion({
    this.key = const Value.absent(),
    this.bytes = const Value.absent(),
    this.size = const Value.absent(),
    this.lastUsed = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedMediaCompanion.insert({
    required String key,
    required Uint8List bytes,
    required int size,
    required int lastUsed,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       bytes = Value(bytes),
       size = Value(size),
       lastUsed = Value(lastUsed);
  static Insertable<CachedMediaRow> custom({
    Expression<String>? key,
    Expression<Uint8List>? bytes,
    Expression<int>? size,
    Expression<int>? lastUsed,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (bytes != null) 'bytes': bytes,
      if (size != null) 'size': size,
      if (lastUsed != null) 'last_used': lastUsed,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedMediaCompanion copyWith({
    Value<String>? key,
    Value<Uint8List>? bytes,
    Value<int>? size,
    Value<int>? lastUsed,
    Value<int>? rowid,
  }) {
    return CachedMediaCompanion(
      key: key ?? this.key,
      bytes: bytes ?? this.bytes,
      size: size ?? this.size,
      lastUsed: lastUsed ?? this.lastUsed,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (bytes.present) {
      map['bytes'] = Variable<Uint8List>(bytes.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (lastUsed.present) {
      map['last_used'] = Variable<int>(lastUsed.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedMediaCompanion(')
          ..write('key: $key, ')
          ..write('bytes: $bytes, ')
          ..write('size: $size, ')
          ..write('lastUsed: $lastUsed, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PendingUploadsTable extends PendingUploads
    with TableInfo<$PendingUploadsTable, PendingUploadRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PendingUploadsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _chatIdMeta = const VerificationMeta('chatId');
  @override
  late final GeneratedColumn<String> chatId = GeneratedColumn<String>(
    'chat_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cipherMeta = const VerificationMeta('cipher');
  @override
  late final GeneratedColumn<Uint8List> cipher = GeneratedColumn<Uint8List>(
    'cipher',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _doneMeta = const VerificationMeta('done');
  @override
  late final GeneratedColumn<bool> done = GeneratedColumn<bool>(
    'done',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("done" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    key,
    messageId,
    chatId,
    kind,
    cipher,
    position,
    done,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'pending_uploads';
  @override
  VerificationContext validateIntegrity(
    Insertable<PendingUploadRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('chat_id')) {
      context.handle(
        _chatIdMeta,
        chatId.isAcceptableOrUnknown(data['chat_id']!, _chatIdMeta),
      );
    } else if (isInserting) {
      context.missing(_chatIdMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('cipher')) {
      context.handle(
        _cipherMeta,
        cipher.isAcceptableOrUnknown(data['cipher']!, _cipherMeta),
      );
    } else if (isInserting) {
      context.missing(_cipherMeta);
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    if (data.containsKey('done')) {
      context.handle(
        _doneMeta,
        done.isAcceptableOrUnknown(data['done']!, _doneMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  PendingUploadRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PendingUploadRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id'],
      )!,
      chatId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}chat_id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      cipher: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}cipher'],
      )!,
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position'],
      )!,
      done: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}done'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $PendingUploadsTable createAlias(String alias) {
    return $PendingUploadsTable(attachedDatabase, alias);
  }
}

class PendingUploadRow extends DataClass
    implements Insertable<PendingUploadRow> {
  final String key;
  final String messageId;
  final String chatId;

  /// photo | thumb | voice (the server's kinds).
  final String kind;
  final Uint8List cipher;

  /// Upload order within a message (thumbnail first).
  final int position;
  final bool done;
  final int createdAt;
  const PendingUploadRow({
    required this.key,
    required this.messageId,
    required this.chatId,
    required this.kind,
    required this.cipher,
    required this.position,
    required this.done,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['message_id'] = Variable<String>(messageId);
    map['chat_id'] = Variable<String>(chatId);
    map['kind'] = Variable<String>(kind);
    map['cipher'] = Variable<Uint8List>(cipher);
    map['position'] = Variable<int>(position);
    map['done'] = Variable<bool>(done);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  PendingUploadsCompanion toCompanion(bool nullToAbsent) {
    return PendingUploadsCompanion(
      key: Value(key),
      messageId: Value(messageId),
      chatId: Value(chatId),
      kind: Value(kind),
      cipher: Value(cipher),
      position: Value(position),
      done: Value(done),
      createdAt: Value(createdAt),
    );
  }

  factory PendingUploadRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PendingUploadRow(
      key: serializer.fromJson<String>(json['key']),
      messageId: serializer.fromJson<String>(json['messageId']),
      chatId: serializer.fromJson<String>(json['chatId']),
      kind: serializer.fromJson<String>(json['kind']),
      cipher: serializer.fromJson<Uint8List>(json['cipher']),
      position: serializer.fromJson<int>(json['position']),
      done: serializer.fromJson<bool>(json['done']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'messageId': serializer.toJson<String>(messageId),
      'chatId': serializer.toJson<String>(chatId),
      'kind': serializer.toJson<String>(kind),
      'cipher': serializer.toJson<Uint8List>(cipher),
      'position': serializer.toJson<int>(position),
      'done': serializer.toJson<bool>(done),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  PendingUploadRow copyWith({
    String? key,
    String? messageId,
    String? chatId,
    String? kind,
    Uint8List? cipher,
    int? position,
    bool? done,
    int? createdAt,
  }) => PendingUploadRow(
    key: key ?? this.key,
    messageId: messageId ?? this.messageId,
    chatId: chatId ?? this.chatId,
    kind: kind ?? this.kind,
    cipher: cipher ?? this.cipher,
    position: position ?? this.position,
    done: done ?? this.done,
    createdAt: createdAt ?? this.createdAt,
  );
  PendingUploadRow copyWithCompanion(PendingUploadsCompanion data) {
    return PendingUploadRow(
      key: data.key.present ? data.key.value : this.key,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      chatId: data.chatId.present ? data.chatId.value : this.chatId,
      kind: data.kind.present ? data.kind.value : this.kind,
      cipher: data.cipher.present ? data.cipher.value : this.cipher,
      position: data.position.present ? data.position.value : this.position,
      done: data.done.present ? data.done.value : this.done,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PendingUploadRow(')
          ..write('key: $key, ')
          ..write('messageId: $messageId, ')
          ..write('chatId: $chatId, ')
          ..write('kind: $kind, ')
          ..write('cipher: $cipher, ')
          ..write('position: $position, ')
          ..write('done: $done, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    key,
    messageId,
    chatId,
    kind,
    $driftBlobEquality.hash(cipher),
    position,
    done,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PendingUploadRow &&
          other.key == this.key &&
          other.messageId == this.messageId &&
          other.chatId == this.chatId &&
          other.kind == this.kind &&
          $driftBlobEquality.equals(other.cipher, this.cipher) &&
          other.position == this.position &&
          other.done == this.done &&
          other.createdAt == this.createdAt);
}

class PendingUploadsCompanion extends UpdateCompanion<PendingUploadRow> {
  final Value<String> key;
  final Value<String> messageId;
  final Value<String> chatId;
  final Value<String> kind;
  final Value<Uint8List> cipher;
  final Value<int> position;
  final Value<bool> done;
  final Value<int> createdAt;
  final Value<int> rowid;
  const PendingUploadsCompanion({
    this.key = const Value.absent(),
    this.messageId = const Value.absent(),
    this.chatId = const Value.absent(),
    this.kind = const Value.absent(),
    this.cipher = const Value.absent(),
    this.position = const Value.absent(),
    this.done = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PendingUploadsCompanion.insert({
    required String key,
    required String messageId,
    required String chatId,
    required String kind,
    required Uint8List cipher,
    required int position,
    this.done = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       messageId = Value(messageId),
       chatId = Value(chatId),
       kind = Value(kind),
       cipher = Value(cipher),
       position = Value(position),
       createdAt = Value(createdAt);
  static Insertable<PendingUploadRow> custom({
    Expression<String>? key,
    Expression<String>? messageId,
    Expression<String>? chatId,
    Expression<String>? kind,
    Expression<Uint8List>? cipher,
    Expression<int>? position,
    Expression<bool>? done,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (messageId != null) 'message_id': messageId,
      if (chatId != null) 'chat_id': chatId,
      if (kind != null) 'kind': kind,
      if (cipher != null) 'cipher': cipher,
      if (position != null) 'position': position,
      if (done != null) 'done': done,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PendingUploadsCompanion copyWith({
    Value<String>? key,
    Value<String>? messageId,
    Value<String>? chatId,
    Value<String>? kind,
    Value<Uint8List>? cipher,
    Value<int>? position,
    Value<bool>? done,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return PendingUploadsCompanion(
      key: key ?? this.key,
      messageId: messageId ?? this.messageId,
      chatId: chatId ?? this.chatId,
      kind: kind ?? this.kind,
      cipher: cipher ?? this.cipher,
      position: position ?? this.position,
      done: done ?? this.done,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (chatId.present) {
      map['chat_id'] = Variable<String>(chatId.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (cipher.present) {
      map['cipher'] = Variable<Uint8List>(cipher.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (done.present) {
      map['done'] = Variable<bool>(done.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PendingUploadsCompanion(')
          ..write('key: $key, ')
          ..write('messageId: $messageId, ')
          ..write('chatId: $chatId, ')
          ..write('kind: $kind, ')
          ..write('cipher: $cipher, ')
          ..write('position: $position, ')
          ..write('done: $done, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ExpiredMediaTable extends ExpiredMedia
    with TableInfo<$ExpiredMediaTable, ExpiredMediaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ExpiredMediaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'expired_media';
  @override
  VerificationContext validateIntegrity(
    Insertable<ExpiredMediaRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  ExpiredMediaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ExpiredMediaRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
    );
  }

  @override
  $ExpiredMediaTable createAlias(String alias) {
    return $ExpiredMediaTable(attachedDatabase, alias);
  }
}

class ExpiredMediaRow extends DataClass implements Insertable<ExpiredMediaRow> {
  final String key;
  const ExpiredMediaRow({required this.key});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    return map;
  }

  ExpiredMediaCompanion toCompanion(bool nullToAbsent) {
    return ExpiredMediaCompanion(key: Value(key));
  }

  factory ExpiredMediaRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ExpiredMediaRow(key: serializer.fromJson<String>(json['key']));
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{'key': serializer.toJson<String>(key)};
  }

  ExpiredMediaRow copyWith({String? key}) =>
      ExpiredMediaRow(key: key ?? this.key);
  ExpiredMediaRow copyWithCompanion(ExpiredMediaCompanion data) {
    return ExpiredMediaRow(key: data.key.present ? data.key.value : this.key);
  }

  @override
  String toString() {
    return (StringBuffer('ExpiredMediaRow(')
          ..write('key: $key')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => key.hashCode;
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ExpiredMediaRow && other.key == this.key);
}

class ExpiredMediaCompanion extends UpdateCompanion<ExpiredMediaRow> {
  final Value<String> key;
  final Value<int> rowid;
  const ExpiredMediaCompanion({
    this.key = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ExpiredMediaCompanion.insert({
    required String key,
    this.rowid = const Value.absent(),
  }) : key = Value(key);
  static Insertable<ExpiredMediaRow> custom({
    Expression<String>? key,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ExpiredMediaCompanion copyWith({Value<String>? key, Value<int>? rowid}) {
    return ExpiredMediaCompanion(
      key: key ?? this.key,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ExpiredMediaCompanion(')
          ..write('key: $key, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MediaMetaTable extends MediaMeta
    with TableInfo<$MediaMetaTable, MediaMetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MediaMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'media_meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<MediaMetaRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  MediaMetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MediaMetaRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $MediaMetaTable createAlias(String alias) {
    return $MediaMetaTable(attachedDatabase, alias);
  }
}

class MediaMetaRow extends DataClass implements Insertable<MediaMetaRow> {
  final String key;
  final String value;
  const MediaMetaRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  MediaMetaCompanion toCompanion(bool nullToAbsent) {
    return MediaMetaCompanion(key: Value(key), value: Value(value));
  }

  factory MediaMetaRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MediaMetaRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  MediaMetaRow copyWith({String? key, String? value}) =>
      MediaMetaRow(key: key ?? this.key, value: value ?? this.value);
  MediaMetaRow copyWithCompanion(MediaMetaCompanion data) {
    return MediaMetaRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MediaMetaRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MediaMetaRow &&
          other.key == this.key &&
          other.value == this.value);
}

class MediaMetaCompanion extends UpdateCompanion<MediaMetaRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const MediaMetaCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MediaMetaCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<MediaMetaRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MediaMetaCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return MediaMetaCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MediaMetaCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$MediaDb extends GeneratedDatabase {
  _$MediaDb(QueryExecutor e) : super(e);
  $MediaDbManager get managers => $MediaDbManager(this);
  late final $CachedMediaTable cachedMedia = $CachedMediaTable(this);
  late final $PendingUploadsTable pendingUploads = $PendingUploadsTable(this);
  late final $ExpiredMediaTable expiredMedia = $ExpiredMediaTable(this);
  late final $MediaMetaTable mediaMeta = $MediaMetaTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    cachedMedia,
    pendingUploads,
    expiredMedia,
    mediaMeta,
  ];
}

typedef $$CachedMediaTableCreateCompanionBuilder =
    CachedMediaCompanion Function({
      required String key,
      required Uint8List bytes,
      required int size,
      required int lastUsed,
      Value<int> rowid,
    });
typedef $$CachedMediaTableUpdateCompanionBuilder =
    CachedMediaCompanion Function({
      Value<String> key,
      Value<Uint8List> bytes,
      Value<int> size,
      Value<int> lastUsed,
      Value<int> rowid,
    });

class $$CachedMediaTableFilterComposer
    extends Composer<_$MediaDb, $CachedMediaTable> {
  $$CachedMediaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastUsed => $composableBuilder(
    column: $table.lastUsed,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CachedMediaTableOrderingComposer
    extends Composer<_$MediaDb, $CachedMediaTable> {
  $$CachedMediaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastUsed => $composableBuilder(
    column: $table.lastUsed,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CachedMediaTableAnnotationComposer
    extends Composer<_$MediaDb, $CachedMediaTable> {
  $$CachedMediaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<Uint8List> get bytes =>
      $composableBuilder(column: $table.bytes, builder: (column) => column);

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);

  GeneratedColumn<int> get lastUsed =>
      $composableBuilder(column: $table.lastUsed, builder: (column) => column);
}

class $$CachedMediaTableTableManager
    extends
        RootTableManager<
          _$MediaDb,
          $CachedMediaTable,
          CachedMediaRow,
          $$CachedMediaTableFilterComposer,
          $$CachedMediaTableOrderingComposer,
          $$CachedMediaTableAnnotationComposer,
          $$CachedMediaTableCreateCompanionBuilder,
          $$CachedMediaTableUpdateCompanionBuilder,
          (
            CachedMediaRow,
            BaseReferences<_$MediaDb, $CachedMediaTable, CachedMediaRow>,
          ),
          CachedMediaRow,
          PrefetchHooks Function()
        > {
  $$CachedMediaTableTableManager(_$MediaDb db, $CachedMediaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedMediaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedMediaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CachedMediaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<Uint8List> bytes = const Value.absent(),
                Value<int> size = const Value.absent(),
                Value<int> lastUsed = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedMediaCompanion(
                key: key,
                bytes: bytes,
                size: size,
                lastUsed: lastUsed,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String key,
                required Uint8List bytes,
                required int size,
                required int lastUsed,
                Value<int> rowid = const Value.absent(),
              }) => CachedMediaCompanion.insert(
                key: key,
                bytes: bytes,
                size: size,
                lastUsed: lastUsed,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$CachedMediaTable, CachedMediaRow>(table),
                  BaseReferences<_$MediaDb, $CachedMediaTable, CachedMediaRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CachedMediaTableProcessedTableManager =
    ProcessedTableManager<
      _$MediaDb,
      $CachedMediaTable,
      CachedMediaRow,
      $$CachedMediaTableFilterComposer,
      $$CachedMediaTableOrderingComposer,
      $$CachedMediaTableAnnotationComposer,
      $$CachedMediaTableCreateCompanionBuilder,
      $$CachedMediaTableUpdateCompanionBuilder,
      (
        CachedMediaRow,
        BaseReferences<_$MediaDb, $CachedMediaTable, CachedMediaRow>,
      ),
      CachedMediaRow,
      PrefetchHooks Function()
    >;
typedef $$PendingUploadsTableCreateCompanionBuilder =
    PendingUploadsCompanion Function({
      required String key,
      required String messageId,
      required String chatId,
      required String kind,
      required Uint8List cipher,
      required int position,
      Value<bool> done,
      required int createdAt,
      Value<int> rowid,
    });
typedef $$PendingUploadsTableUpdateCompanionBuilder =
    PendingUploadsCompanion Function({
      Value<String> key,
      Value<String> messageId,
      Value<String> chatId,
      Value<String> kind,
      Value<Uint8List> cipher,
      Value<int> position,
      Value<bool> done,
      Value<int> createdAt,
      Value<int> rowid,
    });

class $$PendingUploadsTableFilterComposer
    extends Composer<_$MediaDb, $PendingUploadsTable> {
  $$PendingUploadsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get chatId => $composableBuilder(
    column: $table.chatId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get cipher => $composableBuilder(
    column: $table.cipher,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get done => $composableBuilder(
    column: $table.done,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PendingUploadsTableOrderingComposer
    extends Composer<_$MediaDb, $PendingUploadsTable> {
  $$PendingUploadsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get chatId => $composableBuilder(
    column: $table.chatId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get cipher => $composableBuilder(
    column: $table.cipher,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get done => $composableBuilder(
    column: $table.done,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PendingUploadsTableAnnotationComposer
    extends Composer<_$MediaDb, $PendingUploadsTable> {
  $$PendingUploadsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<String> get chatId =>
      $composableBuilder(column: $table.chatId, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<Uint8List> get cipher =>
      $composableBuilder(column: $table.cipher, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<bool> get done =>
      $composableBuilder(column: $table.done, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$PendingUploadsTableTableManager
    extends
        RootTableManager<
          _$MediaDb,
          $PendingUploadsTable,
          PendingUploadRow,
          $$PendingUploadsTableFilterComposer,
          $$PendingUploadsTableOrderingComposer,
          $$PendingUploadsTableAnnotationComposer,
          $$PendingUploadsTableCreateCompanionBuilder,
          $$PendingUploadsTableUpdateCompanionBuilder,
          (
            PendingUploadRow,
            BaseReferences<_$MediaDb, $PendingUploadsTable, PendingUploadRow>,
          ),
          PendingUploadRow,
          PrefetchHooks Function()
        > {
  $$PendingUploadsTableTableManager(_$MediaDb db, $PendingUploadsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PendingUploadsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PendingUploadsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PendingUploadsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> messageId = const Value.absent(),
                Value<String> chatId = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<Uint8List> cipher = const Value.absent(),
                Value<int> position = const Value.absent(),
                Value<bool> done = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PendingUploadsCompanion(
                key: key,
                messageId: messageId,
                chatId: chatId,
                kind: kind,
                cipher: cipher,
                position: position,
                done: done,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String key,
                required String messageId,
                required String chatId,
                required String kind,
                required Uint8List cipher,
                required int position,
                Value<bool> done = const Value.absent(),
                required int createdAt,
                Value<int> rowid = const Value.absent(),
              }) => PendingUploadsCompanion.insert(
                key: key,
                messageId: messageId,
                chatId: chatId,
                kind: kind,
                cipher: cipher,
                position: position,
                done: done,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PendingUploadsTable, PendingUploadRow>(table),
                  BaseReferences<
                    _$MediaDb,
                    $PendingUploadsTable,
                    PendingUploadRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PendingUploadsTableProcessedTableManager =
    ProcessedTableManager<
      _$MediaDb,
      $PendingUploadsTable,
      PendingUploadRow,
      $$PendingUploadsTableFilterComposer,
      $$PendingUploadsTableOrderingComposer,
      $$PendingUploadsTableAnnotationComposer,
      $$PendingUploadsTableCreateCompanionBuilder,
      $$PendingUploadsTableUpdateCompanionBuilder,
      (
        PendingUploadRow,
        BaseReferences<_$MediaDb, $PendingUploadsTable, PendingUploadRow>,
      ),
      PendingUploadRow,
      PrefetchHooks Function()
    >;
typedef $$ExpiredMediaTableCreateCompanionBuilder =
    ExpiredMediaCompanion Function({required String key, Value<int> rowid});
typedef $$ExpiredMediaTableUpdateCompanionBuilder =
    ExpiredMediaCompanion Function({Value<String> key, Value<int> rowid});

class $$ExpiredMediaTableFilterComposer
    extends Composer<_$MediaDb, $ExpiredMediaTable> {
  $$ExpiredMediaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ExpiredMediaTableOrderingComposer
    extends Composer<_$MediaDb, $ExpiredMediaTable> {
  $$ExpiredMediaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ExpiredMediaTableAnnotationComposer
    extends Composer<_$MediaDb, $ExpiredMediaTable> {
  $$ExpiredMediaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);
}

class $$ExpiredMediaTableTableManager
    extends
        RootTableManager<
          _$MediaDb,
          $ExpiredMediaTable,
          ExpiredMediaRow,
          $$ExpiredMediaTableFilterComposer,
          $$ExpiredMediaTableOrderingComposer,
          $$ExpiredMediaTableAnnotationComposer,
          $$ExpiredMediaTableCreateCompanionBuilder,
          $$ExpiredMediaTableUpdateCompanionBuilder,
          (
            ExpiredMediaRow,
            BaseReferences<_$MediaDb, $ExpiredMediaTable, ExpiredMediaRow>,
          ),
          ExpiredMediaRow,
          PrefetchHooks Function()
        > {
  $$ExpiredMediaTableTableManager(_$MediaDb db, $ExpiredMediaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ExpiredMediaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ExpiredMediaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ExpiredMediaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => ExpiredMediaCompanion(key: key, rowid: rowid),
          createCompanionCallback: ({
            required String key,
            Value<int> rowid = const Value.absent(),
          }) => ExpiredMediaCompanion.insert(key: key, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ExpiredMediaTable, ExpiredMediaRow>(table),
                  BaseReferences<
                    _$MediaDb,
                    $ExpiredMediaTable,
                    ExpiredMediaRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ExpiredMediaTableProcessedTableManager =
    ProcessedTableManager<
      _$MediaDb,
      $ExpiredMediaTable,
      ExpiredMediaRow,
      $$ExpiredMediaTableFilterComposer,
      $$ExpiredMediaTableOrderingComposer,
      $$ExpiredMediaTableAnnotationComposer,
      $$ExpiredMediaTableCreateCompanionBuilder,
      $$ExpiredMediaTableUpdateCompanionBuilder,
      (
        ExpiredMediaRow,
        BaseReferences<_$MediaDb, $ExpiredMediaTable, ExpiredMediaRow>,
      ),
      ExpiredMediaRow,
      PrefetchHooks Function()
    >;
typedef $$MediaMetaTableCreateCompanionBuilder = MediaMetaCompanion Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$MediaMetaTableUpdateCompanionBuilder = MediaMetaCompanion Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$MediaMetaTableFilterComposer
    extends Composer<_$MediaDb, $MediaMetaTable> {
  $$MediaMetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MediaMetaTableOrderingComposer
    extends Composer<_$MediaDb, $MediaMetaTable> {
  $$MediaMetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MediaMetaTableAnnotationComposer
    extends Composer<_$MediaDb, $MediaMetaTable> {
  $$MediaMetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$MediaMetaTableTableManager
    extends
        RootTableManager<
          _$MediaDb,
          $MediaMetaTable,
          MediaMetaRow,
          $$MediaMetaTableFilterComposer,
          $$MediaMetaTableOrderingComposer,
          $$MediaMetaTableAnnotationComposer,
          $$MediaMetaTableCreateCompanionBuilder,
          $$MediaMetaTableUpdateCompanionBuilder,
          (
            MediaMetaRow,
            BaseReferences<_$MediaDb, $MediaMetaTable, MediaMetaRow>,
          ),
          MediaMetaRow,
          PrefetchHooks Function()
        > {
  $$MediaMetaTableTableManager(_$MediaDb db, $MediaMetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MediaMetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MediaMetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MediaMetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => MediaMetaCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) => MediaMetaCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MediaMetaTable, MediaMetaRow>(table),
                  BaseReferences<_$MediaDb, $MediaMetaTable, MediaMetaRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MediaMetaTableProcessedTableManager =
    ProcessedTableManager<
      _$MediaDb,
      $MediaMetaTable,
      MediaMetaRow,
      $$MediaMetaTableFilterComposer,
      $$MediaMetaTableOrderingComposer,
      $$MediaMetaTableAnnotationComposer,
      $$MediaMetaTableCreateCompanionBuilder,
      $$MediaMetaTableUpdateCompanionBuilder,
      (MediaMetaRow, BaseReferences<_$MediaDb, $MediaMetaTable, MediaMetaRow>),
      MediaMetaRow,
      PrefetchHooks Function()
    >;

class $MediaDbManager {
  final _$MediaDb _db;
  $MediaDbManager(this._db);
  $$CachedMediaTableTableManager get cachedMedia =>
      $$CachedMediaTableTableManager(_db, _db.cachedMedia);
  $$PendingUploadsTableTableManager get pendingUploads =>
      $$PendingUploadsTableTableManager(_db, _db.pendingUploads);
  $$ExpiredMediaTableTableManager get expiredMedia =>
      $$ExpiredMediaTableTableManager(_db, _db.expiredMedia);
  $$MediaMetaTableTableManager get mediaMeta =>
      $$MediaMetaTableTableManager(_db, _db.mediaMeta);
}
