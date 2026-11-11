"""生成 src/.local/probes/ 中的隔离 Flutter iOS 探针，不启动云构建或修改 App 工程。"""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.stdout.reconfigure(encoding='utf-8')

parser = argparse.ArgumentParser()
parser.add_argument('--flutter', default='flutter')
args = parser.parse_args()
probe = Path(__file__).resolve().parent
host = probe.parents[2]
if not (host / 'pubspec.yaml').is_file() or not (host / 'windows').is_dir():
    raise RuntimeError('Windows host root not found')
output = host.parent / '.local/probes'
for parent in [output, *output.parents]:
    if parent.exists() and parent.resolve() != parent.absolute():
        raise RuntimeError('Redirected probe path rejected')
output.mkdir(parents=True, exist_ok=True)
target = Path(tempfile.mkdtemp(prefix='sqlcipher-ios-probe-', dir=output))
subprocess.run([args.flutter, 'create', '--no-pub', '--empty', '--platforms=ios',
                '--project-name=miyu_sqlcipher_ios_probe', str(target)], check=True)
pubspec = '''name: miyu_sqlcipher_ios_probe
publish_to: none
version: 0.0.1+1
environment:
  sdk: '>=3.10.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  miyu_sqlcipher_probe:
    path: PROBE_PATH
dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:
    sdk: flutter
hooks:
  user_defines:
    sqlite3:
      source: sqlcipher
flutter:
  uses-material-design: true
'''.replace('PROBE_PATH', json.dumps(probe.as_posix(), ensure_ascii=False))
(target / 'pubspec.yaml').write_text(pubspec, encoding='utf-8')
(target / 'analysis_options.yaml').write_text('analyzer:\n  errors:\n    avoid_print: ignore\n', encoding='utf-8')
(target / 'lib/main.dart').write_text((probe / 'templates/main.dart.txt').read_text(encoding='utf-8'), encoding='utf-8')
(target / 'integration_test').mkdir()
(target / 'integration_test/sqlcipher_test.dart').write_text(
    (probe / 'templates/sqlcipher_test.dart.txt').read_text(encoding='utf-8'), encoding='utf-8')
print(f'Prepared isolated harness: {target}')
print('下一步在 macOS/Xcode 上执行 README 中的构建与测试命令；生成工程不代表 iOS 已验证。')
