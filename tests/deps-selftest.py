#!/usr/bin/env python3
"""scripts/deps on a small fake tree: each kind of failure, and the clean case."""
from pathlib import Path
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


if __name__ == '__main__':
    unittest.main()
