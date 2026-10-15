"""Prove comparison fails on changed error/stop facts and incomplete output."""
import copy
from pathlib import Path
import runpy

module = runpy.run_path(str(Path(__file__).with_name('command-compare.py')))
compare = module['compare']
good = {'version': 1, 'rows': [[label, ['stopped', i]] for i, label in enumerate(module['LABELS'])]}
good['rows'][0][1] = ['error', 'GenerationRequired']
compare(good, copy.deepcopy(good))
bad = copy.deepcopy(good)
bad['rows'][0][1] = ['ok']
stop = copy.deepcopy(good)
stop['rows'][1][1] = ['running', 0]
for mutant in (bad, stop, {'version': 1, 'rows': []}, {'version': 1, 'rows': good['rows'][:-1]}):
    try:
        compare(good, mutant)
    except AssertionError:
        pass
    else:
        raise AssertionError('comparison accepted planted wrong result')
print('command comparison rejects changed errors, stops and incomplete transcripts')
