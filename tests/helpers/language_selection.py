"""Cross-check presentation links against owned native/language reader evidence."""
import csv
import io
import re
import subprocess
import time
from pathlib import Path


def check(display, tid, language, label):
    deadline = time.monotonic() + 180
    while True:
        tabs = display.tool('get_language_tabs')['view']
        if any(t['tab'] == language and t['visible'] and t['status'] == 'ready' for t in tabs['tabs']):
            break
        assert time.monotonic() < deadline, tabs
        time.sleep(.03)
    generation = display.session()['generation']
    registers = display.tool('get_registers', tid=tid)
    stack = display.tool('get_language_stack', tid=tid, language=language)
    native = display.tool('get_stack', tid=tid)['frames']
    segment_index, segment = next((i, s) for i, s in enumerate(stack['segments']) if s['frames'] and s['anchor'])
    anchor = segment['anchor']
    pc = anchor['pc'] if isinstance(anchor['pc'], int) else int(anchor['pc'], 16)
    assert native[anchor['frame']]['pc'] == pc
    frame = min(1, len(segment['frames']) - 1)
    selected = display.tool('select_language_frame', generation=generation, tid=tid,
                            language=language, segment=segment_index, frame=frame)['view']
    row = selected['logical_selection']
    assert row['segment'] == segment_index and row['frame'] == frame and row['language'] == language, row
    assert row['anchor_basis'] == 'reader_segment' and row['native_anchor'] == anchor['frame'], row
    assert row['native_pc'] == pc and selected['native_selection']['frame'] == anchor['frame'], selected
    offered = display.tool('select_native_frame', generation=generation, tid=tid, frame=anchor['frame'])['view']
    assert any(o['language'] == language and o['segment'] == segment_index for o in offered['offers']['items']), offered
    # Keep the GUI on this language; several segments at one native frame are
    # explicit choices rather than an inferred logical activation.
    display.tool('select_language_frame', generation=generation, tid=tid,
                 language=language, segment=segment_index, frame=frame)
    expected_name = segment['frames'][0]['name']
    normalize = lambda text: re.sub(r'[^a-z0-9]', '', text.lower())
    needle = normalize(expected_name)
    assert len(needle) >= 3, ('choose a readable owned fixture frame', expected_name)
    deadline = time.monotonic() + 20
    while True:
        time.sleep(.15)
        screenshot = display.shot(label+'-selected')
        completed = subprocess.run(['tesseract', screenshot, 'stdout', '--psm', '11', 'tsv'],
                                   env=dict(display.env, OMP_THREAD_LIMIT='1'), capture_output=True,
                                   text=True, timeout=60, check=True)
        Path(screenshot+'.tsv').write_text(completed.stdout)
        # OCR may split an underscore-qualified name into several words.
        # Match the whole rendered line, retaining its actual click bounds.
        lines = {}
        for word in csv.DictReader(io.StringIO(completed.stdout), delimiter='\t'):
            if int(word['left']) < 1013 or not word['text'].strip():
                continue
            key = tuple(word[k] for k in ('page_num', 'block_num', 'par_num', 'line_num'))
            lines.setdefault(key, []).append(word)
        matches = []
        for words in lines.values():
            words.sort(key=lambda word: int(word['left']))
            if normalize(''.join(word['text'] for word in words)) != needle:
                continue
            left = min(int(word['left']) for word in words)
            top = min(int(word['top']) for word in words)
            matches.append({'left':left, 'top':top,
                            'width':max(int(word['left'])+int(word['width']) for word in words)-left,
                            'height':max(int(word['top'])+int(word['height']) for word in words)-top})
        if matches:
            hit = matches[0]
            display.keys('click', int(hit['left'])+max(1,int(hit['width'])//2),
                         int(hit['top'])+max(1,int(hit['height'])//2))
            actual = display.tool('get_language_tabs')['view']['logical_selection']
            if actual and actual['language'] == language and actual['segment'] == segment_index and actual['frame'] == 0:
                break
        assert time.monotonic() < deadline, (expected_name, matches, display.tool('get_language_tabs'))
    display.shot(label+'-clicked')
    assert display.tool('get_registers', tid=tid) == registers
    assert display.session()['generation'] == generation
    display.tool('select_language_tab', generation=generation, tab='native')
    return {'language':language, 'segment':segment_index, 'native_anchor':anchor, 'selected_frame':frame,
            'clicked_frame':0, 'basis':'reader_segment', 'registers_generation_unchanged':True}
