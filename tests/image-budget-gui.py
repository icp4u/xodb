#!/usr/bin/env python3
"""An image over the full-image budget is named on the GUI status line, on a private compositor.
Run: python3 tests/image-budget-gui.py [PREFIX]
The image is a small shared object padded with a hole to just over the budget set on the command line."""
import importlib.util, os, subprocess, sys, time
from pathlib import Path
from PIL import Image, ImageOps
root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
spec = importlib.util.spec_from_file_location('input_repro', root/'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
work = root/'.work'/('input-budget-'+str(time.time_ns())[-10:]); work.mkdir()
h.WORK = str(work)
for name in ('tmp', 'cache', 'cache/mesa', 'cache/nvidia'): (work/name).mkdir(parents=True, exist_ok=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work/(stem+'.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work/(stem+'.c'))], check=True)
h.HELPER = str(work/'vinput')
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(work), str(root/'tests/helpers/vinput.c'), str(work/'virtual-pointer.c'), str(work/'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)
MIB = 1 << 20
(work/'big.c').write_text('__attribute__((noinline)) int big_wait(int n) { __asm__ volatile("" ::: "memory"); return n + 1; }\n')
(work/'main.c').write_text('int big_wait(int);\nint main(void) { return big_wait(1) != 2; }\n')
# A path longer than the 512 bytes a diagnostic shows: the line still names the file.
deep = work/('d' * 250)/('e' * 250); deep.mkdir(parents=True)
library = deep/'libbig.so'  # a short name: the line shows the file name, then size and budget
subprocess.run(['cc', '-g', '-O1', '-shared', '-fPIC', str(work/'big.c'), '-o', str(library)], check=True, timeout=60)
subprocess.run(['cc', '-g', '-O1', str(work/'main.c'), '-o', str(work/'main'), f'-L{deep}', '-lbig', f'-Wl,-rpath,{deep}'], check=True, timeout=60)
os.truncate(library, 65 * MIB)  # a hole, not data
tree = work/'tree'; tree.mkdir()
(tree/'zig-out').symlink_to(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out').resolve(), target_is_directory=True)
def check(kind):
    d = None
    try:
        d = h.Display(str(tree), ['--agent-scope', 'control', '--image-limit', '64M', '--break', 'big_wait', '--', str(work/'main')])
        d.keys('tap', 63); snap = d.stopped('breakpoint'); assert snap, d.tail()
        found = d.tool('get_stack', tid=snap['threads'][0]['tid'])
        notice = found['image_budget']
        subject = ' (decompressed debug data)' if kind == 'compressed' else ''
        assert len(str(library)) > 512 and notice == f'{str(library)[:509]}...{subject} is 65 MiB; image budget 64 MiB; rerun with --image-limit 100M or set symbols.image_bytes', found
        if kind == 'compressed':
            assert any(f['diagnostic'] == 'CompressedDebugBudget' for f in found['frames']), found
        wanted = lambda text: ('wrong budget' if '--wrong-result' in sys.argv else 'over budget') in text and 'libbig.so' in text and '65 mib' in text and 'budget 64 mib' in text and (kind != 'compressed' or 'decompressed debug data' in text)
        deadline = time.monotonic() + 20 * h.load_scale(); attempt = 0
        while True:
            shot = d.shot(f'{kind}-over-budget-{attempt}')
            with Image.open(shot) as image:
                strip = image.convert('L').crop((0, image.height - 30, image.width, image.height))
                ImageOps.invert(strip).resize((strip.width * 3, strip.height * 3)).save(shot + '.strip.png')
            text = ' '.join(h.ocr(shot + '.strip.png', '--psm', '7').lower().split())
            if wanted(text) or time.monotonic() > deadline: break
            attempt += 1; time.sleep(.1)
        assert wanted(text), text
        d.app.stdin.close(); assert d.app.wait(timeout=5) == 0
    finally:
        if d: d.close()
try:
    check('image')
    (work/'pad.s').write_text('.section .debug_ranges,"",@progbits\n.zero 67108864\n.section .note.GNU-stack,"",@progbits\n')
    subprocess.run(['cc', '-g', '-O1', '-shared', '-fPIC', str(work/'big.c'), str(work/'pad.s'), '-Wl,--compress-debug-sections=zlib', '-o', str(library)], check=True, timeout=60)
    check('compressed')
    print('Private GUI: status names image and decompressed-debug budget refusals:', work)
finally:
    library.unlink(missing_ok=True)
