import 'package:flutter/material.dart';

Future<DateTime?> showScheduleDateTimePicker(
  BuildContext context, {
  DateTime? initialValue,
  DateTime? now,
}) {
  final effectiveNow = now ?? DateTime.now();
  final fallback = effectiveNow.add(const Duration(minutes: 5));
  final initial =
      initialValue?.isAfter(effectiveNow) == true ? initialValue! : fallback;
  return showDialog<DateTime>(
    context: context,
    builder: (_) => ScheduleDateTimePickerDialog(
      initialValue: initial,
      now: effectiveNow,
    ),
  );
}

class ScheduleDateTimePickerDialog extends StatefulWidget {
  const ScheduleDateTimePickerDialog({
    required this.initialValue,
    required this.now,
    super.key,
  });

  final DateTime initialValue;
  final DateTime now;

  @override
  State<ScheduleDateTimePickerDialog> createState() =>
      _ScheduleDateTimePickerDialogState();
}

class _ScheduleDateTimePickerDialogState
    extends State<ScheduleDateTimePickerDialog> {
  static const _dayCount = 366;
  late final DateTime _firstDay;
  late final FixedExtentScrollController _dateController;
  late final FixedExtentScrollController _hourController;
  late final FixedExtentScrollController _minuteController;
  late int _dayIndex;
  late int _hour;
  late int _minute;

  @override
  void initState() {
    super.initState();
    _firstDay = DateUtils.dateOnly(widget.now);
    _dayIndex = DateUtils.dateOnly(widget.initialValue)
        .difference(_firstDay)
        .inDays
        .clamp(0, _dayCount - 1);
    _hour = widget.initialValue.hour;
    _minute = widget.initialValue.minute;
    _dateController = FixedExtentScrollController(initialItem: _dayIndex);
    _hourController = FixedExtentScrollController(initialItem: _hour);
    _minuteController = FixedExtentScrollController(initialItem: _minute);
  }

  @override
  void dispose() {
    _dateController.dispose();
    _hourController.dispose();
    _minuteController.dispose();
    super.dispose();
  }

  DateTime get _selected {
    final date = _firstDay.add(Duration(days: _dayIndex));
    return DateTime(date.year, date.month, date.day, _hour, _minute);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final valid = selected.isAfter(widget.now);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('开始时间', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(
                _fullDateTimeLabel(selected),
                key: const ValueKey('schedule-picker-summary'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: 190,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      height: 52,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primaryContainer
                            .withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: _PickerWheel(
                            key: const ValueKey('schedule-date-wheel'),
                            controller: _dateController,
                            itemCount: _dayCount,
                            labelBuilder: (index) => _dateLabel(
                              _firstDay.add(Duration(days: index)),
                            ),
                            onChanged: (value) =>
                                setState(() => _dayIndex = value),
                          ),
                        ),
                        Expanded(
                          child: _PickerWheel(
                            key: const ValueKey('schedule-hour-wheel'),
                            controller: _hourController,
                            itemCount: 24,
                            labelBuilder: (value) =>
                                '${value.toString().padLeft(2, '0')} 时',
                            onChanged: (value) => setState(() => _hour = value),
                          ),
                        ),
                        Expanded(
                          child: _PickerWheel(
                            key: const ValueKey('schedule-minute-wheel'),
                            controller: _minuteController,
                            itemCount: 60,
                            labelBuilder: (value) =>
                                '${value.toString().padLeft(2, '0')} 分',
                            onChanged: (value) =>
                                setState(() => _minute = value),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!valid)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '请选择未来时间',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('schedule-picker-confirm'),
                      onPressed: valid
                          ? () => Navigator.of(context).pop(selected)
                          : null,
                      child: const Text('确定'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickerWheel extends StatelessWidget {
  const _PickerWheel({
    required this.controller,
    required this.itemCount,
    required this.labelBuilder,
    required this.onChanged,
    super.key,
  });

  final FixedExtentScrollController controller;
  final int itemCount;
  final String Function(int index) labelBuilder;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListWheelScrollView.useDelegate(
      controller: controller,
      itemExtent: 52,
      diameterRatio: 1.8,
      physics: const FixedExtentScrollPhysics(),
      onSelectedItemChanged: onChanged,
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: itemCount,
        builder: (context, index) {
          return Center(
            child: Text(
              labelBuilder(index),
              maxLines: 1,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          );
        },
      ),
    );
  }
}

String _dateLabel(DateTime value) =>
    '${value.month}月${value.day}日 ${_weekdayLabel(value.weekday)}';

String _fullDateTimeLabel(DateTime value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '${value.year}年${value.month}月${value.day}日 '
      '${_weekdayLabel(value.weekday)} $hour:$minute';
}

String _weekdayLabel(int weekday) =>
    const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][weekday - 1];
