"""Cross-check presentation links against owned native/language reader evidence."""
import csv
import io
import re
import subprocess
import time
from pathlib import Path
from PIL import Image, ImageOps


def check_native_values(display, tid, language, label):
    generation = display.session()['generation']
    display.tool('select_native_frame', generation=generation, tid=tid, frame=0)
    display.tool('select_language_tab', generation=generation, tab=language)
    locals_ = display.tool('list_locals', tid=tid, frame=0)['locals']
    values = [v for v in locals_ if v['value'].get('visualization') and v['value']['visualization'].get(language)]
    assert values, (language, locals_)
    deadline = time.monotonic()+20
    while True:
        screenshot = display.shot(label+'-native-values')
        # OCR only this private pane. Inverting and enlarging the low-contrast
        # secondary text prevents whole-window segmentation from dropping it.
        crop = screenshot + '.native-ocr.png'
        with Image.open(screenshot) as image:
            pane = ImageOps.invert(image.crop((1013, 130, 1272, 578)).convert('L'))
            pane.resize((pane.width * 3, pane.height * 3)).save(crop)
        run = subprocess.run(['tesseract', crop, 'stdout', '--psm', '6'], env=dict(display.env, OMP_THREAD_LIMIT='1'), capture_output=True, text=True, timeout=30, check=True)
        text = run.stdout
        # Match the native section and a reader-derived name/value prefix, not
        # source-pane text. Value identity itself is checked by each fixture.
        normalize = lambda v: re.sub(r'[^a-z0-9]', '', v.lower())
        wanted = normalize(values[0]['value']['display'].split()[0])
        expected = 'NAMED LOCALS' if language in ('lua', 'perl', 'python') else 'Variables by name'
        if 'Native frame' in text and expected in text and wanted in normalize(text): break
        assert time.monotonic()<deadline, (values[0], text)
        time.sleep(.1)
    Path(screenshot+'.native-ocr.txt').write_text(text)
    return {'name':values[0]['name'], 'display':values[0]['value']['display'], 'count':len(values)}

def check(display, tid, language, label):
    deadline = time.monotonic() + 180
    while True:
        tabs = display.tool('get_language_tabs')['view']
        if any(t['tab'] == language and t['visible'] and t['status'] == 'ready' for t in tabs['tabs']):
            break
        assert time.monotonic() < deadline, tabs
        time.sleep(.03)
    native_values = check_native_values(display, tid, language, label)
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
    # Native browsing must not steal the C/C++ pane, including the real j/k
    # keyboard path. A proved offer stays available through the tab badge.
    for tab in ('native', 'registers'):
        display.tool('select_language_tab', generation=generation, tab=tab)
        same = display.tool('select_native_frame', generation=generation, tid=tid, frame=anchor['frame'])['view']
        assert same['selected'] == tab, same
        display.keys('tap', 36, 'tap', 37)
        assert display.tool('get_language_tabs')['view']['selected'] == tab
    display.tool('select_language_tab', generation=generation, tab='native')
    display.tool('select_native_frame', generation=generation, tid=tid, frame=anchor['frame'])
    display.shot(label+'-native-offer')
    return {'native_values':native_values, 'language':language, 'segment':segment_index, 'native_anchor':anchor, 'selected_frame':frame,
            'clicked_frame':0, 'basis':'reader_segment', 'registers_generation_unchanged':True}
