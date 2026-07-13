enum TaskRecurrence {
  once,
  daily,
  weekly,
}

extension TaskRecurrenceSchedule on TaskRecurrence {
  bool get isRecurring => this != TaskRecurrence.once;

  DateTime nextAfter(DateTime scheduledFor, DateTime now) {
    if (!isRecurring) {
      return scheduledFor;
    }
    final interval = switch (this) {
      TaskRecurrence.daily => const Duration(days: 1),
      TaskRecurrence.weekly => const Duration(days: 7),
      TaskRecurrence.once => Duration.zero,
    };
    var next = scheduledFor.add(interval);
    while (!next.isAfter(now)) {
      next = next.add(interval);
    }
    return next;
  }
}
