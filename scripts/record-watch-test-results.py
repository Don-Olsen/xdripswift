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

SUITES = ('LibreWatchValuePipelineTests', 'TroubleshootingLogTests',
          'WatchRefreshCoordinatorTests', 'WatchPhoneRefreshServiceTests',
          'WatchSnapshotSemanticsTests', 'WatchDeliveryEvidenceTests',
          'NightscoutHistoryWriteTests')
VERIFY_ONLY_SUITES = ('RootHomeInteractionTests',)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def swift_source_tokens(source):
    """Tokenize declaration boundaries, excluding comments and Swift string contents."""
    def skip_comment(start):
        if source.startswith('//', start):
            end = source.find('\n', start)
            return len(source) if end < 0 else end
        depth, pos = 1, start + 2
        while pos < len(source):
            if source.startswith('/*', pos):
                depth += 1
                pos += 2
            elif source.startswith('*/', pos):
                depth -= 1
                pos += 2
                if depth == 0:
                    return pos
            else:
                pos += 1
        raise ValueError('Unterminated Swift block comment')

    def skip_string(start, hashes, quote):
        pos = start + len(hashes) + len(quote)
        closing, escape = quote + hashes, '\\' + hashes
        while pos < len(source):
            if source.startswith(closing, pos):
                return pos + len(closing)
            if source.startswith(escape, pos):
                pos += len(escape)
                if source.startswith('(', pos):
                    depth, pos = 1, pos + 1
                    while pos < len(source) and depth:
                        nested = re.match(r'(#*)("""|")', source[pos:])
                        if source.startswith(('//', '/*'), pos):
                            pos = skip_comment(pos)
                        elif nested:
                            pos = skip_string(pos, nested[1], nested[2])
                        else:
                            depth += (source[pos] == '(') - (source[pos] == ')')
                            pos += 1
                    require(depth == 0, 'Unterminated Swift string interpolation')
                else:
                    pos += 1
            else:
                pos += 1
        raise ValueError('Unterminated Swift string')

    tokens, pos = [], 0
    while pos < len(source):
        literal = re.match(r'(#*)("""|")', source[pos:])
        if source.startswith(('//', '/*'), pos):
            pos = skip_comment(pos)
        elif literal:
            pos = skip_string(pos, literal[1], literal[2])
            tokens.append('<literal>')
        elif source[pos].isspace():
            pos += 1
        else:
            token = re.match(r'[A-Za-z_][A-Za-z_0-9]*|[0-9]+|[^\s]', source[pos:])[0]
            tokens.append(token)
            pos += len(token)
    return tokens


def suite_methods(source, suite):
    """Require unambiguous direct XCTest methods in one class and its extensions.

    Nested helpers and other classes do not own the selected suite's methods.
    Conditional declarations, generic/qualified suite declarations and overloaded
    or parameterized test methods require explicit discovery support, not guesses.
    """
    tokens = swift_source_tokens(source)
    scopes, declarations, methods = [], {}, set()
    class_count = 0
    types = {'class', 'extension', 'struct', 'enum', 'protocol', 'actor'}
    for index, token in enumerate(tokens):
        if token == '/':
            previous = tokens[index - 1] if index else ''
            following = tokens[index + 1] if index + 1 < len(tokens) else ''
            require((re.fullmatch(r'[A-Za-z_0-9]+', previous) or previous in {')', ']', '<literal>'})
                    and previous not in {'return', 'throw', 'case', 'if', 'else', 'in', 'try', 'await'}
                    and (re.fullmatch(r'[A-Za-z_0-9]+', following) or following in {'(', '<literal>'}),
                    'Unsupported or ambiguous Swift regex/operator syntax in ' + suite)
        if token == '#' and index + 1 < len(tokens):
            require(tokens[index + 1] not in {'if', 'elseif', 'else', 'endif', '/'},
                    'Unsupported conditional or regex declaration syntax in ' + suite)
        if token in types and index + 1 < len(tokens):
            name = tokens[index + 1]
            if name == suite or (token == 'extension' and index + 3 < len(tokens)
                                 and tokens[index + 2:index + 4] == ['.', suite]):
                require(not scopes and name == suite, 'Unsupported nested/qualified suite: ' + suite)
                end = index + 2
                while end < len(tokens) and tokens[end] not in {'{', '}', ';'}:
                    end += 1
                require(end < len(tokens) and tokens[end] == '{', 'Missing suite body: ' + suite)
                header = tokens[index + 2:end]
                require(token in {'class', 'extension'} and '<' not in header and 'where' not in header,
                        'Unsupported suite declaration: ' + suite)
                if token == 'class':
                    require(header == [':', 'XCTestCase'], 'Unsupported XCTest inheritance: ' + suite)
                    class_count += 1
                else:
                    require(not header, 'Unsupported suite extension: ' + suite)
                declarations[end] = suite
        if token == '{':
            scopes.append(declarations.get(index))
        elif token == '}':
            require(bool(scopes), 'Unbalanced Swift source in ' + suite)
            scopes.pop()
        elif token == 'func' and scopes and scopes[-1] == suite:
            require(index + 1 < len(tokens), 'Missing function name in ' + suite)
            name = tokens[index + 1]
            require(name != '`', 'Unsupported escaped method name in ' + suite)
            if re.fullmatch(r'test\w+', name):
                require(tokens[index + 2:index + 4] == ['(', ')'],
                        'Unsupported parameterized test: ' + suite + '/' + name)
                require(index == 0 or tokens[index - 1] not in {'static', 'class'},
                        'Unsupported static test: ' + suite + '/' + name)
                require(name not in methods, 'Ambiguous duplicate test: ' + suite + '/' + name)
                methods.add(name)
    require(not scopes, 'Unbalanced Swift source in ' + suite)
    require(class_count == 1, 'Expected exactly one XCTest class for ' + suite)
    require(bool(methods), 'No declared tests for ' + suite)
    return methods


