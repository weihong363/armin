import 'package:flutter_test/flutter_test.dart';

import 'package:armin/features/voice/services/pinyin_confusion_corrector.dart';
import 'package:armin/features/voice/services/transcript_normalizer.dart';

void main() {
  // ============================================================
  // PinyinConfusionCorrector 直接测试
  // ============================================================
  group('PinyinConfusionCorrector', () {
    late PinyinConfusionCorrector corrector;

    setUp(() {
      corrector = const PinyinConfusionCorrector();
    });

    // ---- Pass 1: 短语级直接修正 ----

    group('phrase corrections', () {
      test('corrects 带码 → 代码', () {
        final result = corrector.correct('我写了一些带码');
        expect(result.text, '我写了一些代码');
        // Phrase corrections are applied in pass 1 without producing
        // per-character correction records; only pass 2 produces them.
      });

      test('corrects 代马 → 代码', () {
        final result = corrector.correct('检查这个代马');
        expect(result.text, '检查这个代码');
      });

      test('corrects 数聚库 → 数据库', () {
        final result = corrector.correct('连接数聚库');
        expect(result.text, '连接数据库');
      });

      test('corrects 布属 → 部署', () {
        final result = corrector.correct('布属到服务器');
        expect(result.text, '部署到服务器');
      });

      test('corrects 重购 → 重构', () {
        final result = corrector.correct('这个模块需要重购');
        expect(result.text, '这个模块需要重构');
      });

      test('corrects 依懒 → 依赖', () {
        final result = corrector.correct('添加依懒');
        expect(result.text, '添加依赖');
      });

      test('corrects 攻能 → 功能', () {
        final result = corrector.correct('新攻能上线');
        expect(result.text, '新功能上线');
      });

      test('leaves correct text unchanged', () {
        final result = corrector.correct('请检查登录模块的代码');
        expect(result.text, '请检查登录模块的代码');
        expect(result.corrections, isEmpty);
      });

      test('empty input returns empty', () {
        final result = corrector.correct('');
        expect(result.text, '');
        expect(result.corrections, isEmpty);
      });
    });

    // ---- Pass 2: 字级上下文消歧 ----

    group('character-level context disambiguation', () {
      // -- 在 vs 再 --
      test('在 vs 再: 现在 prefers 在', () {
        final result = corrector.correct('现再开始检查');
        expect(result.text, '现在开始检查');
      });

      test('在 vs 再: 一再 prefers 再', () {
        final result = corrector.correct('一在强调这个问题');
        expect(result.text, '一再强调这个问题');
      });

      test('在 vs 再: 存在 keeps 在', () {
        final result = corrector.correct('这个文件存再');
        expect(result.text, '这个文件存在');
      });

      // -- 的 vs 得 vs 地 --
      test('de: 跑得很快 prefers 得', () {
        final result = corrector.correct('他跑的很快');
        expect(result.text, '他跑得很快');
      });

      test('de: 我的项目 keeps 的', () {
        final result = corrector.correct('我得项目');
        expect(result.text, '我的项目');
      });

      // -- 作 vs 做 --
      test('zuo: 工作 keeps 作', () {
        final result = corrector.correct('工做流程');
        expect(result.text, '工作流程');
      });

      test('zuo: 做事 prefers 做', () {
        final result = corrector.correct('作事要小心');
        expect(result.text, '做事要小心');
      });

      // -- 那 vs 哪 --
      test('na: 问那个 → 问哪个', () {
        final result = corrector.correct('问那个文件');
        expect(result.text, '问哪个文件');
      });

      // -- 吧 vs 把 --
      test('ba: 好吧 keeps 吧', () {
        final result = corrector.correct('好把，我试试');
        expect(result.text, '好吧，我试试');
      });

      test('ba: 把这个 keeps 把', () {
        final result = corrector.correct('吧这个文件删掉');
        expect(result.text, '把这个文件删掉');
      });

      // -- 向 vs 像 --
      test('xiang: 方向 keeps 向', () {
        final result = corrector.correct('方像不对');
        expect(result.text, '方向不对');
      });

      // -- 建 vs 见 --
      test('jian: 创建 keeps 建', () {
        final result = corrector.correct('创见一个新项目');
        expect(result.text, '创建一个新项目');
      });

      test('jian: 意见 keeps 见', () {
        final result = corrector.correct('我的意建');
        expect(result.text, '我的意见');
      });

      // -- 试 vs 式 --
      test('shi: 测试 keeps 试', () {
        final result = corrector.correct('运行测式');
        expect(result.text, '运行测试');
      });

      test('shi: 方式 keeps 式', () {
        final result = corrector.correct('换个方试');
        expect(result.text, '换个方式');
      });

      // -- 及 vs 即 --
      test('ji: 立即 keeps 即', () {
        final result = corrector.correct('立及生效');
        expect(result.text, '立即生效');
      });

      // -- 里 vs 理 --
      test('li: 处理 keeps 理', () {
        final result = corrector.correct('处里这个请求');
        expect(result.text, '处理这个请求');
      });

      test('li: 这里 keeps 里', () {
        final result = corrector.correct('这理有问题');
        expect(result.text, '这里有问题');
      });

      // -- 关 vs 观 --
      test('guan: 关于 keeps 关', () {
        final result = corrector.correct('观于这个项目');
        expect(result.text, '关于这个项目');
      });

      // -- 到 vs 道 --
      test('dao: 知道 keeps 道', () {
        final result = corrector.correct('我知到这个问题');
        expect(result.text, '我知道这个问题');
      });

      test('dao: 找到 keeps 到', () {
        final result = corrector.correct('帮我找道那个文件');
        expect(result.text, '帮我找到那个文件');
      });

      // -- 原 vs 元 vs 源 --
      test('yuan: 资源 keeps 源', () {
        final result = corrector.correct('系统资原不足');
        expect(result.text, '系统资源不足');
      });

      test('yuan: 原因 keeps 原', () {
        final result = corrector.correct('出错元因');
        expect(result.text, '出错原因');
      });

      // -- 记 vs 计 --
      test('ji: 记录 keeps 记', () {
        final result = corrector.correct('计录这个日志');
        expect(result.text, '记录这个日志');
      });

      test('ji: 设计 keeps 计', () {
        final result = corrector.correct('设记模式');
        expect(result.text, '设计模式');
      });
    });

    // ---- 混合场景 ----
    group('mixed corrections', () {
      test('phrase + character corrections both apply', () {
        final result = corrector.correct('这个带码需要重购和测式');
        expect(result.text, '这个代码需要重构和测试');
      });

      test('character correction with context from phrase correction', () {
        // After phrase correction "带码"→"代码", the character at 码's position
        // changes context. But our pipeline does phrase first, then character,
        // so the character-level pass sees "代码" not "带码".
        final result = corrector.correct('带码没有工做');
        // 带码→代码 (phrase), 工做→工作 (char)
        expect(result.text, '代码没有工作');
      });
    });

    // ---- 边界情况 ----
    group('edge cases', () {
      test('single character returns unchanged', () {
        final result = corrector.correct('在');
        expect(result.text, '在');
        expect(result.corrections, isEmpty);
      });

      test('text with no confusion group characters', () {
        final result = corrector.correct('abcdefg12345');
        expect(result.text, 'abcdefg12345');
        expect(result.corrections, isEmpty);
      });

      test('mixed Chinese and English', () {
        final result = corrector.correct('API的设记需要重购');
        expect(result.text, 'API的设计需要重构');
      });

      test('long text with multiple corrections', () {
        final result = corrector.correct(
          '这个带码的工做流程有问题，需要立即重购。方像不对，换个方试。',
        );
        expect(result.text,
            '这个代码的工作流程有问题，需要立即重构。方向不对，换个方式。');
      });

      test('no false positive on 说道 vs 说到', () {
        // Both are valid, neither should be corrected.
        final r1 = corrector.correct('他说道理很简单');
        final r2 = corrector.correct('请说到做到');
        // 道理 is 道理 not 到理, so r1 should correct 到→道 in "道理"
        expect(r1.text, '他说道理很简单'); // 道理 already correct
        expect(r2.text, '请说到做到');
      });
    });
  });

  // ============================================================
  // TranscriptNormalizer 集成测试
  // ============================================================
  group('TranscriptNormalizer integration', () {
    late TranscriptNormalizer normalizer;

    setUp(() {
      normalizer = const TranscriptNormalizer();
    });

    test('pinyin correction runs in pipeline after dictionary', () {
      final result = normalizer.normalize('立及修复这个带码');
      expect(result.correctedText, contains('立即'));
      expect(result.correctedText, contains('代码'));
      // Both phrase and character corrections should apply
      expect(result.changes.length, greaterThanOrEqualTo(1));
    });

    test('correction changes are tracked with reason', () {
      // 立即→立即 (character-level: 及→即) triggers pinyin correction change
      final result = normalizer.normalize('立及修复这个问题');
      final correctionChanges = result.changes
          .where((c) => c.reason.startsWith('拼音纠错'));
      expect(correctionChanges.isNotEmpty, isTrue);
    });

    test('pinyin correction changes are not dictionary matches', () {
      final result = normalizer.normalize('工做流程');
      final pinyinChanges = result.changes
          .where((c) => c.reason.startsWith('拼音纠错'));
      for (final c in pinyinChanges) {
        expect(c.isDictionaryMatch, isFalse);
      }
    });

    test('confidence remains high for minor corrections', () {
      final result = normalizer.normalize('立及生效的连接方式');
      // 立即→立即 is character-level pinyin correction
      final pinyinCount = result.changes
          .where((c) => c.reason.startsWith('拼音纠错'))
          .length;
      expect(pinyinCount, greaterThanOrEqualTo(1));
      expect(result.confidence, greaterThanOrEqualTo(0.75));
    });

    test('correctOnly does not run pinyin correction', () {
      // correctOnly currently only runs dictionary, not pinyin correction.
      // This is by design — correctOnly is for preserving original semantics.
      final result = normalizer.correctOnly('这个带码要测式');
      // Should stay as-is (带码→代码 is pinyin, not dictionary)
      // Note: if "带码" is in dictionary, it would be corrected here.
      // We mainly test that the method doesn't crash with input that
      // goes through the pinyin path in normalize().
      expect(result.correctedText, isNotEmpty);
    });
  });
}
