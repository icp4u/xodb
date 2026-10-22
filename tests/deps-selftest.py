#!/usr/bin/env python3
"""scripts/deps on a small fake tree: each kind of failure, and the clean case."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest

DEPS = Path(__file__).resolve().parents[1] / 'scripts/deps'

LAYERS = """\
src/main.zig      root
src/model/**      model
src/ui/**         ui
src/common/**     common
src/runtime/**    runtime
"""
RULES = """\
deny model-no-ui     model -> ui
deny no-hub          ui -> src/model/hub.zig
only runtime-alone   runtime -> runtime
"""
FILES = {
    'build.zig': 'module.addIncludePath(b.path("src/runtime"));\nmodule.addOptions("build_options", options);\n',
    'src/main.zig': 'const ui = @import("ui/view.zig");\nconst m = @import("model/state.zig");\nconst o = @import("build_options");\n',
    'src/model/state.zig': 'const std = @import("std");\nconst c = @import("../common/util.zig");\n'
                           '// const ui = @import("../ui/view.zig"); a comment is not an import\n',
    'src/model/hub.zig': 'const std = @import("std");\n',
    'src/ui/view.zig': 'const m = @import("../model/state.zig");\nconst s = "@import(\\"../model/hub.zig\\")";\n',
    'src/common/util.zig': 'pub const x = 1;\n',
    'src/runtime/a.c': '#include <stdio.h>\n#include "a.h"\n#include "generated.h"\n',
    'src/runtime/a.h': '#pragma once\n',
}


class DepsSelfTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='xodb-deps-selftest-')
        self.root = Path(self.temporary.name)
        for name, text in FILES.items():
            self.write(name, text)
        self.write('tools/deps/layers', LAYERS)
        self.write('tools/deps/rules', RULES)
        self.write('tools/deps/budgets', 'src/model/state.zig 2\n')
        self.assertEqual(self.deps('baseline', '--write').returncode, 0)
        self.assertEqual(self.read('tools/deps/baseline').count('\n'), self.header_lines() + 1)
        self.assertIn('\ncycle sizes:\n', self.read('tools/deps/baseline'))
        self.passes()

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def read(self, name):
        return (self.root / name).read_text()

    def header_lines(self):
        return sum(1 for line in self.read('tools/deps/baseline').splitlines() if line.startswith('#'))

    def deps(self, *args):
        return subprocess.run([sys.executable, '-B', str(DEPS), '--root', str(self.root), *args],
                              capture_output=True, text=True, timeout=30)

    def passes(self):
        run = self.deps('check')
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn('deps: ok', run.stdout)
        return run.stdout

    def fails(self, *expected):
        run = self.deps('check')
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn('deps: FAIL', run.stdout)
        for text in expected:
            self.assertIn(text, run.stdout)
        return run.stdout

    def test_clean_tree_notes(self):
        out = self.passes()
        self.assertIn('7 files, 6 edges', out)
        self.assertIn('1 unresolved includes', out)  # generated.h: reported, not guessed

    def test_forbidden_direct_edge_fails(self):
        self.write('src/model/hub.zig', 'const v = @import("../ui/view.zig");\n')
        self.fails('+ src/model/hub.zig -> src/ui/view.zig  [model-no-ui]')

    def test_transitive_edge_names_the_culprit(self):
        self.write('src/common/util.zig', 'const v = @import("../ui/view.zig");\n')
        out = self.fails('+ src/model/state.zig -> src/common/util.zig  [model-no-ui transitive]',
                         'chain: src/model/state.zig -> src/common/util.zig -> src/ui/view.zig')
        self.assertNotIn('src/common/util.zig -> src/ui/view.zig  [', out)  # common is not under the rule

    def test_file_level_rule(self):
        self.write('src/ui/view.zig', 'const h = @import("../model/hub.zig");\n')
        self.fails('+ src/ui/view.zig -> src/model/hub.zig  [no-hub]')

    def test_c_include_outside_runtime_fails(self):
        self.write('src/common/x.h', '#pragma once\n')
        self.write('src/runtime/a.c', '#include "../common/x.h"\n')
        self.fails('+ src/runtime/a.c -> src/common/x.h  [runtime-alone]')

    def test_baselined_violation_passes_and_stale_line_fails(self):
        self.write('src/model/hub.zig', 'const v = @import("../ui/view.zig");\n')
        self.assertEqual(self.deps('baseline', '--write').returncode, 0)
        self.passes()
        self.write('src/model/hub.zig', 'const std = @import("std");\n')
        self.fails('baseline lines no longer occur', '- src/model/hub.zig -> src/ui/view.zig  [model-no-ui]')

    def test_new_cycle_fails(self):
        self.write('src/common/util.zig', 'const o = @import("other.zig");\n')
        self.write('src/common/other.zig', 'const u = @import("util.zig");\n')
        self.fails('+ src/common/other.zig  [cycle]', '+ src/common/util.zig  [cycle]',
                   'cycle: src/common/other.zig -> src/common/util.zig -> src/common/other.zig')

    def two_cycles(self):
        self.write('src/common/a.zig', 'const b = @import("b.zig");\n')
        self.write('src/common/b.zig', 'const a = @import("a.zig");\n')
        self.write('src/common/c.zig', 'const d = @import("d.zig");\n')
        self.write('src/common/d.zig', 'const c = @import("c.zig");\n')
        self.assertEqual(self.deps('baseline', '--write').returncode, 0)
        self.assertIn('\ncycle sizes: 2 2\n', self.read('tools/deps/baseline'))
        self.passes()

    def test_cycles_merging_fails(self):
        self.two_cycles()
        self.write('src/common/b.zig', 'const a = @import("a.zig");\nconst c = @import("c.zig");\n')
        self.write('src/common/d.zig', 'const c = @import("c.zig");\nconst a = @import("a.zig");\n')
        out = self.fails('import cycles grew or merged', '- cycle sizes: 2 2', '+ cycle sizes: 4',
                         'cycle of 4: src/common/a.zig src/common/b.zig src/common/c.zig src/common/d.zig')
        self.assertNotIn('[cycle]', out)  # every file was in a cycle already: only the size line sees it

    def test_cycle_broken_asks_for_new_size_line(self):
        self.two_cycles()
        self.write('src/common/d.zig', 'pub const d = 0;\n')
        self.fails('import cycles shrank or split', '- cycle sizes: 2 2', '+ cycle sizes: 2',
                   '- src/common/d.zig  [cycle]')

    def test_angle_include_of_project_header_is_an_edge(self):
        self.write('src/common/x.h', '#pragma once\n')
        self.write('build.zig', FILES['build.zig'] + 'module.addIncludePath(b.path("src/common"));\n')
        self.write('src/runtime/a.c', '#include <stdio.h>\n#include <x.h>\n')
        self.fails('+ src/runtime/a.c -> src/common/x.h  [runtime-alone]')

    def test_multiline_import_with_trailing_comma(self):
        self.write('src/model/hub.zig', 'const v = @import(\n    "../ui/view.zig",\n);\n')
        self.fails('+ src/model/hub.zig -> src/ui/view.zig  [model-no-ui]')

    def test_unmapped_file_fails(self):
        self.write('src/stray/z.zig', 'pub const z = 0;\n')
        self.fails('unmapped file (add a glob to tools/deps/layers): src/stray/z.zig')

    def test_budget_exceeded_fails(self):
        self.write('src/model/hub.zig', 'const s = @import("state.zig");\n')
        self.fails('src/model/state.zig has 3 direct importers, budget 2')

    def test_budget_under_suggests_lower(self):
        self.write('tools/deps/budgets', 'src/model/state.zig 5\n')
        self.assertIn('lower the budget to 2', self.passes())

    def test_unwidened_int_from_bool_sum_fails(self):
        self.write('src/model/hub.zig',
                   'const bad = @intFromBool(first()) + @intFromBool(second());\n')
        self.fails('direct @intFromBool additions use u1 arithmetic',
                   'src/model/hub.zig:1: @intFromBool(...) + @intFromBool(...)')

    def test_grouped_int_from_bool_sum_fails(self):
        self.write('src/model/hub.zig',
                   'const a = (@intFromBool(first())) + @intFromBool(second());\n'
                   'const b = @intFromBool(first()) + ( @intFromBool(second()) );\n')
        self.fails('src/model/hub.zig:1: @intFromBool(...) + @intFromBool(...)',
                   'src/model/hub.zig:2: @intFromBool(...) + @intFromBool(...)')

    def test_widened_int_from_bool_sum_and_literal_text_pass(self):
        self.write('src/model/hub.zig',
                   'const good = @as(u8, @intFromBool(first())) + @intFromBool(second());\n'
                   'const chain = @as(usize, 4) + @intFromBool(first()) + @intFromBool(second());\n'
                   'const text = "@intFromBool(a) + @intFromBool(b)";\n'
                   '// @intFromBool(a) + @intFromBool(b)\n')
        self.passes()

    def test_why_and_rdeps(self):
        run = self.deps('why', 'root', 'common')
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual([line.split()[-2] for line in run.stdout.splitlines()],
                         ['src/main.zig', 'src/model/state.zig', 'src/common/util.zig'])
        self.assertEqual(self.deps('why', 'common', 'ui').returncode, 1)
        run = self.deps('rdeps', 'src/common/util.zig')
        self.assertEqual(run.stdout.split(), ['src/main.zig', 'src/model/state.zig', 'src/ui/view.zig'])

    def test_graph_json(self):
        import json
        graph = json.loads(self.deps('graph', '--json').stdout)
        layers = {f['path']: f['layer'] for f in graph['files']}
        self.assertEqual(layers['src/runtime/a.h'], 'runtime')
        edges = {(e['source'], e['target'], e['kind']) for e in graph['edges']}
        self.assertIn(('src/runtime/a.c', 'src/runtime/a.h', 'include'), edges)
        self.assertIn(('src/main.zig', 'module:build_options', 'module'), edges)
        self.assertNotIn(('src/ui/view.zig', 'src/model/hub.zig', 'import'), edges)  # inside a string

    def strict_rule(self, name='model-no-ui'):
        self.write('tools/deps/rules', RULES.replace('deny ' + name, 'strict deny ' + name))

    def test_strict_clean_and_baselined_direct_violation(self):
        self.strict_rule()
        self.passes()
        self.write('src/model/hub.zig', 'const v = @import("../ui/view.zig");\n')
        self.write('tools/deps/rules', RULES)
        self.assertEqual(self.deps('baseline', '--write').returncode, 0)
        self.passes()  # Negative control: the same exemption works without strict.
        self.strict_rule()
        self.fails('strict rule forbids baseline exemption', '[model-no-ui]')
        before = self.read('tools/deps/baseline')
        run = self.deps('baseline', '--write')
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn('baseline unchanged', run.stdout)
        self.assertEqual(self.read('tools/deps/baseline'), before)

    def test_strict_transitive_exemption_and_stale_exemption(self):
        self.write('src/common/util.zig', 'const h = @import("../model/hub.zig");\n')
        self.assertEqual(self.deps('baseline', '--write').returncode, 0)
        self.passes()
        self.strict_rule('no-hub')
        self.fails('strict rule forbids baseline exemption', '[no-hub transitive]')
        self.write('src/common/util.zig', FILES['src/common/util.zig'])
        self.fails('strict rule forbids baseline exemption', 'no longer occur')
        self.assertEqual(self.deps('baseline', '--write').returncode, 0)
        self.passes()

    def test_strict_only_rule_and_new_violation(self):
        self.write('tools/deps/rules', RULES.replace('only runtime-alone', 'strict only runtime-alone'))
        self.passes()
        self.write('src/runtime/a.c', '#include "../common/x.h"\n')
        self.write('src/common/x.h', '#pragma once\n')
        self.fails('[runtime-alone]')
        before = self.read('tools/deps/baseline')
        self.assertEqual(self.deps('baseline', '--write').returncode, 1)
        self.assertEqual(self.read('tools/deps/baseline'), before)

    def graph_file(self, name, layers, edges):
        self.write(name, json.dumps(dict(schema=1, files=[dict(path=p, layer=l) for p, l in layers.items()],
                                        edges=[dict(source=a, target=b, kind='import') for a, b in edges])))
        return str(self.root/name)

    def test_diff_removed_relayered_added(self):
        a = self.graph_file('a.json', {'src/language/p.zig': 'language', 'src/model/value.zig': 'model',
                                      'src/model/hub.zig': 'model'},
                            [('src/language/p.zig', 'src/model/value.zig'), ('src/language/p.zig', 'src/model/hub.zig')])
        b = self.graph_file('b.json', {'src/language/p.zig': 'language', 'src/debug/value.zig': 'debug',
                                      'src/model/new.zig': 'model'},
                            [('src/language/p.zig', 'src/debug/value.zig'), ('src/language/p.zig', 'src/model/new.zig')])
        run = self.deps('diff', a, b, '--from-layer', 'language', '--to-layer', 'model', '--json')
        self.assertEqual(run.returncode, 0, run.stderr)
        result = json.loads(run.stdout)
        self.assertEqual((result['before'], result['after']), (2, 1))
        self.assertEqual(result['removed'], [['src/language/p.zig', 'src/model/hub.zig']])
        self.assertEqual(result['added'], [['src/language/p.zig', 'src/model/new.zig']])
        self.assertEqual(len(result['relayered']), 1)
        self.assertEqual(result['inferred_moves'], {'src/model/value.zig': 'src/debug/value.zig'})
        self.assertEqual(result['relayered'][0]['layers_after'], ['language', 'debug'])
        self.assertIn('removed=1 re-layered=1 added=1', self.deps('diff', a, b).stdout)
        reverse = json.loads(self.deps('diff', b, a, '--to-layer', 'model', '--json').stdout)
        self.assertEqual((len(reverse['removed']), len(reverse['relayered']), len(reverse['added'])), (1, 1, 1))
        # Planted wrong layer: a move within model must not count as re-layering.
        value = json.loads(self.read('b.json'))
        value['files'][1]['layer'] = 'model'
        self.write('b.json', json.dumps(value))
        wrong = json.loads(self.deps('diff', a, b, '--json').stdout)
        self.assertEqual(wrong['relayered'], [])
        self.assertEqual(wrong['unchanged'], 1)

    def test_diff_same_path_layer_change_and_ambiguous_moves(self):
        a = self.graph_file('a.json', {'src/p.zig': 'language', 'src/a/v.zig': 'model', 'src/b/v.zig': 'model'},
                            [('src/p.zig', 'src/a/v.zig'), ('src/p.zig', 'src/b/v.zig')])
        b = self.graph_file('b.json', {'src/p.zig': 'language', 'src/c/v.zig': 'debug'}, [('src/p.zig', 'src/c/v.zig')])
        result = json.loads(self.deps('diff', a, b, '--json').stdout)
        self.assertEqual(result['inferred_moves'], {})
        self.assertEqual(len(result['ambiguous_moves']), 1)
        self.assertEqual((len(result['removed']), len(result['added'])), (2, 1))
        value = json.loads(self.read('a.json'))
        value['files'][1]['layer'] = 'debug'
        self.write('b.json', json.dumps(value))
        result = json.loads(self.deps('diff', a, b, '--json').stdout)
        self.assertEqual((len(result['relayered']), result['unchanged']), (1, 1))

    def test_diff_directory_json_and_bad_input(self):
        self.write('graph.json', self.deps('graph', '--json').stdout)
        run = self.deps('diff', str(self.root), str(self.root/'graph.json'), '--json')
        self.assertEqual(run.returncode, 0, run.stderr)
        result = json.loads(run.stdout)
        self.assertEqual((result['before'], result['after'], result['unchanged']), (6, 6, 6))
        self.assertEqual(result['removed'] + result['relayered'] + result['added'], [])
        self.assertEqual(self.deps('diff', str(self.root), str(self.root), '--to-layer', 'typo').returncode, 2)
        self.write('bad.json', '{bad')
        self.assertEqual(self.deps('diff', str(self.root/'bad.json'), str(self.root)).returncode, 2)


if __name__ == '__main__':
    unittest.main()
