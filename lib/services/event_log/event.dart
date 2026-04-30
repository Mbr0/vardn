enum EventType {
  todoCreated('todo.created'),
  todoUpdated('todo.updated'),
  todoDeleted('todo.deleted'),
  listCreated('list.created'),
  listUpdated('list.updated'),
  listDeleted('list.deleted'),
  tagAdded('todo.tag.added'),
  tagRemoved('todo.tag.removed');

  const EventType(this.wire);
  final String wire;
}

class MutationEvent {
  MutationEvent({
    required this.id,
    required this.type,
    required this.deviceId,
    required this.createdAt,
    required this.entityId,
    required this.payload,
  });

  final String id;
  final EventType type;
  final String deviceId;
  final DateTime createdAt;
  final String entityId;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type.wire,
        'deviceId': deviceId,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'entityId': entityId,
        'payload': payload,
      };
}
