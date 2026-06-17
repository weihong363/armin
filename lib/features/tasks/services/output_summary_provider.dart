import '../../../core/models/task_status.dart';
import '../../agent/parsers/terminal_prompt_parser.dart';
import '../../agent/services/agent_output_cleaner.dart';
import '../../voice/services/device_voice_service.dart';
import 'secret_redactor.dart';

class OutputSummaryRequest {
  const OutputSummaryRequest({
    required this.cleanedOutput,
    required this.status,
    this.taskTitle = '',
    this.promptInputs = const [],
    this.agentCommand = '',
  });

  final String cleanedOutput;
  final TaskStatus status;
  final String taskTitle;
  final List<String> promptInputs;
  final String agentCommand;
}

class OutputSummary {
  const OutputSummary({
    required this.displaySummary,
    required this.speechSummary,
    this.importantLines = const [],
    this.fallbackReason,
  });

  final String displaySummary;
  final String speechSummary;
  final List<String> importantLines;
  final String? fallbackReason;

  OutputSummary copyWith({
    String? displaySummary,
    String? speechSummary,
    List<String>? importantLines,
    String? fallbackReason,
  }) {
    return OutputSummary(
      displaySummary: displaySummary ?? this.displaySummary,
      speechSummary: speechSummary ?? this.speechSummary,
      importantLines: importantLines ?? this.importantLines,
      fallbackReason: fallbackReason ?? this.fallbackReason,
    );
  }
}

abstract class OutputSummaryProvider {
  Future<OutputSummary> summarize(OutputSummaryRequest request);
}

class RuleBasedOutputSummaryProvider implements OutputSummaryProvider {
  const RuleBasedOutputSummaryProvider({
    AgentOutputCleaner cleaner = const AgentOutputCleaner(),
    SecretRedactor redactor = const SecretRedactor(),
    this.maxDisplayLines = 20,
    this.maxDisplayChars = 420,
    this.maxStructuredDisplayLines = 80,
    this.maxStructuredDisplayChars = 3000,
  })  : _cleaner = cleaner,
        _redactor = redactor;

  final AgentOutputCleaner _cleaner;
  final SecretRedactor _redactor;
  final int maxDisplayLines;
  final int maxDisplayChars;
  final int maxStructuredDisplayLines;
  final int maxStructuredDisplayChars;

  @override
  Future<OutputSummary> summarize(OutputSummaryRequest request) async {
    final withoutPromptBlocks = _removeTerminalPromptBlocks(
      request.cleanedOutput,
    );
    final cleaned =
        _redactor.redactInlineSecrets(_cleaner.clean(withoutPromptBlocks));
    final packageSummary = _packageTreeSummary(cleaned);
    if (packageSummary.isNotEmpty) {
      final speech = DeviceVoiceService.cleanSpeechSummary(packageSummary);
      return OutputSummary(
        displaySummary: packageSummary,
        speechSummary: speech,
        importantLines: packageSummary.split('\n'),
      );
    }
    final structuredLines = _structuredLines(cleaned, request);
    if (structuredLines.isNotEmpty) {
      final display = _structuredDisplaySummary(
        cleaned,
        request,
        structuredLines,
      );
      final speech = DeviceVoiceService.cleanSpeechSummary(display);
      return OutputSummary(
        displaySummary: display,
        speechSummary: speech,
        importantLines: structuredLines,
      );
    }
    final bulletLines = _bulletDeliverableLines(cleaned, request);
    if (bulletLines.isNotEmpty) {
      final display = _compactDisplay(bulletLines.take(maxDisplayLines));
      final speech = DeviceVoiceService.cleanSpeechSummary(display);
      return OutputSummary(
        displaySummary: display,
        speechSummary: speech,
        importantLines: bulletLines,
      );
    }
    final importantLines = _importantLines(cleaned, request);
    final display = _compactDisplay(importantLines.take(maxDisplayLines));
    final speech = DeviceVoiceService.cleanSpeechSummary(display);
    return OutputSummary(
      displaySummary: display,
      speechSummary: speech,
      importantLines: importantLines,
    );
  }