def declared_tests(root, suites=SUITES):
    return {suite: suite_methods(
        (root / 'xDrip Tests' / (suite + '.swift')).read_text(encoding='utf-8'), suite)
        for suite in suites}


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
    required_count = sum(len(methods) for methods in expected.values())
    require(total >= required_count, 'xcresult summary contains fewer tests than the required methods')
    require(summary['passedTests'] >= required_count,
            'xcresult summary contains fewer passes than the required methods')
    require(total == summary['passedTests'] + summary['failedTests'] + summary['skippedTests'],
            'xcresult summary counts are internally inconsistent')
    return suites


def main(result, destination, include_verify_only=False):
    base = ['xcrun', 'xcresulttool', 'get', 'test-results']
    summary = json.loads(subprocess.check_output(base + ['summary', '--path', str(result)], text=True))
    tree = json.loads(subprocess.check_output(base + ['tests', '--path', str(result)], text=True))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.with_name(destination.stem + '-xcode-summary.json').write_text(
        json.dumps(summary, indent=2), encoding='utf-8')
    tree_path = destination.with_name(destination.stem + '-test-tree.json')
    tree_path.write_text(json.dumps(tree, separators=(',', ':')), encoding='utf-8')
    selected_suites = SUITES + VERIFY_ONLY_SUITES if include_verify_only else SUITES
    expected = declared_tests(Path(__file__).resolve().parents[1], selected_suites)
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
    expected = {suite: {'testOne', 'testTwo'} for suite in SUITES + VERIFY_ONLY_SUITES}
    test_count = sum(len(methods) for methods in expected.values())
    summary = {'totalTestCount': test_count, 'passedTests': test_count,
               'failedTests': 0, 'skippedTests': 0}
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
    # A file may hold another XCTest class and extensions before/after the owner.
    # Shared method names must retain their class identity, and nested helpers,
    # comments and strings must never introduce declarations.
    source = r'''
    extension SelectedTests { func testBefore() {} }
    final class OtherTests: XCTestCase {
        func testShared() {}
        func testOnlyOther() {}
    }
    final class SelectedTests: XCTestCase {
        func testShared() {
            let text = "func testString() { } \(String("{ }"))"
            let raw = #"func testRaw() { }"#
            let multiline = """
                func testMultiline() { }
                """
            let ratio = 10 / 2
        }
        /* nested /* func testComment() { } */ comment */
        // func testLineComment() {}
        struct Helper { func testNestedHelper() {} }
    }
    extension SelectedTests { func testAfter() async throws {} }
    '''
    selected = suite_methods(source, 'SelectedTests')
    require(selected == {'testBefore', 'testShared', 'testAfter'}, 'Selected class/extension ownership mismatch')
    require(suite_methods(source, 'OtherTests') == {'testShared', 'testOnlyOther'}, 'Other class ownership mismatch')
    discovery_checks = 2
    invalid_sources = [
        source + 'extension SelectedTests { func testShared() {} }',
        source + 'final class SelectedTests: XCTestCase { func testDuplicateClass() {} }',
        'extension SelectedTests { func testOrphan() {} }',
        'final class SelectedTests: CustomBase { func testUnknownInheritance() {} }',
        'final class SelectedTests<T>: XCTestCase { func testGenericOwner() {} }',
        'final class SelectedTests: XCTestCase { func testValue(_ value: Int) {} }',
        'final class SelectedTests: XCTestCase { static func testStatic() {} }',
        'final class SelectedTests: XCTestCase { func `testEscaped`() {} func testOne() {} }',
        '#if DEBUG\n' + source + '\n#endif',
        source + 'extension Module.SelectedTests { func testQualified() {} }',
        source + 'extension SelectedTests where Value: Equatable { func testConstrained() {} }',
        source + '}',
        source + '/* unterminated',
        source + 'let text = "unterminated',
        source + 'let regex = /func testRegex() { }/',
    ]
    for fixture in invalid_sources:
        try:
            suite_methods(fixture, 'SelectedTests')
        except ValueError:
            discovery_checks += 1
        else:
            raise ValueError('Unsupported or ambiguous Swift declaration did not fail closed')
    wrong_owner = {'testNodes': [{'name': 'OtherTests', 'nodeType': 'Test Suite', 'children': [
        {'name': 'testShared()', 'nodeType': 'Test Case', 'result': 'Passed',
         'nodeIdentifier': 'OtherTests/testShared()'}]}]}
    try:
        analyze({'totalTestCount': 1, 'passedTests': 1, 'failedTests': 0, 'skippedTests': 0},
                wrong_owner, {'SelectedTests': {'testShared'}})
    except ValueError:
        discovery_checks += 1
    else:
        raise ValueError('Another class satisfied a required same-name test')
    print(json.dumps({'verification': 'synthetic local JSON and Swift-source fixtures only; no XCTest execution',
                      'checksPassed': len(variants) + 2 + discovery_checks,
                      'resultChecks': len(variants) + 2, 'discoveryChecks': discovery_checks}))


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        self_test()
    else:
        include_verify_only = len(sys.argv) == 4 and sys.argv[3] == '--include-verify-only'
        require(len(sys.argv) == 3 or include_verify_only,
                'Usage: record-watch-test-results.py XCRESULT MANIFEST [--include-verify-only] or --self-test')
        main(Path(sys.argv[1]), Path(sys.argv[2]), include_verify_only)
