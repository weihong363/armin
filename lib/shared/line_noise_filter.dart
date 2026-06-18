class LineNoiseFilter {
  const LineNoiseFilter();

  bool isTerminalGraphic(String line) {
    final compact = line.replaceAll(RegExp(r'\s+'), '');
    return compact.length >= 2 &&
        RegExp(
          r'^[█▓▒░▀▄▌▐▖▗▘▝▚▞▟▙▛▜▔▁▂▃▄▅▆▇╭╮╰╯─│┌┐└┘┬┴├┤┼━┃╋]+$',
        ).hasMatch(compact);
  }

  bool hasTableDecoration(String line) {
    final trimmed = line.trimLeft();
    if ('│'.allMatches(trimmed).length >= 2) {
      return true;
    }
    return RegExp(r'[┌┐└┘┬┼┴├┤─━]').hasMatch(trimmed);
  }

  bool isUnreadable(String line) {
    return hasTableDecoration(line) || isTerminalGraphic(line);
  }
}
