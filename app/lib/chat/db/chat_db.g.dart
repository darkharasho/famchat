// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'chat_db.dart';

// ignore_for_file: type=lint
class $LocalChatsTable extends LocalChats
    with TableInfo<$LocalChatsTable, ChatRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalChatsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
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
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdByMeta = const VerificationMeta(
    'createdBy',
  );
  @override
  late final GeneratedColumn<String> createdBy = GeneratedColumn<String>(
    'created_by',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _currentEpochMeta = const VerificationMeta(
    'currentEpoch',
  );
  @override
  late final GeneratedColumn<int> currentEpoch = GeneratedColumn<int>(
    'current_epoch',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _epochReadyMeta = const VerificationMeta(
    'epochReady',
  );
  @override
  late final GeneratedColumn<bool> epochReady = GeneratedColumn<bool>(
    'epoch_ready',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("epoch_ready" IN (0, 1))',
    ),
  );
  static const VerificationMeta _lastSeqMeta = const VerificationMeta(
    'lastSeq',
  );
  @override
  late final GeneratedColumn<int> lastSeq = GeneratedColumn<int>(
    'last_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastMessageAtMeta = const VerificationMeta(
    'lastMessageAt',
  );
  @override
  late final GeneratedColumn<int> lastMessageAt = GeneratedColumn<int>(
    'last_message_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
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
  static const VerificationMeta _myLastReadSeqMeta = const VerificationMeta(
    'myLastReadSeq',
  );
  @override
  late final GeneratedColumn<int> myLastReadSeq = GeneratedColumn<int>(
    'my_last_read_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _syncedSeqMeta = const VerificationMeta(
    'syncedSeq',
  );
  @override
  late final GeneratedColumn<int> syncedSeq = GeneratedColumn<int>(
    'synced_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    kind,
    title,
    createdBy,
    currentEpoch,
    epochReady,
    lastSeq,
    lastMessageAt,
    createdAt,
    myLastReadSeq,
    syncedSeq,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_chats';
  @override
  VerificationContext validateIntegrity(
    Insertable<ChatRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('created_by')) {
      context.handle(
        _createdByMeta,
        createdBy.isAcceptableOrUnknown(data['created_by']!, _createdByMeta),
      );
    } else if (isInserting) {
      context.missing(_createdByMeta);
    }
    if (data.containsKey('current_epoch')) {
      context.handle(
        _currentEpochMeta,
        currentEpoch.isAcceptableOrUnknown(
          data['current_epoch']!,
          _currentEpochMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_currentEpochMeta);
    }
    if (data.containsKey('epoch_ready')) {
      context.handle(
        _epochReadyMeta,
        epochReady.isAcceptableOrUnknown(data['epoch_ready']!, _epochReadyMeta),
      );
    } else if (isInserting) {
      context.missing(_epochReadyMeta);
    }
    if (data.containsKey('last_seq')) {
      context.handle(
        _lastSeqMeta,
        lastSeq.isAcceptableOrUnknown(data['last_seq']!, _lastSeqMeta),
      );
    } else if (isInserting) {
      context.missing(_lastSeqMeta);
    }
    if (data.containsKey('last_message_at')) {
      context.handle(
        _lastMessageAtMeta,
        lastMessageAt.isAcceptableOrUnknown(
          data['last_message_at']!,
          _lastMessageAtMeta,
        ),
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
    if (data.containsKey('my_last_read_seq')) {
      context.handle(
        _myLastReadSeqMeta,
        myLastReadSeq.isAcceptableOrUnknown(
          data['my_last_read_seq']!,
          _myLastReadSeqMeta,
        ),
      );
    }
    if (data.containsKey('synced_seq')) {
      context.handle(
        _syncedSeqMeta,
        syncedSeq.isAcceptableOrUnknown(data['synced_seq']!, _syncedSeqMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ChatRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChatRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      ),
      createdBy: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_by'],
      )!,
      currentEpoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}current_epoch'],
      )!,
      epochReady: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}epoch_ready'],
      )!,
      lastSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_seq'],
      )!,
      lastMessageAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_message_at'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      myLastReadSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}my_last_read_seq'],
      )!,
      syncedSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}synced_seq'],
      )!,
    );
  }

  @override
  $LocalChatsTable createAlias(String alias) {
    return $LocalChatsTable(attachedDatabase, alias);
  }
}

class ChatRow extends DataClass implements Insertable<ChatRow> {
  final String id;
  final String kind;
  final String? title;
  final String createdBy;
  final int currentEpoch;
  final bool epochReady;
  final int lastSeq;
  final int? lastMessageAt;
  final int createdAt;
  final int myLastReadSeq;

  /// Every message with seq ≤ this is stored locally (the `after=` cursor).
  final int syncedSeq;
  const ChatRow({
    required this.id,
    required this.kind,
    this.title,
    required this.createdBy,
    required this.currentEpoch,
    required this.epochReady,
    required this.lastSeq,
    this.lastMessageAt,
    required this.createdAt,
    required this.myLastReadSeq,
    required this.syncedSeq,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || title != null) {
      map['title'] = Variable<String>(title);
    }
    map['created_by'] = Variable<String>(createdBy);
    map['current_epoch'] = Variable<int>(currentEpoch);
    map['epoch_ready'] = Variable<bool>(epochReady);
    map['last_seq'] = Variable<int>(lastSeq);
    if (!nullToAbsent || lastMessageAt != null) {
      map['last_message_at'] = Variable<int>(lastMessageAt);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['my_last_read_seq'] = Variable<int>(myLastReadSeq);
    map['synced_seq'] = Variable<int>(syncedSeq);
    return map;
  }

  LocalChatsCompanion toCompanion(bool nullToAbsent) {
    return LocalChatsCompanion(
      id: Value(id),
      kind: Value(kind),
      title: title == null && nullToAbsent
          ? const Value.absent()
          : Value(title),
      createdBy: Value(createdBy),
      currentEpoch: Value(currentEpoch),
      epochReady: Value(epochReady),
      lastSeq: Value(lastSeq),
      lastMessageAt: lastMessageAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastMessageAt),
      createdAt: Value(createdAt),
      myLastReadSeq: Value(myLastReadSeq),
      syncedSeq: Value(syncedSeq),
    );
  }

