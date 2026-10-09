"""Distinguish an unbound text field from an editor bound to a logical frame."""
import json
import re
import subprocess
import time
from pathlib import Path
from PIL import Image, ImageOps


def check(display, tid, language, caller, callee, expression, expected):
    generation = display.session()['generation']
    registers = display.tool('get_registers', tid=tid)
    events = []

    def view(label):
        state = display.tool('get_language_tabs')['view']
        events.append({'label': label, 'view': state})
        return state

    def select(frame):
        display.tool('select_language_frame', generation=generation, tid=tid,
                     language=language, segment=0, frame=frame)
        state = view('select-' + str(frame))
        assert state['selected'] == language and state['logical_selection']['frame'] == frame, state

    def visible(label, wanted):
        deadline = time.monotonic() + 20
        while True:
            shot = display.shot(language + '-editor-' + label)
            crop = shot + '.crop.png'
            with Image.open(shot) as image:
                pane = ImageOps.invert(image.crop((1013, 130, 1272, 578)).convert('L'))
                pane.resize((pane.width * 3, pane.height * 3)).save(crop)
            text = subprocess.run(['tesseract', crop, 'stdout', '--psm', '11'],
                                  env=dict(display.env, OMP_THREAD_LIMIT='1'), capture_output=True,
                                  text=True, check=True, timeout=30).stdout
            Path(shot + '.txt').write_text(text)
            normalize = lambda s: re.sub(r'[^a-z0-9]', '', s.lower())
            if normalize(wanted) in normalize(text):
                return
            assert time.monotonic() < deadline, (label, wanted, text)
            time.sleep(.03)

    try:
        # A bound editor closes when another client changes the tab.
        select(caller)
        display.keys('tap', 18)
        display.tool('select_language_tab', generation=generation, tab='native')
        assert view('native')['logical_selection'] is None
        display.keys('tap', 15)
        assert view('back-to-language')['selected'] == language

        # Returning to the language tab did NOT restore its logical selection.
        # Select a frame explicitly before testing a bound-editor frame change.
        assert view('unselected')['logical_selection'] is None
        select(caller)
        display.keys('tap', 18)
        select(callee)
        display.keys('tap', 15)
        assert view('bound-frame-change')['selected'] == 'registers'

        # E without a selection must capture text and Tab. Its first selected
        # frame binds the existing text; this is not a bound-frame change.
        display.tool('select_language_tab', generation=generation, tab=language)
        assert view('pending-before-E')['logical_selection'] is None
        display.keys('tap', 18, 'tap', 19, 'tap', 24, 'tap', 22, 'tap', 49, 'tap', 32)
        visible('pending-text', 'round')
        display.keys('tap', 15)
        assert view('pending-tab')['selected'] == language
        select(callee)
        display.keys('tap', 15)
        assert view('first-frame-binds')['selected'] == language
        visible('bound-text', 'round')
        # Ctrl+U replaces the retained text; submit a known read-only value.
        display.keys('down', 29, 'tap', 22, 'up', 29, *expression, 'tap', 28)
        visible('submitted', expected)
        display.keys('tap', 15)
        assert view('submitted-tab')['selected'] == 'registers'

        # Esc explicitly releases an unbound editor as well.
        display.tool('select_language_tab', generation=generation, tab=language)
        assert view('cancel-before-E')['logical_selection'] is None
        display.keys('tap', 18, 'tap', 1, 'tap', 15)
        assert view('cancel-tab')['selected'] == 'registers'
        assert display.session()['generation'] == generation
        assert display.tool('get_registers', tid=tid) == registers
        return {'status': 'pass', 'events': events, 'generation_registers_unchanged': True}
    finally:
        # Preserve the preconditions even if a keyboard assertion fails.
        Path(display.dir, language + '-editor-context.json').write_text(json.dumps(events, indent=2) + '\n')
