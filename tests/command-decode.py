"""Generated decoder freshness and schema-change negative controls (no target)."""
import copy
import json
from pathlib import Path
import runpy

root = Path(__file__).resolve().parents[1]
generator = runpy.run_path(str(root / 'scripts/gen-command-decode'))
catalog = json.loads((root / 'src/mcp/base_tools.json').read_text())
generate = generator['generate']
expected = generate(catalog)
assert expected == (root / 'src/mcp/command_decode.zig').read_text(), 'stale generated decoder'
changed = copy.deepcopy(catalog)
finish = next(t for t in changed if t['name'] == 'finish')['inputSchema']
finish['properties']['frame']['maximum'] = 7
finish['required'].append('frame')
mutant = generate(changed)
assert mutant != expected and 'v.integer > 7' in mutant, 'schema drift was invisible'
assert '@"frame": u64,' in mutant, 'required input was not generated'
finish['properties']['frame']['multipleOf'] = 2
try:
    generate(changed)
except AssertionError:
    pass
else:
    raise AssertionError('unsupported schema constraint silently ignored')
for mutate in (lambda s: s['required'].append('undeclared'),
               lambda s: s['properties'][next(k for k, v in s['properties'].items() if v['type'] == 'string')].update(minimum=1)):
    bad = copy.deepcopy(catalog)
    mutate(next(t for t in bad if t['name'] == 'run_to')['inputSchema'])
    try:
        generate(bad)
    except AssertionError:
        pass
    else:
        raise AssertionError('unsupported schema shape silently accepted')
print('command decoder: fresh; changed limits/required fields and unsupported constraints detected')
