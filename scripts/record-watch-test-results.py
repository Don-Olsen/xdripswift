"""Record actual Xcode test results, plus source/tool identity. Never infer test execution."""
import json
from pathlib import Path
import subprocess
import sys

result = Path(sys.argv[1])
destination = Path(sys.argv[2])
summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)], text=True))
manifest = {'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
            'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
            'resultBundle': str(result), 'summary': summary}
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(manifest, indent=2), encoding='utf-8')
print(json.dumps(manifest, indent=2))