  factory ChatRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChatRow(
      id: serializer.fromJson<String>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      title: serializer.fromJson<String?>(json['title']),
      createdBy: serializer.fromJson<String>(json['createdBy']),
      currentEpoch: serializer.fromJson<int>(json['currentEpoch']),
      epochReady: serializer.fromJson<bool>(json['epochReady']),
      lastSeq: serializer.fromJson<int>(json['lastSeq']),
      lastMessageAt: serializer.fromJson<int?>(json['lastMessageAt']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      myLastReadSeq: serializer.fromJson<int>(json['myLastReadSeq']),
      syncedSeq: serializer.fromJson<int>(json['syncedSeq']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'kind': serializer.toJson<String>(kind),
      'title': serializer.toJson<String?>(title),
      'createdBy': serializer.toJson<String>(createdBy),
      'currentEpoch': serializer.toJson<int>(currentEpoch),
      'epochReady': serializer.toJson<bool>(epochReady),
      'lastSeq': serializer.toJson<int>(lastSeq),
      'lastMessageAt': serializer.toJson<int?>(lastMessageAt),
      'createdAt': serializer.toJson<int>(createdAt),
      'myLastReadSeq': serializer.toJson<int>(myLastReadSeq),
      'syncedSeq': serializer.toJson<int>(syncedSeq),
    };
  }

  ChatRow copyWith({
    String? id,
    String? kind,
    Value<String?> title = const Value.absent(),
    String? createdBy,
    int? currentEpoch,
    bool? epochReady,
    int? lastSeq,
    Value<int?> lastMessageAt = const Value.absent(),
    int? createdAt,
    int? myLastReadSeq,
    int? syncedSeq,
  }) => ChatRow(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    title: title.present ? title.value : this.title,
    createdBy: createdBy ?? this.createdBy,
    currentEpoch: currentEpoch ?? this.currentEpoch,
    epochReady: epochReady ?? this.epochReady,
    lastSeq: lastSeq ?? this.lastSeq,
    lastMessageAt: lastMessageAt.present
        ? lastMessageAt.value
        : this.lastMessageAt,
    createdAt: createdAt ?? this.createdAt,
    myLastReadSeq: myLastReadSeq ?? this.myLastReadSeq,
    syncedSeq: syncedSeq ?? this.syncedSeq,
  );
  ChatRow copyWithCompanion(LocalChatsCompanion data) {
    return ChatRow(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      title: data.title.present ? data.title.value : this.title,
      createdBy: data.createdBy.present ? data.createdBy.value : this.createdBy,
      currentEpoch: data.currentEpoch.present
          ? data.currentEpoch.value
          : this.currentEpoch,
      epochReady: data.epochReady.present
          ? data.epochReady.value
          : this.epochReady,
      lastSeq: data.lastSeq.present ? data.lastSeq.value : this.lastSeq,
      lastMessageAt: data.lastMessageAt.present
          ? data.lastMessageAt.value
          : this.lastMessageAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      myLastReadSeq: data.myLastReadSeq.present
          ? data.myLastReadSeq.value
          : this.myLastReadSeq,
      syncedSeq: data.syncedSeq.present ? data.syncedSeq.value : this.syncedSeq,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChatRow(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('title: $title, ')
          ..write('createdBy: $createdBy, ')
          ..write('currentEpoch: $currentEpoch, ')
          ..write('epochReady: $epochReady, ')
          ..write('lastSeq: $lastSeq, ')
          ..write('lastMessageAt: $lastMessageAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('myLastReadSeq: $myLastReadSeq, ')
          ..write('syncedSeq: $syncedSeq')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    title,
    createdBy,
    currentEpoch,
    epochReady,
    lastSeq,
    lastMessageAt,
    createdAt,
    myLastReadSeq,
    syncedSeq,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChatRow &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.title == this.title &&
          other.createdBy == this.createdBy &&
          other.currentEpoch == this.currentEpoch &&
          other.epochReady == this.epochReady &&
          other.lastSeq == this.lastSeq &&
          other.lastMessageAt == this.lastMessageAt &&
          other.createdAt == this.createdAt &&
          other.myLastReadSeq == this.myLastReadSeq &&
          other.syncedSeq == this.syncedSeq);
}

class LocalChatsCompanion extends UpdateCompanion<ChatRow> {
  final Value<String> id;
  final Value<String> kind;
  final Value<String?> title;
  final Value<String> createdBy;
  final Value<int> currentEpoch;
  final Value<bool> epochReady;
  final Value<int> lastSeq;
  final Value<int?> lastMessageAt;
  final Value<int> createdAt;
  final Value<int> myLastReadSeq;
  final Value<int> syncedSeq;
  final Value<int> rowid;
  const LocalChatsCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.title = const Value.absent(),
    this.createdBy = const Value.absent(),
    this.currentEpoch = const Value.absent(),
    this.epochReady = const Value.absent(),
    this.lastSeq = const Value.absent(),
    this.lastMessageAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.myLastReadSeq = const Value.absent(),
    this.syncedSeq = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalChatsCompanion.insert({
    required String id,
    required String kind,
    this.title = const Value.absent(),
    required String createdBy,
    required int currentEpoch,
    required bool epochReady,
    required int lastSeq,
    this.lastMessageAt = const Value.absent(),
    required int createdAt,
    this.myLastReadSeq = const Value.absent(),
    this.syncedSeq = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       kind = Value(kind),
       createdBy = Value(createdBy),
       currentEpoch = Value(currentEpoch),
       epochReady = Value(epochReady),
       lastSeq = Value(lastSeq),
       createdAt = Value(createdAt);
  static Insertable<ChatRow> custom({
    Expression<String>? id,
    Expression<String>? kind,
    Expression<String>? title,
    Expression<String>? createdBy,
    Expression<int>? currentEpoch,
    Expression<bool>? epochReady,
    Expression<int>? lastSeq,
    Expression<int>? lastMessageAt,
    Expression<int>? createdAt,
    Expression<int>? myLastReadSeq,
    Expression<int>? syncedSeq,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (title != null) 'title': title,
      if (createdBy != null) 'created_by': createdBy,
      if (currentEpoch != null) 'current_epoch': currentEpoch,
      if (epochReady != null) 'epoch_ready': epochReady,
      if (lastSeq != null) 'last_seq': lastSeq,
      if (lastMessageAt != null) 'last_message_at': lastMessageAt,
      if (createdAt != null) 'created_at': createdAt,
      if (myLastReadSeq != null) 'my_last_read_seq': myLastReadSeq,
      if (syncedSeq != null) 'synced_seq': syncedSeq,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalChatsCompanion copyWith({
    Value<String>? id,
    Value<String>? kind,
    Value<String?>? title,
    Value<String>? createdBy,
    Value<int>? currentEpoch,
    Value<bool>? epochReady,
    Value<int>? lastSeq,
    Value<int?>? lastMessageAt,
    Value<int>? createdAt,
    Value<int>? myLastReadSeq,
    Value<int>? syncedSeq,
    Value<int>? rowid,
  }) {
    return LocalChatsCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      createdBy: createdBy ?? this.createdBy,
      currentEpoch: currentEpoch ?? this.currentEpoch,
      epochReady: epochReady ?? this.epochReady,
      lastSeq: lastSeq ?? this.lastSeq,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      createdAt: createdAt ?? this.createdAt,
      myLastReadSeq: myLastReadSeq ?? this.myLastReadSeq,
      syncedSeq: syncedSeq ?? this.syncedSeq,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (createdBy.present) {
      map['created_by'] = Variable<String>(createdBy.value);
    }
    if (currentEpoch.present) {
      map['current_epoch'] = Variable<int>(currentEpoch.value);
    }
    if (epochReady.present) {
      map['epoch_ready'] = Variable<bool>(epochReady.value);
    }
    if (lastSeq.present) {
      map['last_seq'] = Variable<int>(lastSeq.value);
    }
    if (lastMessageAt.present) {
      map['last_message_at'] = Variable<int>(lastMessageAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (myLastReadSeq.present) {
      map['my_last_read_seq'] = Variable<int>(myLastReadSeq.value);
    }
    if (syncedSeq.present) {
      map['synced_seq'] = Variable<int>(syncedSeq.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalChatsCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('title: $title, ')
          ..write('createdBy: $createdBy, ')
          ..write('currentEpoch: $currentEpoch, ')
          ..write('epochReady: $epochReady, ')
          ..write('lastSeq: $lastSeq, ')
          ..write('lastMessageAt: $lastMessageAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('myLastReadSeq: $myLastReadSeq, ')
          ..write('syncedSeq: $syncedSeq, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalMembersTable extends LocalMembers
    with TableInfo<$LocalMembersTable, MemberRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalMembersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _chatIdMeta = const VerificationMeta('chatId');
  @override
  late final GeneratedColumn<String> chatId = GeneratedColumn<String>(
    'chat_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _joinedSeqMeta = const VerificationMeta(
    'joinedSeq',
  );
  @override
  late final GeneratedColumn<int> joinedSeq = GeneratedColumn<int>(
    'joined_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastReadSeqMeta = const VerificationMeta(
    'lastReadSeq',
  );
  @override
  late final GeneratedColumn<int> lastReadSeq = GeneratedColumn<int>(
    'last_read_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    chatId,
    userId,
    joinedSeq,
    lastReadSeq,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_members';
  @override
  VerificationContext validateIntegrity(
    Insertable<MemberRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('chat_id')) {
      context.handle(
        _chatIdMeta,
        chatId.isAcceptableOrUnknown(data['chat_id']!, _chatIdMeta),
      );
    } else if (isInserting) {
      context.missing(_chatIdMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('joined_seq')) {
      context.handle(
        _joinedSeqMeta,
        joinedSeq.isAcceptableOrUnknown(data['joined_seq']!, _joinedSeqMeta),
      );
    } else if (isInserting) {
      context.missing(_joinedSeqMeta);
    }
    if (data.containsKey('last_read_seq')) {
      context.handle(
        _lastReadSeqMeta,
        lastReadSeq.isAcceptableOrUnknown(
          data['last_read_seq']!,
          _lastReadSeqMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastReadSeqMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {chatId, userId};
  @override
  MemberRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MemberRow(
      chatId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}chat_id'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      joinedSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}joined_seq'],
      )!,
      lastReadSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_read_seq'],
      )!,
    );
  }

  @override
  $LocalMembersTable createAlias(String alias) {
    return $LocalMembersTable(attachedDatabase, alias);
  }
}

class MemberRow extends DataClass implements Insertable<MemberRow> {
  final String chatId;
  final String userId;
  final int joinedSeq;
  final int lastReadSeq;
  const MemberRow({
    required this.chatId,
    required this.userId,
    required this.joinedSeq,
    required this.lastReadSeq,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['chat_id'] = Variable<String>(chatId);
    map['user_id'] = Variable<String>(userId);
    map['joined_seq'] = Variable<int>(joinedSeq);
    map['last_read_seq'] = Variable<int>(lastReadSeq);
    return map;
  }

  LocalMembersCompanion toCompanion(bool nullToAbsent) {
    return LocalMembersCompanion(
      chatId: Value(chatId),
      userId: Value(userId),
      joinedSeq: Value(joinedSeq),
      lastReadSeq: Value(lastReadSeq),
    );
  }

  factory MemberRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MemberRow(
      chatId: serializer.fromJson<String>(json['chatId']),
      userId: serializer.fromJson<String>(json['userId']),
      joinedSeq: serializer.fromJson<int>(json['joinedSeq']),
      lastReadSeq: serializer.fromJson<int>(json['lastReadSeq']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'chatId': serializer.toJson<String>(chatId),
      'userId': serializer.toJson<String>(userId),
      'joinedSeq': serializer.toJson<int>(joinedSeq),
      'lastReadSeq': serializer.toJson<int>(lastReadSeq),
    };
  }

  MemberRow copyWith({
    String? chatId,
    String? userId,
    int? joinedSeq,
    int? lastReadSeq,
  }) => MemberRow(
    chatId: chatId ?? this.chatId,
    userId: userId ?? this.userId,
    joinedSeq: joinedSeq ?? this.joinedSeq,
    lastReadSeq: lastReadSeq ?? this.lastReadSeq,
  );
  MemberRow copyWithCompanion(LocalMembersCompanion data) {
    return MemberRow(
      chatId: data.chatId.present ? data.chatId.value : this.chatId,
      userId: data.userId.present ? data.userId.value : this.userId,
      joinedSeq: data.joinedSeq.present ? data.joinedSeq.value : this.joinedSeq,
      lastReadSeq: data.lastReadSeq.present
          ? data.lastReadSeq.value
          : this.lastReadSeq,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MemberRow(')
          ..write('chatId: $chatId, ')
          ..write('userId: $userId, ')
          ..write('joinedSeq: $joinedSeq, ')
          ..write('lastReadSeq: $lastReadSeq')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(chatId, userId, joinedSeq, lastReadSeq);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MemberRow &&
          other.chatId == this.chatId &&
          other.userId == this.userId &&
          other.joinedSeq == this.joinedSeq &&
          other.lastReadSeq == this.lastReadSeq);
}

class LocalMembersCompanion extends UpdateCompanion<MemberRow> {
  final Value<String> chatId;
  final Value<String> userId;
  final Value<int> joinedSeq;
  final Value<int> lastReadSeq;
  final Value<int> rowid;
  const LocalMembersCompanion({
    this.chatId = const Value.absent(),
    this.userId = const Value.absent(),
    this.joinedSeq = const Value.absent(),
    this.lastReadSeq = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalMembersCompanion.insert({
    required String chatId,
    required String userId,
    required int joinedSeq,
    required int lastReadSeq,
    this.rowid = const Value.absent(),
  }) : chatId = Value(chatId),
       userId = Value(userId),
       joinedSeq = Value(joinedSeq),
       lastReadSeq = Value(lastReadSeq);
  static Insertable<MemberRow> custom({
    Expression<String>? chatId,
    Expression<String>? userId,
    Expression<int>? joinedSeq,
    Expression<int>? lastReadSeq,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (chatId != null) 'chat_id': chatId,
      if (userId != null) 'user_id': userId,
      if (joinedSeq != null) 'joined_seq': joinedSeq,
      if (lastReadSeq != null) 'last_read_seq': lastReadSeq,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalMembersCompanion copyWith({
    Value<String>? chatId,
    Value<String>? userId,
    Value<int>? joinedSeq,
    Value<int>? lastReadSeq,
    Value<int>? rowid,
  }) {
    return LocalMembersCompanion(
      chatId: chatId ?? this.chatId,
      userId: userId ?? this.userId,
      joinedSeq: joinedSeq ?? this.joinedSeq,
      lastReadSeq: lastReadSeq ?? this.lastReadSeq,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (chatId.present) {
      map['chat_id'] = Variable<String>(chatId.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (joinedSeq.present) {
      map['joined_seq'] = Variable<int>(joinedSeq.value);
    }
    if (lastReadSeq.present) {
      map['last_read_seq'] = Variable<int>(lastReadSeq.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalMembersCompanion(')
          ..write('chatId: $chatId, ')
          ..write('userId: $userId, ')
          ..write('joinedSeq: $joinedSeq, ')
          ..write('lastReadSeq: $lastReadSeq, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalMessagesTable extends LocalMessages
    with TableInfo<$LocalMessagesTable, MessageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalMessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
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
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
    'seq',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _senderUserIdMeta = const VerificationMeta(
    'senderUserId',
  );
  @override
  late final GeneratedColumn<String> senderUserId = GeneratedColumn<String>(
    'sender_user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _senderDeviceIdMeta = const VerificationMeta(
    'senderDeviceId',
  );
  @override
  late final GeneratedColumn<String> senderDeviceId = GeneratedColumn<String>(
    'sender_device_id',
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
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'body',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _targetIdMeta = const VerificationMeta(
    'targetId',
  );
  @override
  late final GeneratedColumn<String> targetId = GeneratedColumn<String>(
    'target_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _envelopeMeta = const VerificationMeta(
    'envelope',
  );
  @override
  late final GeneratedColumn<String> envelope = GeneratedColumn<String>(
    'envelope',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
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
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    chatId,
    seq,
    senderUserId,
    senderDeviceId,
    kind,
    body,
    targetId,
    envelope,
    createdAt,
    state,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<MessageRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('chat_id')) {
      context.handle(
        _chatIdMeta,
        chatId.isAcceptableOrUnknown(data['chat_id']!, _chatIdMeta),
      );
    } else if (isInserting) {
      context.missing(_chatIdMeta);
    }
    if (data.containsKey('seq')) {
      context.handle(
        _seqMeta,
        seq.isAcceptableOrUnknown(data['seq']!, _seqMeta),
      );
    }
    if (data.containsKey('sender_user_id')) {
      context.handle(
        _senderUserIdMeta,
        senderUserId.isAcceptableOrUnknown(
          data['sender_user_id']!,
          _senderUserIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_senderUserIdMeta);
    }
    if (data.containsKey('sender_device_id')) {
      context.handle(
        _senderDeviceIdMeta,
        senderDeviceId.isAcceptableOrUnknown(
          data['sender_device_id']!,
          _senderDeviceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_senderDeviceIdMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    }
    if (data.containsKey('target_id')) {
      context.handle(
        _targetIdMeta,
        targetId.isAcceptableOrUnknown(data['target_id']!, _targetIdMeta),
      );
    }
    if (data.containsKey('envelope')) {
      context.handle(
        _envelopeMeta,
        envelope.isAcceptableOrUnknown(data['envelope']!, _envelopeMeta),
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
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MessageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      chatId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}chat_id'],
      )!,
      seq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seq'],
      ),
      senderUserId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_user_id'],
      )!,
      senderDeviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_device_id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body'],
      ),
      targetId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}target_id'],
      ),
      envelope: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}envelope'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
    );
  }

  @override
  $LocalMessagesTable createAlias(String alias) {
    return $LocalMessagesTable(attachedDatabase, alias);
  }
}

class MessageRow extends DataClass implements Insertable<MessageRow> {
  final String id;
  final String chatId;
  final int? seq;
  final String senderUserId;
  final String senderDeviceId;

  /// text | reaction | unknown | undecryptable
  final String kind;

  /// The plaintext JSON (null while undecryptable).
  final String? body;

  /// For reactions: the message reacted to.
  final String? targetId;

  /// The envelope JSON, kept only while the message can't be decrypted yet.
  final String? envelope;
  final int createdAt;

  /// pending | sent | failed
  final String state;
  const MessageRow({
    required this.id,
    required this.chatId,
    this.seq,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.kind,
    this.body,
    this.targetId,
    this.envelope,
    required this.createdAt,
    required this.state,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['chat_id'] = Variable<String>(chatId);
    if (!nullToAbsent || seq != null) {
      map['seq'] = Variable<int>(seq);
    }
    map['sender_user_id'] = Variable<String>(senderUserId);
    map['sender_device_id'] = Variable<String>(senderDeviceId);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || body != null) {
      map['body'] = Variable<String>(body);
    }
    if (!nullToAbsent || targetId != null) {
      map['target_id'] = Variable<String>(targetId);
    }
    if (!nullToAbsent || envelope != null) {
      map['envelope'] = Variable<String>(envelope);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['state'] = Variable<String>(state);
    return map;
  }

  LocalMessagesCompanion toCompanion(bool nullToAbsent) {
    return LocalMessagesCompanion(
      id: Value(id),
      chatId: Value(chatId),
      seq: seq == null && nullToAbsent ? const Value.absent() : Value(seq),
      senderUserId: Value(senderUserId),
      senderDeviceId: Value(senderDeviceId),
      kind: Value(kind),
      body: body == null && nullToAbsent ? const Value.absent() : Value(body),
      targetId: targetId == null && nullToAbsent
          ? const Value.absent()
          : Value(targetId),
      envelope: envelope == null && nullToAbsent
          ? const Value.absent()
          : Value(envelope),
      createdAt: Value(createdAt),
      state: Value(state),
    );
  }

  factory MessageRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageRow(
      id: serializer.fromJson<String>(json['id']),
      chatId: serializer.fromJson<String>(json['chatId']),
      seq: serializer.fromJson<int?>(json['seq']),
      senderUserId: serializer.fromJson<String>(json['senderUserId']),
      senderDeviceId: serializer.fromJson<String>(json['senderDeviceId']),
      kind: serializer.fromJson<String>(json['kind']),
      body: serializer.fromJson<String?>(json['body']),
      targetId: serializer.fromJson<String?>(json['targetId']),
      envelope: serializer.fromJson<String?>(json['envelope']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      state: serializer.fromJson<String>(json['state']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'chatId': serializer.toJson<String>(chatId),
      'seq': serializer.toJson<int?>(seq),
      'senderUserId': serializer.toJson<String>(senderUserId),
      'senderDeviceId': serializer.toJson<String>(senderDeviceId),
      'kind': serializer.toJson<String>(kind),
      'body': serializer.toJson<String?>(body),
      'targetId': serializer.toJson<String?>(targetId),
      'envelope': serializer.toJson<String?>(envelope),
      'createdAt': serializer.toJson<int>(createdAt),
      'state': serializer.toJson<String>(state),
    };
  }

  MessageRow copyWith({
    String? id,
    String? chatId,
    Value<int?> seq = const Value.absent(),
    String? senderUserId,
    String? senderDeviceId,
    String? kind,
    Value<String?> body = const Value.absent(),
    Value<String?> targetId = const Value.absent(),
    Value<String?> envelope = const Value.absent(),
    int? createdAt,
    String? state,
  }) => MessageRow(
    id: id ?? this.id,
    chatId: chatId ?? this.chatId,
    seq: seq.present ? seq.value : this.seq,
    senderUserId: senderUserId ?? this.senderUserId,
    senderDeviceId: senderDeviceId ?? this.senderDeviceId,
    kind: kind ?? this.kind,
    body: body.present ? body.value : this.body,
    targetId: targetId.present ? targetId.value : this.targetId,
    envelope: envelope.present ? envelope.value : this.envelope,
    createdAt: createdAt ?? this.createdAt,
    state: state ?? this.state,
  );
  MessageRow copyWithCompanion(LocalMessagesCompanion data) {
    return MessageRow(
      id: data.id.present ? data.id.value : this.id,
      chatId: data.chatId.present ? data.chatId.value : this.chatId,
      seq: data.seq.present ? data.seq.value : this.seq,
      senderUserId: data.senderUserId.present
          ? data.senderUserId.value
          : this.senderUserId,
      senderDeviceId: data.senderDeviceId.present
          ? data.senderDeviceId.value
          : this.senderDeviceId,
      kind: data.kind.present ? data.kind.value : this.kind,
      body: data.body.present ? data.body.value : this.body,
      targetId: data.targetId.present ? data.targetId.value : this.targetId,
      envelope: data.envelope.present ? data.envelope.value : this.envelope,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      state: data.state.present ? data.state.value : this.state,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageRow(')
          ..write('id: $id, ')
          ..write('chatId: $chatId, ')
          ..write('seq: $seq, ')
          ..write('senderUserId: $senderUserId, ')
          ..write('senderDeviceId: $senderDeviceId, ')
          ..write('kind: $kind, ')
          ..write('body: $body, ')
          ..write('targetId: $targetId, ')
          ..write('envelope: $envelope, ')
          ..write('createdAt: $createdAt, ')
          ..write('state: $state')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    chatId,
    seq,
    senderUserId,
    senderDeviceId,
    kind,
    body,
    targetId,
    envelope,
    createdAt,
    state,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageRow &&
          other.id == this.id &&
          other.chatId == this.chatId &&
          other.seq == this.seq &&
          other.senderUserId == this.senderUserId &&
          other.senderDeviceId == this.senderDeviceId &&
          other.kind == this.kind &&
          other.body == this.body &&
          other.targetId == this.targetId &&
          other.envelope == this.envelope &&
          other.createdAt == this.createdAt &&
          other.state == this.state);
}

class LocalMessagesCompanion extends UpdateCompanion<MessageRow> {
  final Value<String> id;
  final Value<String> chatId;
  final Value<int?> seq;
  final Value<String> senderUserId;
  final Value<String> senderDeviceId;
  final Value<String> kind;
  final Value<String?> body;
  final Value<String?> targetId;
  final Value<String?> envelope;
  final Value<int> createdAt;
  final Value<String> state;
  final Value<int> rowid;
  const LocalMessagesCompanion({
    this.id = const Value.absent(),
    this.chatId = const Value.absent(),
    this.seq = const Value.absent(),
    this.senderUserId = const Value.absent(),
    this.senderDeviceId = const Value.absent(),
    this.kind = const Value.absent(),
    this.body = const Value.absent(),
    this.targetId = const Value.absent(),
    this.envelope = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.state = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalMessagesCompanion.insert({
    required String id,
    required String chatId,
    this.seq = const Value.absent(),
    required String senderUserId,
    required String senderDeviceId,
    required String kind,
    this.body = const Value.absent(),
    this.targetId = const Value.absent(),
    this.envelope = const Value.absent(),
    required int createdAt,
    required String state,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       chatId = Value(chatId),
       senderUserId = Value(senderUserId),
       senderDeviceId = Value(senderDeviceId),
       kind = Value(kind),
       createdAt = Value(createdAt),
       state = Value(state);
  static Insertable<MessageRow> custom({
    Expression<String>? id,
    Expression<String>? chatId,
    Expression<int>? seq,
    Expression<String>? senderUserId,
    Expression<String>? senderDeviceId,
    Expression<String>? kind,
    Expression<String>? body,
    Expression<String>? targetId,
    Expression<String>? envelope,
    Expression<int>? createdAt,
    Expression<String>? state,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (chatId != null) 'chat_id': chatId,
      if (seq != null) 'seq': seq,
      if (senderUserId != null) 'sender_user_id': senderUserId,
      if (senderDeviceId != null) 'sender_device_id': senderDeviceId,
      if (kind != null) 'kind': kind,
      if (body != null) 'body': body,
      if (targetId != null) 'target_id': targetId,
      if (envelope != null) 'envelope': envelope,
      if (createdAt != null) 'created_at': createdAt,
      if (state != null) 'state': state,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalMessagesCompanion copyWith({
    Value<String>? id,
    Value<String>? chatId,
    Value<int?>? seq,
    Value<String>? senderUserId,
    Value<String>? senderDeviceId,
    Value<String>? kind,
    Value<String?>? body,
    Value<String?>? targetId,
    Value<String?>? envelope,
    Value<int>? createdAt,
    Value<String>? state,
    Value<int>? rowid,
  }) {
    return LocalMessagesCompanion(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      seq: seq ?? this.seq,
      senderUserId: senderUserId ?? this.senderUserId,
      senderDeviceId: senderDeviceId ?? this.senderDeviceId,
      kind: kind ?? this.kind,
      body: body ?? this.body,
      targetId: targetId ?? this.targetId,
      envelope: envelope ?? this.envelope,
      createdAt: createdAt ?? this.createdAt,
      state: state ?? this.state,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (chatId.present) {
      map['chat_id'] = Variable<String>(chatId.value);
    }
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (senderUserId.present) {
      map['sender_user_id'] = Variable<String>(senderUserId.value);
    }
    if (senderDeviceId.present) {
      map['sender_device_id'] = Variable<String>(senderDeviceId.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (targetId.present) {
      map['target_id'] = Variable<String>(targetId.value);
    }
    if (envelope.present) {
      map['envelope'] = Variable<String>(envelope.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalMessagesCompanion(')
          ..write('id: $id, ')
          ..write('chatId: $chatId, ')
          ..write('seq: $seq, ')
          ..write('senderUserId: $senderUserId, ')
          ..write('senderDeviceId: $senderDeviceId, ')
          ..write('kind: $kind, ')
          ..write('body: $body, ')
          ..write('targetId: $targetId, ')
          ..write('envelope: $envelope, ')
          ..write('createdAt: $createdAt, ')
          ..write('state: $state, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalKeysTable extends LocalKeys
    with TableInfo<$LocalKeysTable, KeyRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalKeysTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _chatIdMeta = const VerificationMeta('chatId');
  @override
  late final GeneratedColumn<String> chatId = GeneratedColumn<String>(
    'chat_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _epochMeta = const VerificationMeta('epoch');
  @override
  late final GeneratedColumn<int> epoch = GeneratedColumn<int>(
    'epoch',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<Uint8List> key = GeneratedColumn<Uint8List>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [chatId, epoch, key];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_keys';
  @override
  VerificationContext validateIntegrity(
    Insertable<KeyRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('chat_id')) {
      context.handle(
        _chatIdMeta,
        chatId.isAcceptableOrUnknown(data['chat_id']!, _chatIdMeta),
      );
    } else if (isInserting) {
      context.missing(_chatIdMeta);
    }
    if (data.containsKey('epoch')) {
      context.handle(
        _epochMeta,
        epoch.isAcceptableOrUnknown(data['epoch']!, _epochMeta),
      );
    } else if (isInserting) {
      context.missing(_epochMeta);
    }
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
  Set<GeneratedColumn> get $primaryKey => {chatId, epoch};
  @override
  KeyRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return KeyRow(
      chatId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}chat_id'],
      )!,
      epoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}epoch'],
      )!,
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}key'],
      )!,
    );
  }

  @override
  $LocalKeysTable createAlias(String alias) {
    return $LocalKeysTable(attachedDatabase, alias);
  }
}

class KeyRow extends DataClass implements Insertable<KeyRow> {
  final String chatId;
  final int epoch;
  final Uint8List key;
  const KeyRow({required this.chatId, required this.epoch, required this.key});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['chat_id'] = Variable<String>(chatId);
    map['epoch'] = Variable<int>(epoch);
    map['key'] = Variable<Uint8List>(key);
    return map;
  }

  LocalKeysCompanion toCompanion(bool nullToAbsent) {
    return LocalKeysCompanion(
      chatId: Value(chatId),
      epoch: Value(epoch),
      key: Value(key),
    );
  }

  factory KeyRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return KeyRow(
      chatId: serializer.fromJson<String>(json['chatId']),
      epoch: serializer.fromJson<int>(json['epoch']),
      key: serializer.fromJson<Uint8List>(json['key']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'chatId': serializer.toJson<String>(chatId),
      'epoch': serializer.toJson<int>(epoch),
      'key': serializer.toJson<Uint8List>(key),
    };
  }

  KeyRow copyWith({String? chatId, int? epoch, Uint8List? key}) => KeyRow(
    chatId: chatId ?? this.chatId,
    epoch: epoch ?? this.epoch,
    key: key ?? this.key,
  );
  KeyRow copyWithCompanion(LocalKeysCompanion data) {
    return KeyRow(
      chatId: data.chatId.present ? data.chatId.value : this.chatId,
      epoch: data.epoch.present ? data.epoch.value : this.epoch,
      key: data.key.present ? data.key.value : this.key,
    );
  }

  @override
  String toString() {
    return (StringBuffer('KeyRow(')
          ..write('chatId: $chatId, ')
          ..write('epoch: $epoch, ')
          ..write('key: $key')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(chatId, epoch, $driftBlobEquality.hash(key));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KeyRow &&
          other.chatId == this.chatId &&
          other.epoch == this.epoch &&
          $driftBlobEquality.equals(other.key, this.key));
}

class LocalKeysCompanion extends UpdateCompanion<KeyRow> {
  final Value<String> chatId;
  final Value<int> epoch;
  final Value<Uint8List> key;
  final Value<int> rowid;
  const LocalKeysCompanion({
    this.chatId = const Value.absent(),
    this.epoch = const Value.absent(),
    this.key = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalKeysCompanion.insert({
    required String chatId,
    required int epoch,
    required Uint8List key,
    this.rowid = const Value.absent(),
  }) : chatId = Value(chatId),
       epoch = Value(epoch),
       key = Value(key);
  static Insertable<KeyRow> custom({
    Expression<String>? chatId,
    Expression<int>? epoch,
    Expression<Uint8List>? key,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (chatId != null) 'chat_id': chatId,
      if (epoch != null) 'epoch': epoch,
      if (key != null) 'key': key,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalKeysCompanion copyWith({
    Value<String>? chatId,
    Value<int>? epoch,
    Value<Uint8List>? key,
    Value<int>? rowid,
  }) {
    return LocalKeysCompanion(
      chatId: chatId ?? this.chatId,
      epoch: epoch ?? this.epoch,
      key: key ?? this.key,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (chatId.present) {
      map['chat_id'] = Variable<String>(chatId.value);
    }
    if (epoch.present) {
      map['epoch'] = Variable<int>(epoch.value);
    }
    if (key.present) {
      map['key'] = Variable<Uint8List>(key.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalKeysCompanion(')
          ..write('chatId: $chatId, ')
          ..write('epoch: $epoch, ')
          ..write('key: $key, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalUsersTable extends LocalUsers
    with TableInfo<$LocalUsersTable, UserRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalUsersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isAdminMeta = const VerificationMeta(
    'isAdmin',
  );
  @override
  late final GeneratedColumn<bool> isAdmin = GeneratedColumn<bool>(
    'is_admin',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_admin" IN (0, 1))',
    ),
  );
  static const VerificationMeta _identityPubMeta = const VerificationMeta(
    'identityPub',
  );
  @override
  late final GeneratedColumn<String> identityPub = GeneratedColumn<String>(
    'identity_pub',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _trustedIdentityPubMeta =
      const VerificationMeta('trustedIdentityPub');
  @override
  late final GeneratedColumn<String> trustedIdentityPub =
      GeneratedColumn<String>(
        'trusted_identity_pub',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _knownIdentityPubsMeta = const VerificationMeta(
    'knownIdentityPubs',
  );
  @override
  late final GeneratedColumn<String> knownIdentityPubs =
      GeneratedColumn<String>(
        'known_identity_pubs',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant('[]'),
      );
  static const VerificationMeta _pinnedAdminMeta = const VerificationMeta(
    'pinnedAdmin',
  );
  @override
  late final GeneratedColumn<bool> pinnedAdmin = GeneratedColumn<bool>(
    'pinned_admin',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("pinned_admin" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _deletedMeta = const VerificationMeta(
    'deleted',
  );
  @override
  late final GeneratedColumn<bool> deleted = GeneratedColumn<bool>(
    'deleted',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deleted" IN (0, 1))',
    ),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    isAdmin,
    identityPub,
    trustedIdentityPub,
    knownIdentityPubs,
    pinnedAdmin,
    deleted,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_users';
  @override
  VerificationContext validateIntegrity(
    Insertable<UserRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('is_admin')) {
      context.handle(
        _isAdminMeta,
        isAdmin.isAcceptableOrUnknown(data['is_admin']!, _isAdminMeta),
      );
    } else if (isInserting) {
      context.missing(_isAdminMeta);
    }
    if (data.containsKey('identity_pub')) {
      context.handle(
        _identityPubMeta,
        identityPub.isAcceptableOrUnknown(
          data['identity_pub']!,
          _identityPubMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_identityPubMeta);
    }
    if (data.containsKey('trusted_identity_pub')) {
      context.handle(
        _trustedIdentityPubMeta,
        trustedIdentityPub.isAcceptableOrUnknown(
          data['trusted_identity_pub']!,
          _trustedIdentityPubMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_trustedIdentityPubMeta);
    }
    if (data.containsKey('known_identity_pubs')) {
      context.handle(
        _knownIdentityPubsMeta,
        knownIdentityPubs.isAcceptableOrUnknown(
          data['known_identity_pubs']!,
          _knownIdentityPubsMeta,
        ),
      );
    }
    if (data.containsKey('pinned_admin')) {
      context.handle(
        _pinnedAdminMeta,
        pinnedAdmin.isAcceptableOrUnknown(
          data['pinned_admin']!,
          _pinnedAdminMeta,
        ),
      );
    }
    if (data.containsKey('deleted')) {
      context.handle(
        _deletedMeta,
        deleted.isAcceptableOrUnknown(data['deleted']!, _deletedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  UserRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UserRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      isAdmin: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_admin'],
      )!,
      identityPub: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}identity_pub'],
      )!,
      trustedIdentityPub: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}trusted_identity_pub'],
      )!,
      knownIdentityPubs: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}known_identity_pubs'],
      )!,
      pinnedAdmin: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}pinned_admin'],
      )!,
      deleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deleted'],
      ),
    );
  }

  @override
  $LocalUsersTable createAlias(String alias) {
    return $LocalUsersTable(attachedDatabase, alias);
  }
}

class UserRow extends DataClass implements Insertable<UserRow> {
  final String id;
  final String name;
  final bool isAdmin;

  /// The identity key the server lists now.
  final String identityPub;

  /// The key first seen (or last acknowledged). Differs from [identityPub] after a change.
  final String trustedIdentityPub;

  /// JSON list of every key this device has trusted for the user (first seen and acknowledged),
  /// so devices certified by an earlier key still verify their old messages.
  final String knownIdentityPubs;

  /// This device trusts the user as an admin: pinned when it first saw the family (or from a
  /// pairing handover), or promoted by an admin it trusts (lib/chat/resets.dart). The server's
  /// [isAdmin] alone doesn't make anyone's reset count.
  final bool pinnedAdmin;

  /// The account was deleted (docs/protocol.md "Deleting an account"): kept so old messages and
  /// certificates still resolve, but not offered for new chats. Null means not deleted.
  final bool? deleted;
  const UserRow({
    required this.id,
    required this.name,
    required this.isAdmin,
    required this.identityPub,
    required this.trustedIdentityPub,
    required this.knownIdentityPubs,
    required this.pinnedAdmin,
    this.deleted,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['is_admin'] = Variable<bool>(isAdmin);
    map['identity_pub'] = Variable<String>(identityPub);
    map['trusted_identity_pub'] = Variable<String>(trustedIdentityPub);
    map['known_identity_pubs'] = Variable<String>(knownIdentityPubs);
    map['pinned_admin'] = Variable<bool>(pinnedAdmin);
    if (!nullToAbsent || deleted != null) {
      map['deleted'] = Variable<bool>(deleted);
    }
    return map;
  }

  LocalUsersCompanion toCompanion(bool nullToAbsent) {
    return LocalUsersCompanion(
      id: Value(id),
      name: Value(name),
      isAdmin: Value(isAdmin),
      identityPub: Value(identityPub),
      trustedIdentityPub: Value(trustedIdentityPub),
      knownIdentityPubs: Value(knownIdentityPubs),
      pinnedAdmin: Value(pinnedAdmin),
      deleted: deleted == null && nullToAbsent
          ? const Value.absent()
          : Value(deleted),
    );
  }

  factory UserRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UserRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      isAdmin: serializer.fromJson<bool>(json['isAdmin']),
      identityPub: serializer.fromJson<String>(json['identityPub']),
      trustedIdentityPub: serializer.fromJson<String>(
        json['trustedIdentityPub'],
      ),
      knownIdentityPubs: serializer.fromJson<String>(json['knownIdentityPubs']),
      pinnedAdmin: serializer.fromJson<bool>(json['pinnedAdmin']),
      deleted: serializer.fromJson<bool?>(json['deleted']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'isAdmin': serializer.toJson<bool>(isAdmin),
      'identityPub': serializer.toJson<String>(identityPub),
      'trustedIdentityPub': serializer.toJson<String>(trustedIdentityPub),
      'knownIdentityPubs': serializer.toJson<String>(knownIdentityPubs),
      'pinnedAdmin': serializer.toJson<bool>(pinnedAdmin),
      'deleted': serializer.toJson<bool?>(deleted),
    };
  }

  UserRow copyWith({
    String? id,
    String? name,
    bool? isAdmin,
    String? identityPub,
    String? trustedIdentityPub,
    String? knownIdentityPubs,
    bool? pinnedAdmin,
    Value<bool?> deleted = const Value.absent(),
  }) => UserRow(
    id: id ?? this.id,
    name: name ?? this.name,
    isAdmin: isAdmin ?? this.isAdmin,
    identityPub: identityPub ?? this.identityPub,
    trustedIdentityPub: trustedIdentityPub ?? this.trustedIdentityPub,
    knownIdentityPubs: knownIdentityPubs ?? this.knownIdentityPubs,
    pinnedAdmin: pinnedAdmin ?? this.pinnedAdmin,
    deleted: deleted.present ? deleted.value : this.deleted,
  );
  UserRow copyWithCompanion(LocalUsersCompanion data) {
    return UserRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      isAdmin: data.isAdmin.present ? data.isAdmin.value : this.isAdmin,
      identityPub: data.identityPub.present
          ? data.identityPub.value
          : this.identityPub,
      trustedIdentityPub: data.trustedIdentityPub.present
          ? data.trustedIdentityPub.value
          : this.trustedIdentityPub,
      knownIdentityPubs: data.knownIdentityPubs.present
          ? data.knownIdentityPubs.value
          : this.knownIdentityPubs,
      pinnedAdmin: data.pinnedAdmin.present
          ? data.pinnedAdmin.value
          : this.pinnedAdmin,
      deleted: data.deleted.present ? data.deleted.value : this.deleted,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UserRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('isAdmin: $isAdmin, ')
          ..write('identityPub: $identityPub, ')
          ..write('trustedIdentityPub: $trustedIdentityPub, ')
          ..write('knownIdentityPubs: $knownIdentityPubs, ')
          ..write('pinnedAdmin: $pinnedAdmin, ')
          ..write('deleted: $deleted')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    isAdmin,
    identityPub,
    trustedIdentityPub,
    knownIdentityPubs,
    pinnedAdmin,
    deleted,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UserRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.isAdmin == this.isAdmin &&
          other.identityPub == this.identityPub &&
          other.trustedIdentityPub == this.trustedIdentityPub &&
          other.knownIdentityPubs == this.knownIdentityPubs &&
          other.pinnedAdmin == this.pinnedAdmin &&
          other.deleted == this.deleted);
}

class LocalUsersCompanion extends UpdateCompanion<UserRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<bool> isAdmin;
  final Value<String> identityPub;
  final Value<String> trustedIdentityPub;
  final Value<String> knownIdentityPubs;
  final Value<bool> pinnedAdmin;
  final Value<bool?> deleted;
  final Value<int> rowid;
  const LocalUsersCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.isAdmin = const Value.absent(),
    this.identityPub = const Value.absent(),
    this.trustedIdentityPub = const Value.absent(),
    this.knownIdentityPubs = const Value.absent(),
    this.pinnedAdmin = const Value.absent(),
    this.deleted = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalUsersCompanion.insert({
    required String id,
    required String name,
    required bool isAdmin,
    required String identityPub,
    required String trustedIdentityPub,
    this.knownIdentityPubs = const Value.absent(),
    this.pinnedAdmin = const Value.absent(),
    this.deleted = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       isAdmin = Value(isAdmin),
       identityPub = Value(identityPub),
       trustedIdentityPub = Value(trustedIdentityPub);
  static Insertable<UserRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<bool>? isAdmin,
    Expression<String>? identityPub,
    Expression<String>? trustedIdentityPub,
    Expression<String>? knownIdentityPubs,
    Expression<bool>? pinnedAdmin,
    Expression<bool>? deleted,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (isAdmin != null) 'is_admin': isAdmin,
      if (identityPub != null) 'identity_pub': identityPub,
      if (trustedIdentityPub != null)
        'trusted_identity_pub': trustedIdentityPub,
      if (knownIdentityPubs != null) 'known_identity_pubs': knownIdentityPubs,
      if (pinnedAdmin != null) 'pinned_admin': pinnedAdmin,
      if (deleted != null) 'deleted': deleted,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalUsersCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<bool>? isAdmin,
    Value<String>? identityPub,
    Value<String>? trustedIdentityPub,
    Value<String>? knownIdentityPubs,
    Value<bool>? pinnedAdmin,
    Value<bool?>? deleted,
    Value<int>? rowid,
  }) {
    return LocalUsersCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      isAdmin: isAdmin ?? this.isAdmin,
      identityPub: identityPub ?? this.identityPub,
      trustedIdentityPub: trustedIdentityPub ?? this.trustedIdentityPub,
      knownIdentityPubs: knownIdentityPubs ?? this.knownIdentityPubs,
      pinnedAdmin: pinnedAdmin ?? this.pinnedAdmin,
      deleted: deleted ?? this.deleted,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (isAdmin.present) {
      map['is_admin'] = Variable<bool>(isAdmin.value);
    }
    if (identityPub.present) {
      map['identity_pub'] = Variable<String>(identityPub.value);
    }
    if (trustedIdentityPub.present) {
      map['trusted_identity_pub'] = Variable<String>(trustedIdentityPub.value);
    }
    if (knownIdentityPubs.present) {
      map['known_identity_pubs'] = Variable<String>(knownIdentityPubs.value);
    }
    if (pinnedAdmin.present) {
      map['pinned_admin'] = Variable<bool>(pinnedAdmin.value);
    }
    if (deleted.present) {
      map['deleted'] = Variable<bool>(deleted.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalUsersCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('isAdmin: $isAdmin, ')
          ..write('identityPub: $identityPub, ')
          ..write('trustedIdentityPub: $trustedIdentityPub, ')
          ..write('knownIdentityPubs: $knownIdentityPubs, ')
          ..write('pinnedAdmin: $pinnedAdmin, ')
          ..write('deleted: $deleted, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalDevicesTable extends LocalDevices
    with TableInfo<$LocalDevicesTable, DeviceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalDevicesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _encPubMeta = const VerificationMeta('encPub');
  @override
  late final GeneratedColumn<String> encPub = GeneratedColumn<String>(
    'enc_pub',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _signPubMeta = const VerificationMeta(
    'signPub',
  );
  @override
  late final GeneratedColumn<String> signPub = GeneratedColumn<String>(
    'sign_pub',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _certSigMeta = const VerificationMeta(
    'certSig',
  );
  @override
  late final GeneratedColumn<String> certSig = GeneratedColumn<String>(
    'cert_sig',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _revokedMeta = const VerificationMeta(
    'revoked',
  );
  @override
  late final GeneratedColumn<bool> revoked = GeneratedColumn<bool>(
    'revoked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("revoked" IN (0, 1))',
    ),
  );
  static const VerificationMeta _certValidMeta = const VerificationMeta(
    'certValid',
  );
  @override
  late final GeneratedColumn<bool> certValid = GeneratedColumn<bool>(
    'cert_valid',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("cert_valid" IN (0, 1))',
    ),
  );
  static const VerificationMeta _trustedMeta = const VerificationMeta(
    'trusted',
  );
  @override
  late final GeneratedColumn<bool> trusted = GeneratedColumn<bool>(
    'trusted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("trusted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    userId,
    name,
    encPub,
    signPub,
    certSig,
    revoked,
    certValid,
    trusted,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_devices';
  @override
  VerificationContext validateIntegrity(
    Insertable<DeviceRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('enc_pub')) {
      context.handle(
        _encPubMeta,
        encPub.isAcceptableOrUnknown(data['enc_pub']!, _encPubMeta),
      );
    } else if (isInserting) {
      context.missing(_encPubMeta);
    }
    if (data.containsKey('sign_pub')) {
      context.handle(
        _signPubMeta,
        signPub.isAcceptableOrUnknown(data['sign_pub']!, _signPubMeta),
      );
    } else if (isInserting) {
      context.missing(_signPubMeta);
    }
    if (data.containsKey('cert_sig')) {
      context.handle(
        _certSigMeta,
        certSig.isAcceptableOrUnknown(data['cert_sig']!, _certSigMeta),
      );
    } else if (isInserting) {
      context.missing(_certSigMeta);
    }
    if (data.containsKey('revoked')) {
      context.handle(
        _revokedMeta,
        revoked.isAcceptableOrUnknown(data['revoked']!, _revokedMeta),
      );
    } else if (isInserting) {
      context.missing(_revokedMeta);
    }
    if (data.containsKey('cert_valid')) {
      context.handle(
        _certValidMeta,
        certValid.isAcceptableOrUnknown(data['cert_valid']!, _certValidMeta),
      );
    } else if (isInserting) {
      context.missing(_certValidMeta);
    }
    if (data.containsKey('trusted')) {
      context.handle(
        _trustedMeta,
        trusted.isAcceptableOrUnknown(data['trusted']!, _trustedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DeviceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DeviceRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      encPub: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}enc_pub'],
      )!,
      signPub: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sign_pub'],
      )!,
      certSig: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cert_sig'],
      )!,
      revoked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}revoked'],
      )!,
      certValid: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}cert_valid'],
      )!,
      trusted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}trusted'],
      )!,
    );
  }

  @override
  $LocalDevicesTable createAlias(String alias) {
    return $LocalDevicesTable(attachedDatabase, alias);
  }
}

class DeviceRow extends DataClass implements Insertable<DeviceRow> {
  final String id;
  final String userId;
  final String name;
  final String encPub;
  final String signPub;
  final String certSig;
  final bool revoked;

  /// The cert verifies against the user's current identity key or a key trusted earlier.
  final bool certValid;

  /// The cert verifies against a key this device trusts (not an unacknowledged new one). Only
  /// trusted devices get wraps, count as wrappers, or count as senders.
  final bool trusted;
  const DeviceRow({
    required this.id,
    required this.userId,
    required this.name,
    required this.encPub,
    required this.signPub,
    required this.certSig,
    required this.revoked,
    required this.certValid,
    required this.trusted,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['user_id'] = Variable<String>(userId);
    map['name'] = Variable<String>(name);
    map['enc_pub'] = Variable<String>(encPub);
    map['sign_pub'] = Variable<String>(signPub);
    map['cert_sig'] = Variable<String>(certSig);
    map['revoked'] = Variable<bool>(revoked);
    map['cert_valid'] = Variable<bool>(certValid);
    map['trusted'] = Variable<bool>(trusted);
    return map;
  }

  LocalDevicesCompanion toCompanion(bool nullToAbsent) {
    return LocalDevicesCompanion(
      id: Value(id),
      userId: Value(userId),
      name: Value(name),
      encPub: Value(encPub),
      signPub: Value(signPub),
      certSig: Value(certSig),
      revoked: Value(revoked),
      certValid: Value(certValid),
      trusted: Value(trusted),
    );
  }

  factory DeviceRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DeviceRow(
      id: serializer.fromJson<String>(json['id']),
      userId: serializer.fromJson<String>(json['userId']),
      name: serializer.fromJson<String>(json['name']),
      encPub: serializer.fromJson<String>(json['encPub']),
      signPub: serializer.fromJson<String>(json['signPub']),
      certSig: serializer.fromJson<String>(json['certSig']),
      revoked: serializer.fromJson<bool>(json['revoked']),
      certValid: serializer.fromJson<bool>(json['certValid']),
      trusted: serializer.fromJson<bool>(json['trusted']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'userId': serializer.toJson<String>(userId),
      'name': serializer.toJson<String>(name),
      'encPub': serializer.toJson<String>(encPub),
      'signPub': serializer.toJson<String>(signPub),
      'certSig': serializer.toJson<String>(certSig),
      'revoked': serializer.toJson<bool>(revoked),
      'certValid': serializer.toJson<bool>(certValid),
      'trusted': serializer.toJson<bool>(trusted),
    };
  }

  DeviceRow copyWith({
    String? id,
    String? userId,
    String? name,
    String? encPub,
    String? signPub,
    String? certSig,
    bool? revoked,
    bool? certValid,
    bool? trusted,
  }) => DeviceRow(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    name: name ?? this.name,
    encPub: encPub ?? this.encPub,
    signPub: signPub ?? this.signPub,
    certSig: certSig ?? this.certSig,
    revoked: revoked ?? this.revoked,
    certValid: certValid ?? this.certValid,
    trusted: trusted ?? this.trusted,
  );
  DeviceRow copyWithCompanion(LocalDevicesCompanion data) {
    return DeviceRow(
      id: data.id.present ? data.id.value : this.id,
      userId: data.userId.present ? data.userId.value : this.userId,
      name: data.name.present ? data.name.value : this.name,
      encPub: data.encPub.present ? data.encPub.value : this.encPub,
      signPub: data.signPub.present ? data.signPub.value : this.signPub,
      certSig: data.certSig.present ? data.certSig.value : this.certSig,
      revoked: data.revoked.present ? data.revoked.value : this.revoked,
      certValid: data.certValid.present ? data.certValid.value : this.certValid,
      trusted: data.trusted.present ? data.trusted.value : this.trusted,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DeviceRow(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('name: $name, ')
          ..write('encPub: $encPub, ')
          ..write('signPub: $signPub, ')
          ..write('certSig: $certSig, ')
          ..write('revoked: $revoked, ')
          ..write('certValid: $certValid, ')
          ..write('trusted: $trusted')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    userId,
    name,
    encPub,
    signPub,
    certSig,
    revoked,
    certValid,
    trusted,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DeviceRow &&
          other.id == this.id &&
          other.userId == this.userId &&
          other.name == this.name &&
          other.encPub == this.encPub &&
          other.signPub == this.signPub &&
          other.certSig == this.certSig &&
          other.revoked == this.revoked &&
          other.certValid == this.certValid &&
          other.trusted == this.trusted);
}

class LocalDevicesCompanion extends UpdateCompanion<DeviceRow> {
  final Value<String> id;
  final Value<String> userId;
  final Value<String> name;
  final Value<String> encPub;
  final Value<String> signPub;
  final Value<String> certSig;
  final Value<bool> revoked;
  final Value<bool> certValid;
  final Value<bool> trusted;
  final Value<int> rowid;
  const LocalDevicesCompanion({
    this.id = const Value.absent(),
    this.userId = const Value.absent(),
    this.name = const Value.absent(),
    this.encPub = const Value.absent(),
    this.signPub = const Value.absent(),
    this.certSig = const Value.absent(),
    this.revoked = const Value.absent(),
    this.certValid = const Value.absent(),
    this.trusted = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalDevicesCompanion.insert({
    required String id,
    required String userId,
    required String name,
    required String encPub,
    required String signPub,
    required String certSig,
    required bool revoked,
    required bool certValid,
    this.trusted = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       userId = Value(userId),
       name = Value(name),
       encPub = Value(encPub),
       signPub = Value(signPub),
       certSig = Value(certSig),
       revoked = Value(revoked),
       certValid = Value(certValid);
  static Insertable<DeviceRow> custom({
    Expression<String>? id,
    Expression<String>? userId,
    Expression<String>? name,
    Expression<String>? encPub,
    Expression<String>? signPub,
    Expression<String>? certSig,
    Expression<bool>? revoked,
    Expression<bool>? certValid,
    Expression<bool>? trusted,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (userId != null) 'user_id': userId,
      if (name != null) 'name': name,
      if (encPub != null) 'enc_pub': encPub,
      if (signPub != null) 'sign_pub': signPub,
      if (certSig != null) 'cert_sig': certSig,
      if (revoked != null) 'revoked': revoked,
      if (certValid != null) 'cert_valid': certValid,
      if (trusted != null) 'trusted': trusted,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalDevicesCompanion copyWith({
    Value<String>? id,
    Value<String>? userId,
    Value<String>? name,
    Value<String>? encPub,
    Value<String>? signPub,
    Value<String>? certSig,
    Value<bool>? revoked,
    Value<bool>? certValid,
    Value<bool>? trusted,
    Value<int>? rowid,
  }) {
    return LocalDevicesCompanion(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      name: name ?? this.name,
      encPub: encPub ?? this.encPub,
      signPub: signPub ?? this.signPub,
      certSig: certSig ?? this.certSig,
      revoked: revoked ?? this.revoked,
      certValid: certValid ?? this.certValid,
      trusted: trusted ?? this.trusted,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (encPub.present) {
      map['enc_pub'] = Variable<String>(encPub.value);
    }
    if (signPub.present) {
      map['sign_pub'] = Variable<String>(signPub.value);
    }
    if (certSig.present) {
      map['cert_sig'] = Variable<String>(certSig.value);
    }
    if (revoked.present) {
      map['revoked'] = Variable<bool>(revoked.value);
    }
    if (certValid.present) {
      map['cert_valid'] = Variable<bool>(certValid.value);
    }
    if (trusted.present) {
      map['trusted'] = Variable<bool>(trusted.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalDevicesCompanion(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('name: $name, ')
          ..write('encPub: $encPub, ')
          ..write('signPub: $signPub, ')
          ..write('certSig: $certSig, ')
          ..write('revoked: $revoked, ')
          ..write('certValid: $certValid, ')
          ..write('trusted: $trusted, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalResetsTable extends LocalResets
    with TableInfo<$LocalResetsTable, ResetRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalResetsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _signerUserIdMeta = const VerificationMeta(
    'signerUserId',
  );
  @override
  late final GeneratedColumn<String> signerUserId = GeneratedColumn<String>(
    'signer_user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _signerKindMeta = const VerificationMeta(
    'signerKind',
  );
  @override
  late final GeneratedColumn<String> signerKind = GeneratedColumn<String>(
    'signer_kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
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
  static const VerificationMeta _dismissedChatsMeta = const VerificationMeta(
    'dismissedChats',
  );
  @override
  late final GeneratedColumn<String> dismissedChats = GeneratedColumn<String>(
    'dismissed_chats',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    userId,
    signerUserId,
    signerKind,
    createdAt,
    dismissedChats,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_resets';
  @override
  VerificationContext validateIntegrity(
    Insertable<ResetRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('signer_user_id')) {
      context.handle(
        _signerUserIdMeta,
        signerUserId.isAcceptableOrUnknown(
          data['signer_user_id']!,
          _signerUserIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_signerUserIdMeta);
    }
    if (data.containsKey('signer_kind')) {
      context.handle(
        _signerKindMeta,
        signerKind.isAcceptableOrUnknown(data['signer_kind']!, _signerKindMeta),
      );
    } else if (isInserting) {
      context.missing(_signerKindMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('dismissed_chats')) {
      context.handle(
        _dismissedChatsMeta,
        dismissedChats.isAcceptableOrUnknown(
          data['dismissed_chats']!,
          _dismissedChatsMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ResetRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ResetRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      signerUserId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}signer_user_id'],
      )!,
      signerKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}signer_kind'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      dismissedChats: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}dismissed_chats'],
      )!,
    );
  }

  @override
  $LocalResetsTable createAlias(String alias) {
    return $LocalResetsTable(attachedDatabase, alias);
  }
}

class ResetRow extends DataClass implements Insertable<ResetRow> {
  final String id;
  final String userId;
  final String signerUserId;

  /// `admin` or `recovery`.
  final String signerKind;
  final int createdAt;

  /// JSON list of chat ids where the banner was dismissed.
  final String dismissedChats;
  const ResetRow({
    required this.id,
    required this.userId,
    required this.signerUserId,
    required this.signerKind,
    required this.createdAt,
    required this.dismissedChats,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['user_id'] = Variable<String>(userId);
    map['signer_user_id'] = Variable<String>(signerUserId);
    map['signer_kind'] = Variable<String>(signerKind);
    map['created_at'] = Variable<int>(createdAt);
    map['dismissed_chats'] = Variable<String>(dismissedChats);
    return map;
  }

  LocalResetsCompanion toCompanion(bool nullToAbsent) {
    return LocalResetsCompanion(
      id: Value(id),
      userId: Value(userId),
      signerUserId: Value(signerUserId),
      signerKind: Value(signerKind),
      createdAt: Value(createdAt),
      dismissedChats: Value(dismissedChats),
    );
  }

  factory ResetRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ResetRow(
      id: serializer.fromJson<String>(json['id']),
      userId: serializer.fromJson<String>(json['userId']),
      signerUserId: serializer.fromJson<String>(json['signerUserId']),
      signerKind: serializer.fromJson<String>(json['signerKind']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      dismissedChats: serializer.fromJson<String>(json['dismissedChats']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'userId': serializer.toJson<String>(userId),
      'signerUserId': serializer.toJson<String>(signerUserId),
      'signerKind': serializer.toJson<String>(signerKind),
      'createdAt': serializer.toJson<int>(createdAt),
      'dismissedChats': serializer.toJson<String>(dismissedChats),
    };
  }

  ResetRow copyWith({
    String? id,
    String? userId,
    String? signerUserId,
    String? signerKind,
    int? createdAt,
    String? dismissedChats,
  }) => ResetRow(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    signerUserId: signerUserId ?? this.signerUserId,
    signerKind: signerKind ?? this.signerKind,
    createdAt: createdAt ?? this.createdAt,
    dismissedChats: dismissedChats ?? this.dismissedChats,
  );
  ResetRow copyWithCompanion(LocalResetsCompanion data) {
    return ResetRow(
      id: data.id.present ? data.id.value : this.id,
      userId: data.userId.present ? data.userId.value : this.userId,
      signerUserId: data.signerUserId.present
          ? data.signerUserId.value
          : this.signerUserId,
      signerKind: data.signerKind.present
          ? data.signerKind.value
          : this.signerKind,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      dismissedChats: data.dismissedChats.present
          ? data.dismissedChats.value
          : this.dismissedChats,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ResetRow(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('signerUserId: $signerUserId, ')
          ..write('signerKind: $signerKind, ')
          ..write('createdAt: $createdAt, ')
          ..write('dismissedChats: $dismissedChats')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    userId,
    signerUserId,
    signerKind,
    createdAt,
    dismissedChats,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ResetRow &&
          other.id == this.id &&
          other.userId == this.userId &&
          other.signerUserId == this.signerUserId &&
          other.signerKind == this.signerKind &&
          other.createdAt == this.createdAt &&
          other.dismissedChats == this.dismissedChats);
}

class LocalResetsCompanion extends UpdateCompanion<ResetRow> {
  final Value<String> id;
  final Value<String> userId;
  final Value<String> signerUserId;
  final Value<String> signerKind;
  final Value<int> createdAt;
  final Value<String> dismissedChats;
  final Value<int> rowid;
  const LocalResetsCompanion({
    this.id = const Value.absent(),
    this.userId = const Value.absent(),
    this.signerUserId = const Value.absent(),
    this.signerKind = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.dismissedChats = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalResetsCompanion.insert({
    required String id,
    required String userId,
    required String signerUserId,
    required String signerKind,
    required int createdAt,
    this.dismissedChats = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       userId = Value(userId),
       signerUserId = Value(signerUserId),
       signerKind = Value(signerKind),
       createdAt = Value(createdAt);
  static Insertable<ResetRow> custom({
    Expression<String>? id,
    Expression<String>? userId,
    Expression<String>? signerUserId,
    Expression<String>? signerKind,
    Expression<int>? createdAt,
    Expression<String>? dismissedChats,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (userId != null) 'user_id': userId,
      if (signerUserId != null) 'signer_user_id': signerUserId,
      if (signerKind != null) 'signer_kind': signerKind,
      if (createdAt != null) 'created_at': createdAt,
      if (dismissedChats != null) 'dismissed_chats': dismissedChats,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalResetsCompanion copyWith({
    Value<String>? id,
    Value<String>? userId,
    Value<String>? signerUserId,
    Value<String>? signerKind,
    Value<int>? createdAt,
    Value<String>? dismissedChats,
    Value<int>? rowid,
  }) {
    return LocalResetsCompanion(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      signerUserId: signerUserId ?? this.signerUserId,
      signerKind: signerKind ?? this.signerKind,
      createdAt: createdAt ?? this.createdAt,
      dismissedChats: dismissedChats ?? this.dismissedChats,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (signerUserId.present) {
      map['signer_user_id'] = Variable<String>(signerUserId.value);
    }
    if (signerKind.present) {
      map['signer_kind'] = Variable<String>(signerKind.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (dismissedChats.present) {
      map['dismissed_chats'] = Variable<String>(dismissedChats.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalResetsCompanion(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('signerUserId: $signerUserId, ')
          ..write('signerKind: $signerKind, ')
          ..write('createdAt: $createdAt, ')
          ..write('dismissedChats: $dismissedChats, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MetaTable extends Meta with TableInfo<$MetaTable, MetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MetaTable(this.attachedDatabase, [this._alias]);
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
  static const String $name = 'meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<MetaRow> instance, {
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
  MetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MetaRow(
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
  $MetaTable createAlias(String alias) {
    return $MetaTable(attachedDatabase, alias);
  }
}

class MetaRow extends DataClass implements Insertable<MetaRow> {
  final String key;
  final String value;
  const MetaRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  MetaCompanion toCompanion(bool nullToAbsent) {
    return MetaCompanion(key: Value(key), value: Value(value));
  }

  factory MetaRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MetaRow(
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

  MetaRow copyWith({String? key, String? value}) =>
      MetaRow(key: key ?? this.key, value: value ?? this.value);
  MetaRow copyWithCompanion(MetaCompanion data) {
    return MetaRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MetaRow(')
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
      (other is MetaRow && other.key == this.key && other.value == this.value);
}

class MetaCompanion extends UpdateCompanion<MetaRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const MetaCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MetaCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<MetaRow> custom({
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

  MetaCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return MetaCompanion(
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
    return (StringBuffer('MetaCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$ChatDb extends GeneratedDatabase {
  _$ChatDb(QueryExecutor e) : super(e);
  $ChatDbManager get managers => $ChatDbManager(this);
  late final $LocalChatsTable localChats = $LocalChatsTable(this);
  late final $LocalMembersTable localMembers = $LocalMembersTable(this);
  late final $LocalMessagesTable localMessages = $LocalMessagesTable(this);
  late final $LocalKeysTable localKeys = $LocalKeysTable(this);
  late final $LocalUsersTable localUsers = $LocalUsersTable(this);
  late final $LocalDevicesTable localDevices = $LocalDevicesTable(this);
  late final $LocalResetsTable localResets = $LocalResetsTable(this);
  late final $MetaTable meta = $MetaTable(this);
  late final Index localMessagesChatSeq = Index(
    'local_messages_chat_seq',
    'CREATE INDEX local_messages_chat_seq ON local_messages (chat_id, seq)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    localChats,
    localMembers,
    localMessages,
    localKeys,
    localUsers,
    localDevices,
    localResets,
    meta,
    localMessagesChatSeq,
  ];
}

typedef $$LocalChatsTableCreateCompanionBuilder = LocalChatsCompanion Function({
  required String id,
  required String kind,
  Value<String?> title,
  required String createdBy,
  required int currentEpoch,
  required bool epochReady,
  required int lastSeq,
  Value<int?> lastMessageAt,
  required int createdAt,
  Value<int> myLastReadSeq,
  Value<int> syncedSeq,
  Value<int> rowid,
});
typedef $$LocalChatsTableUpdateCompanionBuilder = LocalChatsCompanion Function({
  Value<String> id,
  Value<String> kind,
  Value<String?> title,
  Value<String> createdBy,
  Value<int> currentEpoch,
  Value<bool> epochReady,
  Value<int> lastSeq,
  Value<int?> lastMessageAt,
  Value<int> createdAt,
  Value<int> myLastReadSeq,
  Value<int> syncedSeq,
  Value<int> rowid,
});

class $$LocalChatsTableFilterComposer
    extends Composer<_$ChatDb, $LocalChatsTable> {
  $$LocalChatsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get createdBy => $composableBuilder(
    column: $table.createdBy,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get currentEpoch => $composableBuilder(
    column: $table.currentEpoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get epochReady => $composableBuilder(
    column: $table.epochReady,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastSeq => $composableBuilder(
    column: $table.lastSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastMessageAt => $composableBuilder(
    column: $table.lastMessageAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get myLastReadSeq => $composableBuilder(
    column: $table.myLastReadSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get syncedSeq => $composableBuilder(
    column: $table.syncedSeq,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalChatsTableOrderingComposer
    extends Composer<_$ChatDb, $LocalChatsTable> {
  $$LocalChatsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get createdBy => $composableBuilder(
    column: $table.createdBy,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get currentEpoch => $composableBuilder(
    column: $table.currentEpoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get epochReady => $composableBuilder(
    column: $table.epochReady,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastSeq => $composableBuilder(
    column: $table.lastSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastMessageAt => $composableBuilder(
    column: $table.lastMessageAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get myLastReadSeq => $composableBuilder(
    column: $table.myLastReadSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get syncedSeq => $composableBuilder(
    column: $table.syncedSeq,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalChatsTableAnnotationComposer
    extends Composer<_$ChatDb, $LocalChatsTable> {
  $$LocalChatsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get createdBy =>
      $composableBuilder(column: $table.createdBy, builder: (column) => column);

  GeneratedColumn<int> get currentEpoch => $composableBuilder(
    column: $table.currentEpoch,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get epochReady => $composableBuilder(
    column: $table.epochReady,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastSeq =>
      $composableBuilder(column: $table.lastSeq, builder: (column) => column);

  GeneratedColumn<int> get lastMessageAt => $composableBuilder(
    column: $table.lastMessageAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get myLastReadSeq => $composableBuilder(
    column: $table.myLastReadSeq,
    builder: (column) => column,
  );

  GeneratedColumn<int> get syncedSeq =>
      $composableBuilder(column: $table.syncedSeq, builder: (column) => column);
}

class $$LocalChatsTableTableManager
    extends
        RootTableManager<
          _$ChatDb,
          $LocalChatsTable,
          ChatRow,
          $$LocalChatsTableFilterComposer,
          $$LocalChatsTableOrderingComposer,
          $$LocalChatsTableAnnotationComposer,
          $$LocalChatsTableCreateCompanionBuilder,
          $$LocalChatsTableUpdateCompanionBuilder,
          (ChatRow, BaseReferences<_$ChatDb, $LocalChatsTable, ChatRow>),
          ChatRow,
          PrefetchHooks Function()
        > {
  $$LocalChatsTableTableManager(_$ChatDb db, $LocalChatsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalChatsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalChatsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalChatsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String?> title = const Value.absent(),
                Value<String> createdBy = const Value.absent(),
                Value<int> currentEpoch = const Value.absent(),
                Value<bool> epochReady = const Value.absent(),
                Value<int> lastSeq = const Value.absent(),
                Value<int?> lastMessageAt = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> myLastReadSeq = const Value.absent(),
                Value<int> syncedSeq = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalChatsCompanion(
                id: id,
                kind: kind,
                title: title,
                createdBy: createdBy,
                currentEpoch: currentEpoch,
                epochReady: epochReady,
                lastSeq: lastSeq,
                lastMessageAt: lastMessageAt,
                createdAt: createdAt,
                myLastReadSeq: myLastReadSeq,
                syncedSeq: syncedSeq,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String kind,
                Value<String?> title = const Value.absent(),
                required String createdBy,
                required int currentEpoch,
                required bool epochReady,
                required int lastSeq,
                Value<int?> lastMessageAt = const Value.absent(),
                required int createdAt,
                Value<int> myLastReadSeq = const Value.absent(),
                Value<int> syncedSeq = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalChatsCompanion.insert(
                id: id,
                kind: kind,
                title: title,
                createdBy: createdBy,
                currentEpoch: currentEpoch,
                epochReady: epochReady,
                lastSeq: lastSeq,
                lastMessageAt: lastMessageAt,
                createdAt: createdAt,
                myLastReadSeq: myLastReadSeq,
                syncedSeq: syncedSeq,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalChatsTable, ChatRow>(table),
                  BaseReferences<_$ChatDb, $LocalChatsTable, ChatRow>(
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

typedef $$LocalChatsTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDb,
      $LocalChatsTable,
      ChatRow,
      $$LocalChatsTableFilterComposer,
      $$LocalChatsTableOrderingComposer,
      $$LocalChatsTableAnnotationComposer,
      $$LocalChatsTableCreateCompanionBuilder,
      $$LocalChatsTableUpdateCompanionBuilder,
      (ChatRow, BaseReferences<_$ChatDb, $LocalChatsTable, ChatRow>),
      ChatRow,
      PrefetchHooks Function()
    >;
typedef $$LocalMembersTableCreateCompanionBuilder =
    LocalMembersCompanion Function({
      required String chatId,
      required String userId,
      required int joinedSeq,
      required int lastReadSeq,
      Value<int> rowid,
    });
typedef $$LocalMembersTableUpdateCompanionBuilder =
    LocalMembersCompanion Function({
      Value<String> chatId,
      Value<String> userId,
      Value<int> joinedSeq,
      Value<int> lastReadSeq,
      Value<int> rowid,
    });

class $$LocalMembersTableFilterComposer
    extends Composer<_$ChatDb, $LocalMembersTable> {
  $$LocalMembersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get chatId => $composableBuilder(
    column: $table.chatId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get joinedSeq => $composableBuilder(
    column: $table.joinedSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastReadSeq => $composableBuilder(
    column: $table.lastReadSeq,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalMembersTableOrderingComposer
    extends Composer<_$ChatDb, $LocalMembersTable> {
  $$LocalMembersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get chatId => $composableBuilder(
    column: $table.chatId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get joinedSeq => $composableBuilder(
    column: $table.joinedSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastReadSeq => $composableBuilder(
    column: $table.lastReadSeq,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalMembersTableAnnotationComposer
    extends Composer<_$ChatDb, $LocalMembersTable> {
  $$LocalMembersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get chatId =>
      $composableBuilder(column: $table.chatId, builder: (column) => column);

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<int> get joinedSeq =>
      $composableBuilder(column: $table.joinedSeq, builder: (column) => column);

  GeneratedColumn<int> get lastReadSeq => $composableBuilder(
    column: $table.lastReadSeq,
    builder: (column) => column,
  );
}

class $$LocalMembersTableTableManager
    extends
        RootTableManager<
          _$ChatDb,
          $LocalMembersTable,
          MemberRow,
          $$LocalMembersTableFilterComposer,
          $$LocalMembersTableOrderingComposer,
          $$LocalMembersTableAnnotationComposer,
          $$LocalMembersTableCreateCompanionBuilder,
          $$LocalMembersTableUpdateCompanionBuilder,
          (MemberRow, BaseReferences<_$ChatDb, $LocalMembersTable, MemberRow>),
          MemberRow,
          PrefetchHooks Function()
        > {
  $$LocalMembersTableTableManager(_$ChatDb db, $LocalMembersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalMembersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalMembersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalMembersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> chatId = const Value.absent(),
                Value<String> userId = const Value.absent(),
                Value<int> joinedSeq = const Value.absent(),
                Value<int> lastReadSeq = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalMembersCompanion(
                chatId: chatId,
                userId: userId,
                joinedSeq: joinedSeq,
                lastReadSeq: lastReadSeq,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String chatId,
                required String userId,
                required int joinedSeq,
                required int lastReadSeq,
                Value<int> rowid = const Value.absent(),
              }) => LocalMembersCompanion.insert(
                chatId: chatId,
                userId: userId,
                joinedSeq: joinedSeq,
                lastReadSeq: lastReadSeq,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalMembersTable, MemberRow>(table),
                  BaseReferences<_$ChatDb, $LocalMembersTable, MemberRow>(
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

typedef $$LocalMembersTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDb,
      $LocalMembersTable,
      MemberRow,
      $$LocalMembersTableFilterComposer,
      $$LocalMembersTableOrderingComposer,
      $$LocalMembersTableAnnotationComposer,
      $$LocalMembersTableCreateCompanionBuilder,
      $$LocalMembersTableUpdateCompanionBuilder,
      (MemberRow, BaseReferences<_$ChatDb, $LocalMembersTable, MemberRow>),
      MemberRow,
      PrefetchHooks Function()
    >;
typedef $$LocalMessagesTableCreateCompanionBuilder =
    LocalMessagesCompanion Function({
      required String id,
      required String chatId,
      Value<int?> seq,
      required String senderUserId,
      required String senderDeviceId,
      required String kind,
      Value<String?> body,
      Value<String?> targetId,
      Value<String?> envelope,
      required int createdAt,
      required String state,
      Value<int> rowid,
    });
typedef $$LocalMessagesTableUpdateCompanionBuilder =
    LocalMessagesCompanion Function({
      Value<String> id,
      Value<String> chatId,
      Value<int?> seq,
      Value<String> senderUserId,
      Value<String> senderDeviceId,
      Value<String> kind,
      Value<String?> body,
      Value<String?> targetId,
      Value<String?> envelope,
      Value<int> createdAt,
      Value<String> state,
      Value<int> rowid,
    });

class $$LocalMessagesTableFilterComposer
    extends Composer<_$ChatDb, $LocalMessagesTable> {
  $$LocalMessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get chatId => $composableBuilder(
    column: $table.chatId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get senderUserId => $composableBuilder(
    column: $table.senderUserId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get senderDeviceId => $composableBuilder(
    column: $table.senderDeviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get targetId => $composableBuilder(
    column: $table.targetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get envelope => $composableBuilder(
    column: $table.envelope,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalMessagesTableOrderingComposer
    extends Composer<_$ChatDb, $LocalMessagesTable> {
  $$LocalMessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get chatId => $composableBuilder(
    column: $table.chatId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get senderUserId => $composableBuilder(
    column: $table.senderUserId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get senderDeviceId => $composableBuilder(
    column: $table.senderDeviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get targetId => $composableBuilder(
    column: $table.targetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get envelope => $composableBuilder(
    column: $table.envelope,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalMessagesTableAnnotationComposer
    extends Composer<_$ChatDb, $LocalMessagesTable> {
  $$LocalMessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get chatId =>
      $composableBuilder(column: $table.chatId, builder: (column) => column);

  GeneratedColumn<int> get seq =>
      $composableBuilder(column: $table.seq, builder: (column) => column);

  GeneratedColumn<String> get senderUserId => $composableBuilder(
    column: $table.senderUserId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get senderDeviceId => $composableBuilder(
    column: $table.senderDeviceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get targetId =>
      $composableBuilder(column: $table.targetId, builder: (column) => column);

  GeneratedColumn<String> get envelope =>
      $composableBuilder(column: $table.envelope, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);
}

class $$LocalMessagesTableTableManager
    extends
        RootTableManager<
          _$ChatDb,
          $LocalMessagesTable,
          MessageRow,
          $$LocalMessagesTableFilterComposer,
          $$LocalMessagesTableOrderingComposer,
          $$LocalMessagesTableAnnotationComposer,
          $$LocalMessagesTableCreateCompanionBuilder,
          $$LocalMessagesTableUpdateCompanionBuilder,
          (
            MessageRow,
            BaseReferences<_$ChatDb, $LocalMessagesTable, MessageRow>,
          ),
          MessageRow,
          PrefetchHooks Function()
        > {
  $$LocalMessagesTableTableManager(_$ChatDb db, $LocalMessagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalMessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> chatId = const Value.absent(),
                Value<int?> seq = const Value.absent(),
                Value<String> senderUserId = const Value.absent(),
                Value<String> senderDeviceId = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String?> body = const Value.absent(),
                Value<String?> targetId = const Value.absent(),
                Value<String?> envelope = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalMessagesCompanion(
                id: id,
                chatId: chatId,
                seq: seq,
                senderUserId: senderUserId,
                senderDeviceId: senderDeviceId,
                kind: kind,
                body: body,
                targetId: targetId,
                envelope: envelope,
                createdAt: createdAt,
                state: state,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String chatId,
                Value<int?> seq = const Value.absent(),
                required String senderUserId,
                required String senderDeviceId,
                required String kind,
                Value<String?> body = const Value.absent(),
                Value<String?> targetId = const Value.absent(),
                Value<String?> envelope = const Value.absent(),
                required int createdAt,
                required String state,
                Value<int> rowid = const Value.absent(),
              }) => LocalMessagesCompanion.insert(
                id: id,
                chatId: chatId,
                seq: seq,
                senderUserId: senderUserId,
                senderDeviceId: senderDeviceId,
                kind: kind,
                body: body,
                targetId: targetId,
                envelope: envelope,
                createdAt: createdAt,
                state: state,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalMessagesTable, MessageRow>(table),
                  BaseReferences<_$ChatDb, $LocalMessagesTable, MessageRow>(
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

typedef $$LocalMessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDb,
      $LocalMessagesTable,
      MessageRow,
      $$LocalMessagesTableFilterComposer,
      $$LocalMessagesTableOrderingComposer,
      $$LocalMessagesTableAnnotationComposer,
      $$LocalMessagesTableCreateCompanionBuilder,
      $$LocalMessagesTableUpdateCompanionBuilder,
      (MessageRow, BaseReferences<_$ChatDb, $LocalMessagesTable, MessageRow>),
      MessageRow,
      PrefetchHooks Function()
    >;
typedef $$LocalKeysTableCreateCompanionBuilder = LocalKeysCompanion Function({
  required String chatId,
  required int epoch,
  required Uint8List key,
  Value<int> rowid,
});
typedef $$LocalKeysTableUpdateCompanionBuilder = LocalKeysCompanion Function({
  Value<String> chatId,
  Value<int> epoch,
  Value<Uint8List> key,
  Value<int> rowid,
});

class $$LocalKeysTableFilterComposer
    extends Composer<_$ChatDb, $LocalKeysTable> {
  $$LocalKeysTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get chatId => $composableBuilder(
    column: $table.chatId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalKeysTableOrderingComposer
    extends Composer<_$ChatDb, $LocalKeysTable> {
  $$LocalKeysTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get chatId => $composableBuilder(
    column: $table.chatId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalKeysTableAnnotationComposer
    extends Composer<_$ChatDb, $LocalKeysTable> {
  $$LocalKeysTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get chatId =>
      $composableBuilder(column: $table.chatId, builder: (column) => column);

  GeneratedColumn<int> get epoch =>
      $composableBuilder(column: $table.epoch, builder: (column) => column);

  GeneratedColumn<Uint8List> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);
}

class $$LocalKeysTableTableManager
    extends
        RootTableManager<
          _$ChatDb,
          $LocalKeysTable,
          KeyRow,
          $$LocalKeysTableFilterComposer,
          $$LocalKeysTableOrderingComposer,
          $$LocalKeysTableAnnotationComposer,
          $$LocalKeysTableCreateCompanionBuilder,
          $$LocalKeysTableUpdateCompanionBuilder,
          (KeyRow, BaseReferences<_$ChatDb, $LocalKeysTable, KeyRow>),
          KeyRow,
          PrefetchHooks Function()
        > {
  $$LocalKeysTableTableManager(_$ChatDb db, $LocalKeysTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalKeysTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalKeysTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalKeysTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> chatId = const Value.absent(),
                Value<int> epoch = const Value.absent(),
                Value<Uint8List> key = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalKeysCompanion(
                chatId: chatId,
                epoch: epoch,
                key: key,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String chatId,
                required int epoch,
                required Uint8List key,
                Value<int> rowid = const Value.absent(),
              }) => LocalKeysCompanion.insert(
                chatId: chatId,
                epoch: epoch,
                key: key,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalKeysTable, KeyRow>(table),
                  BaseReferences<_$ChatDb, $LocalKeysTable, KeyRow>(
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

typedef $$LocalKeysTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDb,
      $LocalKeysTable,
      KeyRow,
      $$LocalKeysTableFilterComposer,
      $$LocalKeysTableOrderingComposer,
      $$LocalKeysTableAnnotationComposer,
      $$LocalKeysTableCreateCompanionBuilder,
      $$LocalKeysTableUpdateCompanionBuilder,
      (KeyRow, BaseReferences<_$ChatDb, $LocalKeysTable, KeyRow>),
      KeyRow,
      PrefetchHooks Function()
    >;
typedef $$LocalUsersTableCreateCompanionBuilder = LocalUsersCompanion Function({
  required String id,
  required String name,
  required bool isAdmin,
  required String identityPub,
  required String trustedIdentityPub,
  Value<String> knownIdentityPubs,
  Value<bool> pinnedAdmin,
  Value<bool?> deleted,
  Value<int> rowid,
});
typedef $$LocalUsersTableUpdateCompanionBuilder = LocalUsersCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<bool> isAdmin,
  Value<String> identityPub,
  Value<String> trustedIdentityPub,
  Value<String> knownIdentityPubs,
  Value<bool> pinnedAdmin,
  Value<bool?> deleted,
  Value<int> rowid,
});

class $$LocalUsersTableFilterComposer
    extends Composer<_$ChatDb, $LocalUsersTable> {
  $$LocalUsersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isAdmin => $composableBuilder(
    column: $table.isAdmin,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get identityPub => $composableBuilder(
    column: $table.identityPub,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get trustedIdentityPub => $composableBuilder(
    column: $table.trustedIdentityPub,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get knownIdentityPubs => $composableBuilder(
    column: $table.knownIdentityPubs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get pinnedAdmin => $composableBuilder(
    column: $table.pinnedAdmin,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalUsersTableOrderingComposer
    extends Composer<_$ChatDb, $LocalUsersTable> {
  $$LocalUsersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isAdmin => $composableBuilder(
    column: $table.isAdmin,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get identityPub => $composableBuilder(
    column: $table.identityPub,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get trustedIdentityPub => $composableBuilder(
    column: $table.trustedIdentityPub,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get knownIdentityPubs => $composableBuilder(
    column: $table.knownIdentityPubs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get pinnedAdmin => $composableBuilder(
    column: $table.pinnedAdmin,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalUsersTableAnnotationComposer
    extends Composer<_$ChatDb, $LocalUsersTable> {
  $$LocalUsersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<bool> get isAdmin =>
      $composableBuilder(column: $table.isAdmin, builder: (column) => column);

  GeneratedColumn<String> get identityPub => $composableBuilder(
    column: $table.identityPub,
    builder: (column) => column,
  );

  GeneratedColumn<String> get trustedIdentityPub => $composableBuilder(
    column: $table.trustedIdentityPub,
    builder: (column) => column,
  );

  GeneratedColumn<String> get knownIdentityPubs => $composableBuilder(
    column: $table.knownIdentityPubs,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get pinnedAdmin => $composableBuilder(
    column: $table.pinnedAdmin,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get deleted =>
      $composableBuilder(column: $table.deleted, builder: (column) => column);
}

class $$LocalUsersTableTableManager
    extends
        RootTableManager<
          _$ChatDb,
          $LocalUsersTable,
          UserRow,
          $$LocalUsersTableFilterComposer,
          $$LocalUsersTableOrderingComposer,
          $$LocalUsersTableAnnotationComposer,
          $$LocalUsersTableCreateCompanionBuilder,
          $$LocalUsersTableUpdateCompanionBuilder,
          (UserRow, BaseReferences<_$ChatDb, $LocalUsersTable, UserRow>),
          UserRow,
          PrefetchHooks Function()
        > {
  $$LocalUsersTableTableManager(_$ChatDb db, $LocalUsersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalUsersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalUsersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalUsersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<bool> isAdmin = const Value.absent(),
                Value<String> identityPub = const Value.absent(),
                Value<String> trustedIdentityPub = const Value.absent(),
                Value<String> knownIdentityPubs = const Value.absent(),
                Value<bool> pinnedAdmin = const Value.absent(),
                Value<bool?> deleted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalUsersCompanion(
                id: id,
                name: name,
                isAdmin: isAdmin,
                identityPub: identityPub,
                trustedIdentityPub: trustedIdentityPub,
                knownIdentityPubs: knownIdentityPubs,
                pinnedAdmin: pinnedAdmin,
                deleted: deleted,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required bool isAdmin,
                required String identityPub,
                required String trustedIdentityPub,
                Value<String> knownIdentityPubs = const Value.absent(),
                Value<bool> pinnedAdmin = const Value.absent(),
                Value<bool?> deleted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalUsersCompanion.insert(
                id: id,
                name: name,
                isAdmin: isAdmin,
                identityPub: identityPub,
                trustedIdentityPub: trustedIdentityPub,
                knownIdentityPubs: knownIdentityPubs,
                pinnedAdmin: pinnedAdmin,
                deleted: deleted,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalUsersTable, UserRow>(table),
                  BaseReferences<_$ChatDb, $LocalUsersTable, UserRow>(
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

typedef $$LocalUsersTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDb,
      $LocalUsersTable,
      UserRow,
      $$LocalUsersTableFilterComposer,
      $$LocalUsersTableOrderingComposer,
      $$LocalUsersTableAnnotationComposer,
      $$LocalUsersTableCreateCompanionBuilder,
      $$LocalUsersTableUpdateCompanionBuilder,
      (UserRow, BaseReferences<_$ChatDb, $LocalUsersTable, UserRow>),
      UserRow,
      PrefetchHooks Function()
    >;
typedef $$LocalDevicesTableCreateCompanionBuilder =
    LocalDevicesCompanion Function({
      required String id,
      required String userId,
      required String name,
      required String encPub,
      required String signPub,
      required String certSig,
      required bool revoked,
      required bool certValid,
      Value<bool> trusted,
      Value<int> rowid,
    });
typedef $$LocalDevicesTableUpdateCompanionBuilder =
    LocalDevicesCompanion Function({
      Value<String> id,
      Value<String> userId,
      Value<String> name,
      Value<String> encPub,
      Value<String> signPub,
      Value<String> certSig,
      Value<bool> revoked,
      Value<bool> certValid,
      Value<bool> trusted,
      Value<int> rowid,
    });

class $$LocalDevicesTableFilterComposer
    extends Composer<_$ChatDb, $LocalDevicesTable> {
  $$LocalDevicesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get encPub => $composableBuilder(
    column: $table.encPub,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get signPub => $composableBuilder(
    column: $table.signPub,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get certSig => $composableBuilder(
    column: $table.certSig,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get revoked => $composableBuilder(
    column: $table.revoked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get certValid => $composableBuilder(
    column: $table.certValid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get trusted => $composableBuilder(
    column: $table.trusted,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalDevicesTableOrderingComposer
    extends Composer<_$ChatDb, $LocalDevicesTable> {
  $$LocalDevicesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get encPub => $composableBuilder(
    column: $table.encPub,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get signPub => $composableBuilder(
    column: $table.signPub,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get certSig => $composableBuilder(
    column: $table.certSig,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get revoked => $composableBuilder(
    column: $table.revoked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get certValid => $composableBuilder(
    column: $table.certValid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get trusted => $composableBuilder(
    column: $table.trusted,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalDevicesTableAnnotationComposer
    extends Composer<_$ChatDb, $LocalDevicesTable> {
  $$LocalDevicesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get encPub =>
      $composableBuilder(column: $table.encPub, builder: (column) => column);

  GeneratedColumn<String> get signPub =>
      $composableBuilder(column: $table.signPub, builder: (column) => column);

  GeneratedColumn<String> get certSig =>
      $composableBuilder(column: $table.certSig, builder: (column) => column);

  GeneratedColumn<bool> get revoked =>
      $composableBuilder(column: $table.revoked, builder: (column) => column);

  GeneratedColumn<bool> get certValid =>
      $composableBuilder(column: $table.certValid, builder: (column) => column);

  GeneratedColumn<bool> get trusted =>
      $composableBuilder(column: $table.trusted, builder: (column) => column);
}

class $$LocalDevicesTableTableManager
    extends
        RootTableManager<
          _$ChatDb,
          $LocalDevicesTable,
          DeviceRow,
          $$LocalDevicesTableFilterComposer,
          $$LocalDevicesTableOrderingComposer,
          $$LocalDevicesTableAnnotationComposer,
          $$LocalDevicesTableCreateCompanionBuilder,
          $$LocalDevicesTableUpdateCompanionBuilder,
          (DeviceRow, BaseReferences<_$ChatDb, $LocalDevicesTable, DeviceRow>),
          DeviceRow,
          PrefetchHooks Function()
        > {
  $$LocalDevicesTableTableManager(_$ChatDb db, $LocalDevicesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalDevicesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalDevicesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalDevicesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> userId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> encPub = const Value.absent(),
                Value<String> signPub = const Value.absent(),
                Value<String> certSig = const Value.absent(),
                Value<bool> revoked = const Value.absent(),
                Value<bool> certValid = const Value.absent(),
                Value<bool> trusted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalDevicesCompanion(
                id: id,
                userId: userId,
                name: name,
                encPub: encPub,
                signPub: signPub,
                certSig: certSig,
                revoked: revoked,
                certValid: certValid,
                trusted: trusted,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String userId,
                required String name,
                required String encPub,
                required String signPub,
                required String certSig,
                required bool revoked,
                required bool certValid,
                Value<bool> trusted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalDevicesCompanion.insert(
                id: id,
                userId: userId,
                name: name,
                encPub: encPub,
                signPub: signPub,
                certSig: certSig,
                revoked: revoked,
                certValid: certValid,
                trusted: trusted,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalDevicesTable, DeviceRow>(table),
                  BaseReferences<_$ChatDb, $LocalDevicesTable, DeviceRow>(
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

typedef $$LocalDevicesTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDb,
      $LocalDevicesTable,
      DeviceRow,
      $$LocalDevicesTableFilterComposer,
      $$LocalDevicesTableOrderingComposer,
      $$LocalDevicesTableAnnotationComposer,
      $$LocalDevicesTableCreateCompanionBuilder,
      $$LocalDevicesTableUpdateCompanionBuilder,
      (DeviceRow, BaseReferences<_$ChatDb, $LocalDevicesTable, DeviceRow>),
      DeviceRow,
      PrefetchHooks Function()
    >;
typedef $$LocalResetsTableCreateCompanionBuilder =
    LocalResetsCompanion Function({
      required String id,
      required String userId,
      required String signerUserId,
      required String signerKind,
      required int createdAt,
      Value<String> dismissedChats,
      Value<int> rowid,
    });
typedef $$LocalResetsTableUpdateCompanionBuilder =
    LocalResetsCompanion Function({
      Value<String> id,
      Value<String> userId,
      Value<String> signerUserId,
      Value<String> signerKind,
      Value<int> createdAt,
      Value<String> dismissedChats,
      Value<int> rowid,
    });

class $$LocalResetsTableFilterComposer
    extends Composer<_$ChatDb, $LocalResetsTable> {
  $$LocalResetsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get signerUserId => $composableBuilder(
    column: $table.signerUserId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get signerKind => $composableBuilder(
    column: $table.signerKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dismissedChats => $composableBuilder(
    column: $table.dismissedChats,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalResetsTableOrderingComposer
    extends Composer<_$ChatDb, $LocalResetsTable> {
  $$LocalResetsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get signerUserId => $composableBuilder(
    column: $table.signerUserId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get signerKind => $composableBuilder(
    column: $table.signerKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dismissedChats => $composableBuilder(
    column: $table.dismissedChats,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalResetsTableAnnotationComposer
    extends Composer<_$ChatDb, $LocalResetsTable> {
  $$LocalResetsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get signerUserId => $composableBuilder(
    column: $table.signerUserId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get signerKind => $composableBuilder(
    column: $table.signerKind,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get dismissedChats => $composableBuilder(
    column: $table.dismissedChats,
    builder: (column) => column,
  );
}

class $$LocalResetsTableTableManager
    extends
        RootTableManager<
          _$ChatDb,
          $LocalResetsTable,
          ResetRow,
          $$LocalResetsTableFilterComposer,
          $$LocalResetsTableOrderingComposer,
          $$LocalResetsTableAnnotationComposer,
          $$LocalResetsTableCreateCompanionBuilder,
          $$LocalResetsTableUpdateCompanionBuilder,
          (ResetRow, BaseReferences<_$ChatDb, $LocalResetsTable, ResetRow>),
          ResetRow,
          PrefetchHooks Function()
        > {
  $$LocalResetsTableTableManager(_$ChatDb db, $LocalResetsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalResetsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalResetsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalResetsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> userId = const Value.absent(),
                Value<String> signerUserId = const Value.absent(),
                Value<String> signerKind = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<String> dismissedChats = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalResetsCompanion(
                id: id,
                userId: userId,
                signerUserId: signerUserId,
                signerKind: signerKind,
                createdAt: createdAt,
                dismissedChats: dismissedChats,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String userId,
                required String signerUserId,
                required String signerKind,
                required int createdAt,
                Value<String> dismissedChats = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalResetsCompanion.insert(
                id: id,
                userId: userId,
                signerUserId: signerUserId,
                signerKind: signerKind,
                createdAt: createdAt,
                dismissedChats: dismissedChats,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalResetsTable, ResetRow>(table),
                  BaseReferences<_$ChatDb, $LocalResetsTable, ResetRow>(
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

typedef $$LocalResetsTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDb,
      $LocalResetsTable,
      ResetRow,
      $$LocalResetsTableFilterComposer,
      $$LocalResetsTableOrderingComposer,
      $$LocalResetsTableAnnotationComposer,
      $$LocalResetsTableCreateCompanionBuilder,
      $$LocalResetsTableUpdateCompanionBuilder,
      (ResetRow, BaseReferences<_$ChatDb, $LocalResetsTable, ResetRow>),
      ResetRow,
      PrefetchHooks Function()
    >;
typedef $$MetaTableCreateCompanionBuilder = MetaCompanion Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$MetaTableUpdateCompanionBuilder = MetaCompanion Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$MetaTableFilterComposer extends Composer<_$ChatDb, $MetaTable> {
  $$MetaTableFilterComposer({
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

class $$MetaTableOrderingComposer extends Composer<_$ChatDb, $MetaTable> {
  $$MetaTableOrderingComposer({
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

class $$MetaTableAnnotationComposer extends Composer<_$ChatDb, $MetaTable> {
  $$MetaTableAnnotationComposer({
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

class $$MetaTableTableManager
    extends
        RootTableManager<
          _$ChatDb,
          $MetaTable,
          MetaRow,
          $$MetaTableFilterComposer,
          $$MetaTableOrderingComposer,
          $$MetaTableAnnotationComposer,
          $$MetaTableCreateCompanionBuilder,
          $$MetaTableUpdateCompanionBuilder,
          (MetaRow, BaseReferences<_$ChatDb, $MetaTable, MetaRow>),
          MetaRow,
          PrefetchHooks Function()
        > {
  $$MetaTableTableManager(_$ChatDb db, $MetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => MetaCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) => MetaCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MetaTable, MetaRow>(table),
                  BaseReferences<_$ChatDb, $MetaTable, MetaRow>(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MetaTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDb,
      $MetaTable,
      MetaRow,
      $$MetaTableFilterComposer,
      $$MetaTableOrderingComposer,
      $$MetaTableAnnotationComposer,
      $$MetaTableCreateCompanionBuilder,
      $$MetaTableUpdateCompanionBuilder,
      (MetaRow, BaseReferences<_$ChatDb, $MetaTable, MetaRow>),
      MetaRow,
      PrefetchHooks Function()
    >;

class $ChatDbManager {
  final _$ChatDb _db;
  $ChatDbManager(this._db);
  $$LocalChatsTableTableManager get localChats =>
      $$LocalChatsTableTableManager(_db, _db.localChats);
  $$LocalMembersTableTableManager get localMembers =>
      $$LocalMembersTableTableManager(_db, _db.localMembers);
  $$LocalMessagesTableTableManager get localMessages =>
      $$LocalMessagesTableTableManager(_db, _db.localMessages);
  $$LocalKeysTableTableManager get localKeys =>
      $$LocalKeysTableTableManager(_db, _db.localKeys);
  $$LocalUsersTableTableManager get localUsers =>
      $$LocalUsersTableTableManager(_db, _db.localUsers);
  $$LocalDevicesTableTableManager get localDevices =>
      $$LocalDevicesTableTableManager(_db, _db.localDevices);
  $$LocalResetsTableTableManager get localResets =>
      $$LocalResetsTableTableManager(_db, _db.localResets);
  $$MetaTableTableManager get meta => $$MetaTableTableManager(_db, _db.meta);
}
