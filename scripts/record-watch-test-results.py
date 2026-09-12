"""Record actual XCTest results and reject missing, skipped or failed new suites.
Command family: Apple's Xcode 16.3 release notes:
https://developer.apple.com/documentation/Xcode-Release-Notes/xcode-16_3-release-notes
Unknown result shapes fail closed; retain the compact test tree for diagnosis.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote

SUITES = ('WatchRefreshCoordinatorTests', 'WatchPhoneRefreshServiceTests',
          'WatchSnapshotSemanticsTests', 'WatchDeliveryEvidenceTests')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def declared_tests(root):
    expected = {}
    for suite in SUITES:
        source = (root / 'xDrip Tests' / (suite + '.swift')).read_text(encoding='utf-8')
        methods = set(re.findall(r'\bfunc\s+(test\w+)\s*\(', source))
        require(bool(methods), 'No declared tests for ' + suite)
        expected[suite] = methods
    return expected


def analyze(summary, tree, expected):
    require(isinstance(summary, dict) and isinstance(tree, dict), 'Unsupported xcresult JSON')
    total = summary.get('totalTestCount')
    require(type(total) is int and total > 0, 'No actual executed tests in xcresult summary')
    require(summary.get('failedTests') == 0, 'xcresult contains failures or lacks failure count')
    require(summary.get('skippedTests') == 0, 'xcresult contains skipped tests or lacks skip count')
    require(type(summary.get('passedTests')) is int and summary['passedTests'] > 0, 'No confirmed passing tests')
    found = {suite: {} for suite in expected}

    def visit(node, ancestors=()):
        if isinstance(node, list):
            for value in node:
                visit(value, ancestors)
            return
        if not isinstance(node, dict):
            return
        labels = tuple(unquote(node[key]) for key in ('name', 'nodeIdentifier', 'testIdentifier', 'testIdentifierURL')
                       if isinstance(node.get(key), str))
        path = ancestors + labels
        kind = re.sub(r'[^a-z]', '', str(node.get('nodeType', '')).lower())
        if kind == 'testcase':
            owners = [suite for suite in expected if any(
                re.search(r'(?<![A-Za-z0-9_])' + re.escape(suite) + r'(?![A-Za-z0-9_])', label) for label in path)]
            if owners:
                require(len(owners) == 1, 'Ambiguous XCTest suite identity')
                suite = owners[0]
                methods = set()
                for label in labels:
                    methods.update(re.findall(r'\b(test\w+)\s*(?:\(|$|/)', label))
                methods &= expected[suite]
                require(len(methods) == 1, 'Unrecognized test case identity in ' + suite)
                method = next(iter(methods))
                outcome = node.get('result')
                require(outcome == 'Passed', 'Required XCTest case did not pass: ' + suite + '/' + method)
                found[suite][method] = found[suite].get(method, 0) + 1
        for key, value in node.items():
            if isinstance(value, (dict, list)):
                visit(value, path)

    visit(tree)
    suites = {}
    for suite, methods in expected.items():
        missing = methods - found[suite].keys()
        require(not missing, 'Required XCTest methods not executed: ' + suite + ' (' + str(len(missing)) + ' missing)')
        require(len(found[suite]) > 0, 'Required XCTest suite executed zero tests: ' + suite)
        suites[suite] = {'declaredMethods': len(methods), 'uniquePassedMethods': len(found[suite]),
                         'caseResultNodes': sum(found[suite].values()), 'failed': 0, 'skipped': 0}
    return suites


def main(result, destination):
    base = ['xcrun', 'xcresulttool', 'get', 'test-results']
    summary = json.loads(subprocess.check_output(base + ['summary', '--path', str(result)], text=True))
    tree = json.loads(subprocess.check_output(base + ['tests', '--path', str(result)], text=True))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.with_name(destination.stem + '-xcode-summary.json').write_text(
        json.dumps(summary, indent=2), encoding='utf-8')
    tree_path = destination.with_name(destination.stem + '-test-tree.json')
    tree_path.write_text(json.dumps(tree, separators=(',', ':')), encoding='utf-8')
    expected = declared_tests(Path(__file__).resolve().parents[1])
    manifest = {'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
                'resultBundle': str(result), 'testTreeArtifact': tree_path.name,
                'counts': {key: summary.get(key) for key in ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests')},
                'verificationPassed': False}
    try:
        manifest['requiredSuites'] = analyze(summary, tree, expected)
        manifest['verificationPassed'] = True
    except ValueError as error:
        manifest['verificationError'] = str(error)
        destination.write_text(json.dumps(manifest, indent=2), encoding='utf-8')
        raise
    destination.write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print(json.dumps(manifest, indent=2))


def self_test():
    expected = {suite: {'testOne', 'testTwo'} for suite in SUITES}
    summary = {'totalTestCount': 8, 'passedTests': 8, 'failedTests': 0, 'skippedTests': 0}
    tree = {'testNodes': [{'name': suite, 'nodeType': 'Test Suite', 'children': [
        {'name': method + '()', 'nodeType': 'Test Case', 'result': 'Passed',
         'nodeIdentifier': suite + '/' + method + '()'} for method in sorted(methods)]}
        for suite, methods in expected.items()]}
    clone = lambda value: json.loads(json.dumps(value))
    analyzed = analyze(clone(summary), clone(tree), expected)
    require(all(row['uniquePassedMethods'] == 2 for row in analyzed.values()), 'Synthetic successful tree count mismatch')
    variants = []
    missing_suite = clone(tree); missing_suite['testNodes'].pop()
    variants.append((summary, missing_suite))
    missing_method = clone(tree); missing_method['testNodes'][0]['children'].pop()
    variants.append((summary, missing_method))
    for result in ('Skipped', 'Failed', 'Expected Failure', None):
        bad = clone(tree); bad['testNodes'][0]['children'][0]['result'] = result
        variants.append((summary, bad))
    variants.extend([(dict(summary, totalTestCount=0), tree), (dict(summary, failedTests=1), tree),
                     (dict(summary, skippedTests=1), tree), (summary, {'unknownSchema': []})])
    for counts, nodes in variants:
        try:
            analyze(clone(counts), clone(nodes), expected)
        except ValueError:
            pass
        else:
            raise ValueError('Synthetic invalid test-result fixture did not fail')
    duplicate = clone(tree)
    duplicate['testNodes'][0]['children'].append(clone(duplicate['testNodes'][0]['children'][0]))
    require(analyze(summary, duplicate, expected)[SUITES[0]]['uniquePassedMethods'] == 2, 'Duplicate result inflated unique test count')
    print(json.dumps({'verification': 'synthetic local JSON fixtures only; no XCTest execution',
                      'checksPassed': len(variants) + 2}))


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        self_test()
    else:
        require(len(sys.argv) == 3, 'Usage: record-watch-test-results.py XCRESULT MANIFEST or --self-test')
        main(Path(sys.argv[1]), Path(sys.argv[2]))