  List<String> _bulletDeliverableLines(
    String cleaned,
    OutputSummaryRequest request,
  ) {
    final promptInputs = {
      request.taskTitle,
      ...request.promptInputs,
    }.where((input) => input.trim().isNotEmpty).toList(growable: false);
    final blocks = <List<String>>[];
    var current = <String>[];

    void flush() {
      final useful = current
          .where((line) => line.trim().isNotEmpty)
          .where((line) => !_looksLikePromptEcho(line, promptInputs))
          .where((line) => !_looksLikeLowValueLine(line))
          .where((line) => !_isPureTableDecorator(line))
          .toList(growable: false);
      if (useful.any((line) => _scoreLine(line) >= 20)) {
        blocks.add(useful);
      }
      current = <String>[];
    }

    for (final rawLine in cleaned.split('\n')) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final bulletMatch = RegExp(r'^[▪■●•]\s*(.+)$').firstMatch(trimmed);
      if (bulletMatch != null) {
        flush();
        final content = bulletMatch.group(1)?.trim() ?? '';
        if (_looksLikeBulletToolCall(content)) {
          continue;
        }
        final semantic = _semanticLine(content);
        if (semantic.isNotEmpty) {
          current.add(semantic);
        }
        continue;
      }
      if (current.isEmpty) {
        continue;
      }
      final semantic = _semanticLine(trimmed);
      if (semantic.isNotEmpty && !_looksLikeBulletToolCall(semantic)) {
        current.add(semantic);
      }
    }
    flush();
    if (blocks.isEmpty) {
      return const [];
    }
    return blocks.last;
  }

  bool _looksLikeBulletToolCall(String line) {
    final lower = line.trim().toLowerCase();
    return lower.startsWith('bash(') ||
        lower.startsWith('grep(') ||
        lower.startsWith('glob(') ||
        lower.startsWith('read(') ||
        lower.startsWith('write(') ||
        lower.startsWith('edit(') ||
        lower.startsWith('ls(') ||
        lower.startsWith('cat(') ||
        lower.startsWith('python ') ||
        lower.startsWith('go test ') ||
        lower.startsWith('flutter test ') ||
        lower.startsWith('dart test ');
  }

  bool _isPureTableDecorator(String line) {
    final compact = line.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return true;
    return RegExp(r'^[┌┬┐├┼┤└┴┘─━│]+\$').hasMatch(compact);
  }

  List<String> _importantLines(String cleaned, OutputSummaryRequest request) {
    final withoutPromptBlocks = _removeTerminalPromptBlocks(cleaned);
    final promptInputs = {
      request.taskTitle,
      ...request.promptInputs,
    }.where((input) => input.trim().isNotEmpty).toList(growable: false);
    final lines = _semanticLines(withoutPromptBlocks)
        .where((line) => line.isNotEmpty)
        .where((line) => !_looksLikePromptEcho(line, promptInputs))
        .where((line) => !_looksLikeLowValueLine(line))
        .toList(growable: false);
    final semanticLines = _joinContinuationLines(lines);

    final scored = [
      for (var index = 0; index < semanticLines.length; index++)
        _ScoredLine(
          line: semanticLines[index],
          index: index,
          score: _scoreLine(semanticLines[index]),
        ),
    ];
    final useful = scored.where((item) => item.score >= 20).toList()
      ..sort((a, b) {
        final scoreCompare = b.score.compareTo(a.score);
        return scoreCompare == 0 ? a.index.compareTo(b.index) : scoreCompare;
      });
    final selected = useful.isEmpty
        ? scored.take(maxDisplayLines).toList()
        : useful.take(maxDisplayLines).toList();
    selected.sort((a, b) => a.index.compareTo(b.index));
    return selected.map((item) => item.line).toList(growable: false);
  }

  List<String> _structuredLines(String cleaned, OutputSummaryRequest request) {
    final promptInputs = {
      request.taskTitle,
      ...request.promptInputs,
    }.where((input) => input.trim().isNotEmpty).toList(growable: false);
    final lines = _semanticLines(_removeTerminalPromptBlocks(cleaned))
        .where((line) => line.isNotEmpty)
        .where((line) => !_looksLikePromptEcho(line, promptInputs))
        .where((line) => !_looksLikeLowValueLine(line))
        .toList(growable: false);
    final blocks = <List<String>>[];
    var current = <String>[];
    String? pendingIntro;

    void flush() {
      if (_isUsefulStructuredBlock(current)) {
        blocks.add(List<String>.from(current));
      }
      current = <String>[];
    }

    for (final line in lines) {
      if (_looksLikeTableLine(line) ||
          (current.isNotEmpty && _looksLikeTableContinuation(line))) {
        if (current.isEmpty && pendingIntro != null) {
          current.add(pendingIntro);
        }
        current.add(line);
      } else {
        flush();
        pendingIntro = _looksLikeStructuredIntroLine(line) ? line : null;
      }
    }
    flush();
    if (blocks.isEmpty) {
      return const [];
    }
    blocks.sort((a, b) => _structuredScore(b).compareTo(_structuredScore(a)));
    return blocks.first;
  }

  bool _isUsefulStructuredBlock(List<String> lines) {
    if (lines.length < 3) {
      return false;
    }
    final dataRows = lines.where(_looksLikeTableDataRow).length;
    return dataRows >= 2;
  }

  int _structuredScore(List<String> lines) {
    final dataRows = lines.where(_looksLikeTableDataRow).length;
    final fileRows = lines.where(_looksLikeFileReferenceLine).length;
    return dataRows * 10 + fileRows * 4 + lines.length;
  }

  bool _looksLikeTableLine(String line) {
    return _looksLikeTableDataRow(line) || _looksLikeTableSeparator(line);
  }

  bool _looksLikeTableDataRow(String line) {
    if (!_hasTableDelimiter(line)) {
      return false;
    }
    if (_looksLikeTableSeparator(line)) {
      return false;
    }
    final cells = _tableCells(line);
    return cells.where((cell) => cell.isNotEmpty).length >= 2 &&
        cells.any(_looksLikeStructuredCell);
  }

  bool _looksLikeStructuredCell(String cell) {
    final lower = cell.toLowerCase();
    return lower.contains('.py') ||
        lower.contains('.dart') ||
        lower.contains('.ts') ||
        lower.contains('.json') ||
        lower.contains('test_') ||
        RegExp(r'^[A-Za-z0-9_\-./]+$').hasMatch(cell) ||
        RegExp(r'[\u4e00-\u9fff]').hasMatch(cell);
  }

  bool _looksLikeTableSeparator(String line) {
    final trimmed = line.trim();
    return RegExp(r'^\|?\s*[-:─━_\s|]+\|?\s*$').hasMatch(trimmed) ||
        RegExp(r'^[┌┬┐├┼┤└┴┘─━│\s]+$').hasMatch(trimmed);
  }

  bool _looksLikeTableContinuation(String line) {
    return _looksLikeFileReferenceLine(line) ||
        _looksLikeTableSeparator(line) ||
        _hasTableDelimiter(line);
  }

  bool _looksLikeFileReferenceLine(String line) {
    return RegExp(r'\b[A-Za-z0-9_\-./]*test[A-Za-z0-9_\-./]*\.(?:py|dart|ts)\b')
        .hasMatch(line);
  }

  String _packageTreeSummary(String cleaned) {
    final lines = _semanticLines(_removeTerminalPromptBlocks(cleaned));
    if (!_hasDirectoryTree(lines)) {
      return '';
    }
    final packageName = _packageRootName(lines);
    final output = <String>[];
    if (packageName.isNotEmpty) {
      output.add('Package complete：已创建 $packageName 包结构。');
    } else {
      output.add('Package complete：已创建项目包结构。');
    }
    final widgetSupport = _packageSupportLine(lines);
    if (widgetSupport.isNotEmpty) {
      output.add(widgetSupport);
    }
    final testStatus = _packageTestStatusLine(lines);
    if (testStatus.isNotEmpty) {
      output.add(testStatus);
    }
    final commands = _packageCommandLines(lines);
    if (commands.isNotEmpty) {
      output.add('本地验证：${commands.join('；')}。');
    }
    return _compactDisplay(output);
  }

  bool _hasDirectoryTree(List<String> lines) {
    final treeLines = lines.where(_looksLikeDirectoryTreeLine).length;
    if (treeLines < 4) {
      return false;
    }
    return _packageRootName(lines).isNotEmpty ||
        lines.any((line) =>
            line.toLowerCase().contains('each widget supports') ||
            line.toLowerCase().contains('cannot run tests'));
  }

  bool _looksLikeDirectoryTreeLine(String line) {
    final trimmed = line.trimLeft();
    return trimmed.startsWith('├') ||
        trimmed.startsWith('└') ||
        trimmed.startsWith('│') ||
        RegExp(r'^[A-Za-z0-9_.-]+/$').hasMatch(trimmed);
  }

  String _packageRootName(List<String> lines) {
    for (final line in lines) {
      final trimmed = line.trim();
      if (RegExp(r'^[A-Za-z0-9_.-]+/$').hasMatch(trimmed)) {
        return trimmed.substring(0, trimmed.length - 1);
      }
    }
    return '';
  }

  String _packageSupportLine(List<String> lines) {
    for (final line in lines) {
      final lower = line.toLowerCase();
      if (lower.contains('each widget supports') ||
          lower.startsWith('supports:')) {
        final supports = line
            .replaceFirst(
                RegExp(r'^each widget supports:?\s*', caseSensitive: false), '')
            .replaceFirst(RegExp(r'^supports:?\s*', caseSensitive: false), '')
            .replaceFirst(RegExp(r'\.?$'), '')
            .trim();
        if (supports.isNotEmpty) {
          return '组件支持：$supports。';
        }
      }
    }
    return '';
  }

  String _packageTestStatusLine(List<String> lines) {
    for (final line in lines) {
      final lower = line.toLowerCase();
      if (lower.contains('cannot run tests')) {
        return '测试未运行：当前环境未安装 flutter/dart。';
      }
    }
    return '';
  }

  List<String> _packageCommandLines(List<String> lines) {
    final commands = <String>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed == 'flutter pub get' ||
          trimmed == 'flutter test' ||
          trimmed.contains('flutter run')) {
        _addUnique(commands, trimmed);
      }
    }
    return commands;
  }

  bool _hasTableDelimiter(String line) {
    return line.contains('|') || line.contains('│');
  }

  bool _looksLikeStructuredIntroLine(String line) {
    return line.contains('汇总') ||
        line.contains('如下') ||
        line.contains('表格') ||
        (line.contains('测试') && line.contains('文件'));
  }

  List<String> _tableCells(String line) {
    final cells = line
        .split(RegExp(r'[|│]'))
        .map((cell) => cell.trim())
        .toList(growable: true);
    if (cells.isNotEmpty && cells.first.isEmpty && _startsWithDelimiter(line)) {
      cells.removeAt(0);
    }
    if (cells.isNotEmpty && cells.last.isEmpty && _endsWithDelimiter(line)) {
      cells.removeLast();
    }
    return cells;
  }

  bool _startsWithDelimiter(String line) {
    final trimmed = line.trimLeft();
    return trimmed.startsWith('|') || trimmed.startsWith('│');
  }

  bool _endsWithDelimiter(String line) {
    final trimmed = line.trimRight();
    return trimmed.endsWith('|') || trimmed.endsWith('│');
  }

  String _structuredNaturalSummary(List<String> lines) {
    final intro = lines
        .firstWhere(
          (line) =>
              !_looksLikeTableLine(line) && _looksLikeStructuredIntroLine(line),
          orElse: () => '结构化结果如下',
        )
        .replaceFirst(RegExp(r'[：:，,。.\s]+$'), '');
    final testFiles = _extractTestFiles(lines);
    if (testFiles.isNotEmpty) {
      return '$intro：共 ${testFiles.length} 个测试文件，包括 ${testFiles.join('、')}。';
    }
    final tableRows = _extractTableRows(lines);
    if (tableRows.isNotEmpty) {
      return '$intro：共 ${tableRows.length} 行，分别是：${tableRows.join('；')}。';
    }
    return intro;
  }

  String _structuredDisplaySummary(
    String cleaned,
    OutputSummaryRequest request,
    List<String> structuredLines,
  ) {
    final tableSummary = _structuredNaturalSummary(structuredLines);
    final context = _structuredContext(
      cleaned,
      request,
      structuredLines,
    );
    if (context.before.isEmpty && context.after.isEmpty) {
      return tableSummary;
    }

    return _compactDisplay([
      ...context.before,
      tableSummary,
      ...context.after,
    ].take(maxDisplayLines));
  }

  _StructuredContext _structuredContext(
    String cleaned,
    OutputSummaryRequest request,
    List<String> structuredLines,
  ) {
    final promptInputs = {
      request.taskTitle,
      ...request.promptInputs,
    }.where((input) => input.trim().isNotEmpty).toList(growable: false);
    final lines = _semanticLines(_removeTerminalPromptBlocks(cleaned))
        .where((line) => line.isNotEmpty)
        .where((line) => !_looksLikePromptEcho(line, promptInputs))
        .where((line) => !_looksLikeLowValueLine(line))
        .toList(growable: false);
    final structuredSet = structuredLines.toSet();
    final before = <String>[];
    final after = <String>[];
    var seenStructured = false;
    for (final line in lines) {
      if (structuredSet.contains(line) ||
          _looksLikeTableLine(line) ||
          _looksLikeTableContinuation(line)) {
        seenStructured = true;
        continue;
      }
      if (_looksLikeStructuredIntroLine(line)) {
        seenStructured = true;
        continue;
      }
      if (seenStructured) {
        after.add(line);
      } else {
        if (_scoreLine(line) < 20) {
          continue;
        }
        before.add(line);
      }
    }
    return _StructuredContext(before: before, after: after);
  }

  List<String> _extractTableRows(List<String> lines) {
    final rows = <String>[];
    for (final cells in _logicalTableRows(lines)) {
      final row = _formatLogicalRow(cells);
      if (row.isEmpty) {
        continue;
      }
      if (!rows.contains(row)) {
        rows.add(row);
      }
    }
    return rows;
  }

  List<List<String>> _logicalTableRows(List<String> lines) {
    final rows = <List<String>>[];
    for (final line in lines) {
      if (!_hasTableDelimiter(line) || _looksLikeTableSeparator(line)) {
        continue;
      }
      final cells = _normalizedTableCells(line);
      if (_looksLikeWrappedContinuation(line, cells, rows)) {
        rows[rows.length - 1] = _mergeTableCells(rows.last, cells);
        continue;
      }
      if (cells.where((cell) => cell.isNotEmpty).length < 2 ||
          _looksLikeHeaderCells(cells)) {
        continue;
      }
      rows.add(cells);
    }
    return rows;
  }

  List<String> _normalizedTableCells(String line) {
    return _tableCells(line)
        .map((cell) => cell.replaceAll(RegExp(r'\s+'), ' ').trim())
        .toList(growable: false);
  }

  bool _looksLikeWrappedContinuation(
    String line,
    List<String> cells,
    List<List<String>> rows,
  ) {
    if (!line.contains('│') || rows.isEmpty) {
      return false;
    }
    if (_onlyFirstCellHasValue(cells)) {
      return true;
    }
    if (_firstColumnsAreEmpty(cells, 2) &&
        cells.skip(2).any((cell) => cell.isNotEmpty)) {
      return true;
    }
    if (cells.length < 2) {
      return false;
    }
    if (_singleContinuationCell(cells, rows.last) != null) {
      return true;
    }
    final previous = rows.last;
    final currentSecond = cells.length > 1 ? cells[1] : '';
    final previousSecond = previous.length > 1 ? previous[1] : '';
    if (currentSecond.isEmpty &&
        _looksLikeWrappedFragment(cells.first, previous.first)) {
      return true;
    }
    if (_looksLikeWrappedFragment(currentSecond, previousSecond)) {
      return true;
    }
    if (_looksLikePathCell(previousSecond) &&
        !_startsRootedPath(currentSecond)) {
      return true;
    }
    return _looksLikeInteger(previousSecond) && currentSecond.isEmpty;
  }

  int? _singleContinuationCell(List<String> cells, List<String> previous) {
    final indexes = <int>[
      for (var index = 0; index < cells.length; index++)
        if (cells[index].isNotEmpty) index,
    ];
    if (indexes.length != 1) {
      return null;
    }
    final index = indexes.single;
    if (index == 0) {
      return null;
    }
    final previousValue = index < previous.length ? previous[index] : '';
    return previousValue.isEmpty ? null : index;
  }

  bool _looksLikeWrappedFragment(String current, String previous) {
    if (current.isEmpty || previous.isEmpty) {
      return false;
    }
    if (current.length <= 2 && _startsWithCjk(current)) {
      return true;
    }
    if (_looksLikeSplitOption(previous, current)) {
      return true;
    }
    return false;
  }

  bool _onlyFirstCellHasValue(List<String> cells) {
    if (cells.isEmpty || cells.first.isEmpty) {
      return false;
    }
    return cells.skip(1).every((cell) => cell.isEmpty);
  }

  bool _firstColumnsAreEmpty(List<String> cells, int count) {
    if (cells.length <= count) {
      return false;
    }
    return cells.take(count).every((cell) => cell.isEmpty);
  }

  List<String> _mergeTableCells(List<String> previous, List<String> current) {
    final width =
        previous.length > current.length ? previous.length : current.length;
    return [
      for (var index = 0; index < width; index++)
        _joinCellParts(
          index < previous.length ? previous[index] : '',
          index < current.length ? current[index] : '',
        ),
    ];
  }

  String _joinCellParts(String previous, String current) {
    if (current.isEmpty) {
      return previous;
    }
    if (previous.isEmpty) {
      return current;
    }
    if (previous.endsWith('/') && current.startsWith('-')) {
      return '$previous $current';
    }
    if (_looksLikeSplitOption(previous, current)) {
      return '$previous$current';
    }
    if (previous.endsWith('/') ||
        previous.endsWith('_') ||
        current.startsWith('.') ||
        current == 'py' ||
        current == 'y' ||
        (_looksLikePathCell(previous) &&
            RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(current))) {
      return '$previous$current';
    }
    if (_endsWithCjk(previous) || _startsWithCjk(current)) {
      return '$previous$current';
    }
    return '$previous $current';
  }

  bool _looksLikeSplitOption(String previous, String current) {
    return RegExp(r'^--[A-Za-z][A-Za-z-]*$').hasMatch(previous) &&
        RegExp(r'^[A-Za-z]').hasMatch(current);
  }

  bool _endsWithCjk(String value) {
    return value.isNotEmpty && RegExp(r'[\u4e00-\u9fff]$').hasMatch(value);
  }

  bool _startsWithCjk(String value) {
    return value.isNotEmpty && RegExp(r'^[\u4e00-\u9fff]').hasMatch(value);
  }

  String _formatLogicalRow(List<String> cells) {
    final values =
        cells.where((cell) => cell.isNotEmpty).toList(growable: false);
    if (values.length < 2) {
      return '';
    }
    if (cells.length >= 3 && _looksLikePathCell(cells[1])) {
      final name = cells.first.trim();
      final path = cells[1].trim();
      final details = cells.skip(2).where((cell) => cell.isNotEmpty).join('，');
      return details.isEmpty ? '$name：$path' : '$name：$path，$details';
    }
    return values.join('，');
  }

  bool _looksLikePathCell(String value) {
    return value.startsWith('app/') ||
        value.startsWith('lib/') ||
        value.startsWith('test/') ||
        value.startsWith('/') ||
        value.contains('/');
  }

  bool _startsRootedPath(String value) {
    return value.startsWith('app/') ||
        value.startsWith('lib/') ||
        value.startsWith('test/') ||
        value.startsWith('/');
  }

  bool _looksLikeInteger(String value) {
    return RegExp(r'^\d+$').hasMatch(value.trim());
  }

  bool _looksLikeHeaderCells(List<String> cells) {
    final normalized = cells
        .where((cell) => cell.isNotEmpty)
        .map((cell) => cell.toLowerCase())
        .toList(growable: false);
    if (normalized.isEmpty) {
      return false;
    }
    const headerWords = {
      '模块',
      '文件',
      '测试文件',
      '功能分类',
      '功能名称',
      '路径',
      '状态',
      '说明',
      '参数/用法',
      '用例',
      '覆盖模块',
      '核心职责',
      '职责',
      '函数',
      'name',
      'status',
    };
    return normalized.every(headerWords.contains);
  }

  List<String> _extractTestFiles(List<String> lines) {
    final files = <String>[];
    String? pendingFragment;
    for (final cells in _logicalTableRows(lines)) {
      if (cells.isEmpty) {
        continue;
      }
      final firstCell = cells.first.replaceAll(RegExp(r'\s+'), '');
      if (firstCell.isEmpty) {
        continue;
      }
      final wholeLineMatch = _testFilePattern.firstMatch(
        cells.join(' ').replaceAll(RegExp(r'\s+'), ''),
      );
      if (wholeLineMatch != null) {
        _addUnique(files, wholeLineMatch.group(0)!);
        pendingFragment = null;
        continue;
      }
      if (pendingFragment != null) {
        final candidate = '$pendingFragment$firstCell';
        final match = _testFilePattern.firstMatch(candidate);
        if (match != null) {
          _addUnique(files, match.group(0)!);
          pendingFragment = null;
        } else {
          pendingFragment = candidate;
        }
      } else if (firstCell.startsWith('test_')) {
        pendingFragment = firstCell;
      }
    }
    return files;
  }

  void _addUnique(List<String> values, String value) {
    if (!values.contains(value)) {
      values.add(value);
    }
  }

  static final RegExp _testFilePattern =
      RegExp(r'test[A-Za-z0-9_]*\.(?:py|dart|ts)');

  String _removeTerminalPromptBlocks(String cleaned) {
    return const TerminalPromptParser().stripPromptBlocks(cleaned);
  }

  List<String> _semanticLines(String cleaned) {
    return cleaned
        .replaceAll('\r', '\n')
        .split('\n')
        .map(_semanticLine)
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

  String _semanticLine(String line) {
    var value = line.trim();
    if (value.isEmpty) {
      return '';
    }
    value = value
        .replaceFirst(RegExp(r'^[>›]\s*'), '')
        .replaceAll(RegExp(r"Glob\('[^']*'\)"), ' ')
        .replaceAll(RegExp(r"Grep\('[^']*'[^)]*\)", caseSensitive: false), ' ')
        .replaceAll(RegExp(r'Read\([^)]*\)'), ' ')
        .replaceAll(
          RegExp(r'^completion:\s*tls handshake eof\b.*', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'\bType your message or @path/to/file\b.*',
              caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\bAuto Model\b.*', caseSensitive: false), '')
        .replaceAll(
          RegExp(r'\bShift\+Tab to Auto-accept Edits\b.*',
              caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\bAGENTS\.md file\b.*', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bThinking\b[.…]*', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'[▪■●•]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (_hasTableDelimiter(value)) {
      return value;
    }
    value = _dropToolTracePrefix(value);
    value = _stripPromptNoisePrefix(value);
    return _normalizePetDescription(value);
  }

  String _stripPromptNoisePrefix(String line) {
    var value = line.trimLeft();
    var previous = '';
    while (value.isNotEmpty && value != previous) {
      previous = value;
      for (final pattern in _promptNoisePrefixPatterns) {
        final match = pattern.firstMatch(value);
        if (match != null) {
          value = value.substring(match.end).trimLeft();
          break;
        }
      }
    }
    return value.trim();
  }

  static final List<RegExp> _promptNoisePrefixPatterns = [
    RegExp(
      r'^(?:最小改动|不要提交\s*git|不要提交git|不要提交\s+Git|高风险操作先确认)[\s:：,，。．.\-]*',
      caseSensitive: false,
    ),
    RegExp(
      r'^(?:user constraints|## user constraints|## user task|## context chunk|## secret placeholders)[\s:：,，。．.\-]*',
      caseSensitive: false,
    ),
    RegExp(
      r'^(?:do not analyze unrelated architecture\.?|run only targeted tests\.?|keep command output short\.?)[\s:：,，。．.\-]*',
      caseSensitive: false,
    ),
    RegExp(
      r'^(?:turn \d+|result: turn \d+|结果为：turn \d+)[\s:：,，。．.\-]*',
      caseSensitive: false,
    ),
  ];

  String _dropToolTracePrefix(String line) {
    final natural = RegExp(
      r'([A-Za-z][A-Za-z0-9_-]*\s*[是:：].*)',
      caseSensitive: false,
    ).firstMatch(line);
    if (natural != null) {
      return natural.group(1)!.trim();
    }
    return line;
  }

  String _normalizePetDescription(String line) {
    final petMatch =
        RegExp(r'^([A-Za-z][A-Za-z0-9_-]*)\s+是\s+一\s+只\s+').firstMatch(line);
    if (petMatch == null) {
      return line;
    }
    final name = _titleCaseAsciiName(petMatch.group(1)!);
    return line.replaceFirst(petMatch.group(0)!, '$name是一只');
  }

  String _titleCaseAsciiName(String name) {
    if (name.isEmpty || name != name.toUpperCase()) {
      return name;
    }
    return name[0] + name.substring(1).toLowerCase();
  }

  List<String> _joinContinuationLines(List<String> lines) {
    final result = <String>[];
    for (final line in lines) {
      if (result.isNotEmpty && _looksLikeContinuation(line)) {
        result[result.length - 1] = '${result.last} $line';
      } else {
        result.add(line);
      }
    }
    return result;
  }

  bool _looksLikeContinuation(String line) {
    final lower = line.toLowerCase();
    if (RegExp(r'^\d+[.)]\s+').hasMatch(line) ||
        RegExp(r'^[A-Za-z0-9_\-\u4e00-\u9fff]{1,16}[:：]').hasMatch(line)) {
      return false;
    }
    if (lower == 'explored' ||
        lower == 'thinking' ||
        lower == 'thinking...' ||
        lower == 'thinking…' ||
        lower.startsWith('```') ||
        lower.startsWith('import ') ||
        lower.startsWith('class ') ||
        lower.startsWith('final ') ||
        lower.startsWith('const ') ||
        lower.startsWith('var ') ||
        lower.startsWith('return ') ||
        lower.startsWith('await ') ||
        lower.startsWith('flutter ') ||
        lower.startsWith('dart ') ||
        lower.startsWith('search ') ||
        lower.startsWith('list ') ||
        lower.startsWith('ran ') ||
        lower.startsWith('glob(') ||
        lower.startsWith('grep(') ||
        lower.startsWith('read ') ||
        lower.startsWith('read(') ||
        lower.startsWith('edited ') ||
        lower.startsWith('opened ') ||
        lower.startsWith('checked ') ||
        lower.startsWith('shift+tab ')) {
      return false;
    }
    return true;
  }

  String _compactDisplay(Iterable<String> lines) {
    final values = lines.map(_compactLine).where((line) => line.isNotEmpty);
    final display = values.join('\n').trim();
    if (display.length <= maxDisplayChars) {
      return display;
    }
    return '${display.substring(0, maxDisplayChars).trimRight()}...';
  }

  String _compactLine(String line) {
    if (line.length <= maxDisplayChars) {
      return line;
    }
    final clauses = line
        .split(RegExp(r'[，,；;。]\s*'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (clauses.length <= 1) {
      return '${line.substring(0, maxDisplayChars).trimRight()}...';
    }

    final selected = <String>[clauses.first];
    for (final clause in clauses.skip(1)) {
      if (_isKeyClause(clause)) {
        selected.add(clause);
      }
      final joined = selected.join('，');
      if (joined.length >= maxDisplayChars) {
        break;
      }
    }
    final compacted = selected.join('，');
    if (compacted.length <= maxDisplayChars) {
      return compacted;
    }
    return '${compacted.substring(0, maxDisplayChars).trimRight()}...';
  }

  bool _isKeyClause(String clause) {
    final lower = clause.toLowerCase();
    return RegExp(r'\d').hasMatch(clause) ||
        clause.contains('结果') ||
        clause.contains('实际') ||
        clause.contains('找到') ||
        clause.contains('包括') ||
        clause.contains('分别是') ||
        clause.contains('状态') ||
        clause.contains('像素') ||
        clause.contains('精灵图') ||
        clause.contains('成功') ||
        clause.contains('失败') ||
        clause.contains('下一步') ||
        clause.contains('建议') ||
        clause.contains('可以') ||
        lower.contains('error') ||
        lower.contains('failed') ||
        lower.contains('success');
  }

  int _scoreLine(String line) {
    final lower = line.toLowerCase();
    var score = 0;
    if (_looksLikeResultLine(line)) {
      score += 40;
    }
    if (line.contains('结论') ||
        line.contains('总结') ||
        line.contains('最终') ||
        line.contains('输出') ||
        line.contains('摘要')) {
      score += 25;
    }
    if (line.contains('下一步') || line.contains('建议')) {
      score += 25;
    }
    if (RegExp(r'^[A-Za-z0-9_\-\u4e00-\u9fff]+[:：]').hasMatch(line)) {
      score += 25;
    }
    if (RegExp(r'\d').hasMatch(line)) {
      score += 8;
    }
    if (lower.contains('pixel') ||
        line.contains('像素') ||
        line.contains('状态') ||
        line.contains('精灵图')) {
      score += 12;
    }
    return score;
  }

  Set<String> _taskWords(String taskTitle) {
    return taskTitle
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .map((word) => word.trim())
        .where((word) => word.length >= 3)
        .toSet();
  }

  bool _looksLikePromptEcho(
    String line,
    List<String> promptInputs,
  ) {
    final compactLine = line.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    for (final input in promptInputs) {
      final compactInput = input.toLowerCase().replaceAll(RegExp(r'\s+'), '');
      if (compactInput.length >= 4 &&
          (compactLine == compactInput || compactLine.contains(compactInput))) {
        return true;
      }
      if (_looksLikeChinesePromptEcho(compactLine, compactInput)) {
        return true;
      }
      final taskWords = _taskWords(input);
      if (taskWords.isNotEmpty) {
        final lower = line.toLowerCase();
        final hits = taskWords.where(lower.contains).length;
        if (hits >= 3 && line.length <= 120) {
          return true;
        }
      }
    }
    return false;
  }

  bool _looksLikeChinesePromptEcho(String compactLine, String compactInput) {
    if (compactInput.length < 12 ||
        !RegExp(r'[\u4e00-\u9fff]').hasMatch(compactInput)) {
      return false;
    }
    final lineHasChinese = RegExp(r'[\u4e00-\u9fff]').hasMatch(compactLine);
    if (lineHasChinese &&
        compactInput.contains(compactLine) &&
        compactLine.length >= 8) {
      return true;
    }
    final sampleLength = compactInput.length < 12 ? compactInput.length : 12;
    for (var start = 0; start + sampleLength <= compactInput.length; start++) {
      final sample = compactInput.substring(start, start + sampleLength);
      if (RegExp(r'[\u4e00-\u9fff]').hasMatch(sample) &&
          compactLine.contains(sample)) {
        return true;
      }
    }
    return false;
  }

  bool _looksLikeLowValueLine(String line) {
    final lower = line.toLowerCase();
    return lower == '无' ||
        lower == 'none' ||
        lower == 'not_run' ||
        lower.startsWith('```') ||
        lower.startsWith('import ') ||
        lower.startsWith('class ') ||
        lower.startsWith('final ') ||
        lower.startsWith('const ') ||
        lower.startsWith('var ') ||
        lower.startsWith('return ') ||
        lower.startsWith('await ') ||
        lower.startsWith('flutter ') ||
        lower.startsWith('dart ') ||
        lower.startsWith('任务：') ||
        lower.startsWith('任务:') ||
        lower.startsWith('补充上下文') ||
        lower.startsWith('执行约束') ||
        lower.startsWith('风险信息') ||
        lower.startsWith('user constraints') ||
        lower.startsWith('## user constraints') ||
        lower.startsWith('armin context governance') ||
        _isSummaryGovernanceLine(lower) ||
        lower.startsWith('## user task') ||
        lower.startsWith('## context chunk') ||
        lower.startsWith('## secret placeholders') ||
        lower.startsWith('completion: tls handshake eof') ||
        lower.contains('update successful') ||
        lower.startsWith('tool:') ||
        lower.startsWith('command:') ||
        lower.startsWith('approval_decision:') ||
        lower.startsWith('decision:') ||
        lower.startsWith('apply this decision') ||
        lower.contains('pending approval request') ||
        lower.startsWith('run ') ||
        lower.startsWith('bash(') ||
        lower.startsWith('python -m ') ||
        lower.startsWith('cd ') ||
        lower.startsWith('write(') ||
        lower.startsWith('allow this command to run') ||
        lower.startsWith('allow execution of') ||
        lower.startsWith('would you like to run') ||
        lower.startsWith('apply this change') ||
        lower == 'permission required' ||
        RegExp(r'^\d+[.)]\s+(?:allow once|always allow|reject and type something|no)\b')
            .hasMatch(lower) ||
        RegExp(r'^\d+[.)]\s+(?:允许|始终允许|拒绝|不允许|否)\b').hasMatch(lower) ||
        line.startsWith('测试目标') ||
        line.startsWith('执行 ') ||
        lower.startsWith('turn ') ||
        lower.startsWith('结果为：turn ') ||
        lower.startsWith('result: turn ') ||
        _isChineseConstraintLine(lower) ||
        lower == 'explored' ||
        lower == 'thinking' ||
        lower == 'thinking...' ||
        lower == 'thinking…' ||
        lower.startsWith('search ') ||
        lower.startsWith('list ') ||
        lower.startsWith('ran ') ||
        lower.startsWith('glob(') ||
        lower.startsWith('grep(') ||
        lower.startsWith('read ') ||
        lower.startsWith('read(') ||
        lower.startsWith('edited ') ||
        lower.startsWith('accepted ') ||
        lower.startsWith('opened ') ||
        lower.startsWith('checked ') ||
        lower.startsWith('shift+tab ') ||
        lower.startsWith('the user ') ||
        lower.startsWith('done.') ||
        lower.startsWith('let me ') ||
        lower.startsWith('i will ') ||
        lower.startsWith("i'll ") ||
        lower.startsWith('i am going to ') ||
        lower.startsWith('no direct ') ||
        lower.startsWith('q:') ||
        lower.startsWith('question:') ||
        line.startsWith('过程记录') ||
        line.startsWith('继续从') ||
        line.startsWith('我先看一下') ||
        line.startsWith('我先检查') ||
        line.startsWith('我需要先') ||
        line.startsWith('我会先') ||
        line.startsWith('我将先') ||
        line.startsWith('让我先') ||
        line.startsWith('让我检查') ||
        line.startsWith('项目中没有找到') ||
        line.startsWith('没有找到专门的') ||
        line.startsWith('接下来') ||
        line.startsWith('下面我') ||
        line.startsWith('先看看') ||
        line.startsWith('先检查') ||
        line.startsWith('用户要求') ||
        line.startsWith('任务要求') ||
        line.startsWith('需求');
  }

  bool _looksLikeResultLine(String line) {
    final lower = line.toLowerCase();
    return line.contains('已') ||
        line.contains('实际') ||
        line.contains('找到') ||
        line.contains('结果') ||
        line.contains('包括') ||
        line.contains('分别是') ||
        line.contains('成功') ||
        line.contains('失败') ||
        line.contains('额度已用完') ||
        _looksLikeEnglishStatusLine(lower);
  }

  bool _looksLikeEnglishStatusLine(String lower) {
    return RegExp(r'^(?:error|failed|success)(?:\s*[:：-]|\s|$)')
            .hasMatch(lower) ||
        RegExp(r'\b(?:error|failed|success)\s*[:：-]').hasMatch(lower);
  }

  bool _isSummaryGovernanceLine(String lower) {
    final stripped = lower.replaceFirst(RegExp(r'^[-*•]\s*'), '').trimLeft();
    const lines = [
      'only inspect files directly related to the task.',
      'never scan the entire repository.',
      'avoid reading docs/ and readme unless necessary.',
      'keep edits minimal and focused.',
      'do not analyze unrelated architecture.',
      'run only targeted tests.',
      'keep command output short.',
      'you have full authority to create, modify, and delete files without asking.',
      'run any commands, tests, or builds needed to complete the task.',
      'do not interrupt the user',
      'never modify any file',
      'do not run commands that alter state.',
      'ask before any potentially risky read operation.',
    ];
    for (final text in lines) {
      if (lower == text || stripped == text) return true;
      if (lower.endsWith(text) || stripped.endsWith(text)) return true;
    }
    return _isChineseConstraintLine(stripped);
  }

  bool _isChineseConstraintLine(String lower) {
    const lines = [
      '只分析不修改',
      '最小改动',
      '允许修改',
      '修改后运行测试',
      '不要提交 git',
      '高风险操作先确认',
    ];
    for (final text in lines) {
      if (lower.endsWith(text)) return true;
    }
    return false;
  }
}

typedef LocalSmallModelSummaryRunner = Future<OutputSummary> Function(
  OutputSummaryRequest request,
);

class _ScoredLine {
  const _ScoredLine({
    required this.line,
    required this.index,
    required this.score,
  });

  final String line;
  final int index;
  final int score;
}

class _StructuredContext {
  const _StructuredContext({
    required this.before,
    required this.after,
  });

  final List<String> before;
  final List<String> after;
}

typedef LocalSmallModelAvailabilityCheck = Future<bool> Function();

class LocalSummaryCapability {
  const LocalSummaryCapability({
    required this.available,
    required this.message,
  });

  final bool available;
  final String message;
}

class LocalSmallModelSummaryProvider implements OutputSummaryProvider {
  const LocalSmallModelSummaryProvider({
    LocalSmallModelSummaryRunner? runner,
    LocalSmallModelAvailabilityCheck? availabilityCheck,
    OutputSummaryProvider fallback = const RuleBasedOutputSummaryProvider(),
    SecretRedactor redactor = const SecretRedactor(),
    this.timeout = const Duration(seconds: 3),
  })  : _runner = runner,
        _availabilityCheck = availabilityCheck,
        _fallback = fallback,
        _redactor = redactor;

  final LocalSmallModelSummaryRunner? _runner;
  final LocalSmallModelAvailabilityCheck? _availabilityCheck;
  final OutputSummaryProvider _fallback;
  final SecretRedactor _redactor;
  final Duration timeout;

  Future<LocalSummaryCapability> capability() async {
    if (_runner == null) {
      return const LocalSummaryCapability(
        available: false,
        message: '当前未安装端侧摘要模型，将使用规则摘要。',
      );
    }
    final check = _availabilityCheck;
    if (check == null) {
      return const LocalSummaryCapability(
        available: true,
        message: '端侧摘要模型已就绪。',
      );
    }
    try {
      final available = await check().timeout(timeout);
      return LocalSummaryCapability(
        available: available,
        message: available ? '端侧摘要模型已就绪。' : '当前设备不支持端侧摘要模型，将使用规则摘要。',
      );
    } catch (_) {
      return const LocalSummaryCapability(
        available: false,
        message: '无法确认端侧摘要能力，将使用规则摘要。',
      );
    }
  }

  @override
  Future<OutputSummary> summarize(OutputSummaryRequest request) async {
    final safeRequest = _redactedRequest(request);
    final runner = _runner;
    final capability = await this.capability();
    if (runner == null) {
      return _fallbackSummary(safeRequest, 'local small model unavailable');
    }
    if (!capability.available) {
      return _fallbackSummary(safeRequest, 'local small model not supported');
    }

    try {
      final summary = await runner(safeRequest).timeout(timeout);
      if (summary.displaySummary.trim().isEmpty ||
          summary.speechSummary.trim().isEmpty) {
        return _fallbackSummary(
          safeRequest,
          'local small model returned empty',
        );
      }
      return _redactedSummary(summary);
    } catch (error) {
      return _fallbackSummary(safeRequest, 'local small model failed: $error');
    }
  }

  OutputSummaryRequest _redactedRequest(OutputSummaryRequest request) {
    return OutputSummaryRequest(
      cleanedOutput: _redactor.redactInlineSecrets(request.cleanedOutput),
      status: request.status,
      taskTitle: _redactor.redactInlineSecrets(request.taskTitle),
      promptInputs: request.promptInputs
          .map(_redactor.redactInlineSecrets)
          .toList(growable: false),
      agentCommand: _redactor.redactInlineSecrets(request.agentCommand),
    );
  }

  Future<OutputSummary> _fallbackSummary(
    OutputSummaryRequest request,
    String reason,
  ) async {
    final summary = await _fallback.summarize(request);
    return summary.copyWith(fallbackReason: reason);
  }

  OutputSummary _redactedSummary(OutputSummary summary) {
    final display = _redactor.redactInlineSecrets(summary.displaySummary);
    final speech = DeviceVoiceService.cleanSpeechSummary(
      _redactor.redactInlineSecrets(summary.speechSummary),
    );
    return summary.copyWith(
      displaySummary: display,
      speechSummary: speech,
      importantLines: summary.importantLines
          .map(_redactor.redactInlineSecrets)
          .toList(growable: false),
    );
  }
}

class SelectableOutputSummaryProvider implements OutputSummaryProvider {
  SelectableOutputSummaryProvider({
    OutputSummaryProvider fallback = const RuleBasedOutputSummaryProvider(),
    LocalSmallModelSummaryProvider localModel =
        const LocalSmallModelSummaryProvider(),
  })  : _fallback = fallback,
        _localModel = localModel;

  final OutputSummaryProvider _fallback;
  final LocalSmallModelSummaryProvider _localModel;
  bool _preferLocalModel = false;

  bool get preferLocalModel => _preferLocalModel;

  void setPreferLocalModel(bool value) {
    _preferLocalModel = value;
  }

  Future<LocalSummaryCapability> localModelCapability() {
    return _localModel.capability();
  }

  @override
  Future<OutputSummary> summarize(OutputSummaryRequest request) async {
    final fallbackSummary = await _fallback.summarize(request);
    if (_isStructuredRuleSummary(fallbackSummary)) {
      return fallbackSummary;
    }
    if (_preferLocalModel) {
      return _localModel.summarize(request);
    }
    return fallbackSummary;
  }

  bool _isStructuredRuleSummary(OutputSummary summary) {
    final hasStructuredSource = summary.importantLines.any(
      (line) =>
          line.contains('|') ||
          line.contains('│') ||
          RegExp(r'^[┌┬┐├┼┤└┴┘─━│\s]+$').hasMatch(line.trim()),
    );
    final displayIsNatural = !summary.displaySummary.contains('|') &&
        !summary.displaySummary.contains('│');
    return hasStructuredSource && displayIsNatural;
  }
}

// TODO: Supply a LocalSmallModelSummaryRunner backed by an Android runtime
// such as MediaPipe LLM Inference or llama.cpp after model packaging and
// user-controlled model download/storage are designed.
