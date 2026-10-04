#!/usr/bin/env python3
"""Run only on a private headless compositor; all artifacts stay in the repo."""
from datetime import datetime
import json
import os
import select
from pathlib import Path
import subprocess
import time
import sys

root = Path(__file__).resolve().parents[1]
os.chdir(root)
m1 = '--m1' in sys.argv
graph_mode = '--graph' in sys.argv
profile_mode = '--profile' in sys.argv
assert sum((m1,graph_mode,profile_mode)) <= 1, 'Select one fixture mode'
render_fault = '--render-fault' in sys.argv
glyph_stress = '--glyph-stress' in sys.argv
assert not (m1 and glyph_stress), 'Glyph stress uses the M0 fixture to keep its source view'
run = root / ".work" / ("gui-" + datetime.now().strftime("%Y%m%dT%H%M%S%f"))
run.mkdir(parents=True)
runtime = run / "runtime"
runtime.mkdir(mode=0o700)
for directory in ("tmp", "cache", "cache/nvidia", "cache/mesa"):
    (run / directory).mkdir(parents=True, exist_ok=True)
config = run / "sway.conf"
config.write_text("xwayland disable\noutput HEADLESS-1 mode 1280x800\noutput * bg #0b0f16 solid_color\ndefault_border none\nfocus_follows_mouse no\nseat seat0 hide_cursor 100\n")
env = os.environ.copy()
for key in ("DISPLAY", "WAYLAND_DISPLAY", "SWAYSOCK", "DBUS_SESSION_BUS_ADDRESS"):
    env.pop(key, None)
env.update(TMPDIR=str(run / "tmp"), XDG_CACHE_HOME=str(run / "cache"), MESA_SHADER_CACHE_DIR=str(run / "cache/mesa"), __GL_SHADER_DISK_CACHE_PATH=str(run / "cache/nvidia"), XDG_RUNTIME_DIR=str(runtime), WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1", WLR_LIBINPUT_NO_DEVICES="1")
# An optional explicit renderer is useful for isolated software comparison.
if os.environ.get("XODB_TEST_COMPOSITOR_RENDERER"):
    env["WLR_RENDERER"] = os.environ["XODB_TEST_COMPOSITOR_RENDERER"]
processes = []
try:
    with (run / "sway.log").open("wb") as log:
        sway = subprocess.Popen(["sway", "--unsupported-gpu", "--config", str(config)], env=env, stdout=log, stderr=subprocess.STDOUT)
    processes.append(sway)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        sockets = [p for p in runtime.glob("wayland-*") if not p.name.endswith(".lock")]
        ipc = list(runtime.glob("sway-ipc*.sock"))
        if sockets and ipc:
            break
        if sway.poll() is not None:
            raise RuntimeError((run / "sway.log").read_text())
        time.sleep(.05)
    else:
        raise TimeoutError("Private compositor did not start")
    env["WAYLAND_DISPLAY"] = sockets[0].name
    env["SWAYSOCK"] = str(ipc[0])
    env["XODB_TEST_PRIVATE_DISPLAY"] = "1"
    protocol = "/usr/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml"
    subprocess.run(["wayland-scanner", "client-header", protocol, str(run / "virtual-pointer.h")], check=True)
    subprocess.run(["wayland-scanner", "private-code", protocol, str(run / "virtual-pointer.c")], check=True)
    pointer = run / "private-pointer"
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", "-I", str(run), "tests/private-pointer.c", str(run / "virtual-pointer.c"), "-lwayland-client", "-lm", "-o", str(pointer)], env=env, check=True)
    app_env = dict(env)
    if render_fault:
        fault = run / 'render-fault.so'
        subprocess.run(['cc','-shared','-fPIC','-Wall','-Wextra','-Werror','tests/render-fault.c','-ldl','-o',str(fault)],env=env,check=True)
        app_env['LD_PRELOAD'] = str(fault)
    source_path = 'tests/fixtures/profile.c' if profile_mode else 'tests/fixtures/m2.c' if graph_mode else 'tests/fixtures/m1.c' if m1 else 'tests/fixtures/target.c'
    if glyph_stress:
        # Enumerate the installed font's charmap using FreeType, already required
        # by the app. Distinct supported glyphs must exceed its 2,048-slot cache.
        import ctypes as ct
        ft = ct.CDLL('libfreetype.so.6')
        library, face = ct.c_void_p(), ct.c_void_p()
        ft.FT_Init_FreeType.argtypes = [ct.POINTER(ct.c_void_p)]
        ft.FT_New_Face.argtypes = [ct.c_void_p,ct.c_char_p,ct.c_long,ct.POINTER(ct.c_void_p)]
        ft.FT_Get_First_Char.argtypes = [ct.c_void_p,ct.POINTER(ct.c_uint)]
        ft.FT_Get_First_Char.restype = ct.c_ulong
        ft.FT_Get_Next_Char.argtypes = [ct.c_void_p,ct.c_ulong,ct.POINTER(ct.c_uint)]
        ft.FT_Get_Next_Char.restype = ct.c_ulong
        ft.FT_Done_Face.argtypes = [ct.c_void_p]
        ft.FT_Done_FreeType.argtypes = [ct.c_void_p]
        assert ft.FT_Init_FreeType(ct.byref(library)) == 0
        try:
            assert ft.FT_New_Face(library,b'/usr/share/fonts/TTF/DejaVuSansMono.ttf',0,ct.byref(face)) == 0
            try:
                glyph = ct.c_uint()
                code = ft.FT_Get_First_Char(face,ct.byref(glyph))
                chars, ids = [], set()
                while glyph.value:
                    if code >= 32 and glyph.value not in ids:
                        ids.add(glyph.value)
                        chars.append(chr(code))
                    code = ft.FT_Get_Next_Char(face,code,ct.byref(glyph))
            finally: ft.FT_Done_Face(face)
        finally: ft.FT_Done_FreeType(library)
        assert len(ids) > 2048, len(ids)
        source_path = str(run / 'glyphs.txt')
        # Scrolling these rows fills the cache. Filler also exercises the
        # explicit source-size notice.
        Path(source_path).write_text('\n'.join(''.join(chars[i:i+40]) for i in range(0,len(chars),40)) + '\n' + 'padding\n' * 150000)
        print(f'Glyph stress: {len(ids)} distinct supported glyphs')
    with (run / "xodb.log").open("wb") as log:
        app = subprocess.Popen(["./zig-out/bin/xodb", "--mcp", "--record", str(run / "investigations.json"), "--source", source_path, "--", "./zig-out/bin/xodb-profile-fixture" if profile_mode else "./zig-out/bin/xodb-m2-fixture" if graph_mode else "./zig-out/bin/xodb-m1-fixture" if m1 else "./zig-out/bin/xodb-fixture"], env=app_env, bufsize=0, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
    processes.append(app)
    serial = 0
    notifications = []
    def request(method, params=None):
        global serial
        serial += 1
        msg = {"jsonrpc": "2.0", "id": serial, "method": method}
        if params is not None:
            msg["params"] = params
        app.stdin.write((json.dumps(msg) + "\n").encode())
        app.stdin.flush()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            ready, _, _ = select.select([app.stdout], [], [], max(0, deadline-time.monotonic()))
            assert ready, (run / "xodb.log").read_text()
            response = json.loads(app.stdout.readline())
            if 'id' not in response:
                notifications.append(response)
                continue
            assert response["id"] == serial
            return response["result"]
        raise AssertionError('Response timeout')
    def snapshot():
        return request("tools/call", {"name": "get_session", "arguments": {}})["structuredContent"]
    def ipc(*args):
        result = subprocess.run(["swaymsg", *args], env=env, check=True, capture_output=True, timeout=5)
        for reply in json.loads(result.stdout):
            assert reply.get("success"), reply
    def click(x, y):
        subprocess.run([str(pointer), str(x), str(y), "1280", "800"], env=env, check=True, timeout=5)
    def await_state(state, min_threads=1, reason=None, scope=None):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            snap = snapshot()
            if snap["state"] == state and len(snap["threads"]) >= min_threads and (reason is None or any(t["reason"]==reason for t in snap["threads"])) and (scope is None or snap["agent_scope"]==scope):
                return snap
            time.sleep(.02)
        raise AssertionError(f"Did not reach {state}: {snap}")
    request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "gui-test", "version": "1"}})
    app.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    app.stdin.flush()
    initial = await_state("stopped")
    target_pid = initial["pid"]
    if render_fault:
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            log_text = (run / 'xodb.log').read_text()
            if 'recreating renderer, target retained' in log_text and log_text.count('Vulkan device:') >= 2:
                break
            assert app.poll() is None, log_text
            time.sleep(.05)
        else: raise AssertionError('Renderer did not recover: ' + log_text)
        assert Path(f'/proc/{target_pid}').exists(), 'Render failure killed target'
        assert snapshot()['pid'] == target_pid and snapshot()['state'] == 'stopped'
    time.sleep(.3)
    assert app.poll() is None, (run / "xodb.log").read_text()
    subprocess.run(["grim", "-o", "HEADLESS-1", str(run / "workspace.png")], env=env, check=True, timeout=5)
    if glyph_stress:
        for _ in range((len(chars) // 40) // 12 + 2):
            subprocess.run([str(pointer),'300','300','1280','800','60'],env=env,check=True,timeout=5)
            assert app.poll() is None, (run / 'xodb.log').read_text()
        assert 'Text rendering degraded: GlyphCacheFull' in (run / 'xodb.log').read_text()
        assert Path(f'/proc/{target_pid}').exists(), 'Glyph exhaustion killed target'
        subprocess.run(['grim','-o','HEADLESS-1',str(run/'glyph-overflow.png')],env=env,check=True,timeout=5)
    if profile_mode:
        def tool(name, **args):
            result=request('tools/call',{'name':name,'arguments':args})
            assert not result['isError'],result
            return result['structuredContent']
        click(700,65)
        await_state('stopped',scope='control')
        bp=tool('set_breakpoint',symbol='profile_ready',generation=snapshot()['generation'])['id']
        click(90,65)
        stopped=await_state('stopped',reason='breakpoint')
        tool('remove_breakpoint',id=bp,generation=snapshot()['generation'])
        click(450,22)  # F: open flame workspace
        time.sleep(.2)
        subprocess.run(['grim','-o','HEADLESS-1',str(run/'flame-empty.png')],env=env,check=True,timeout=5)
        click(290,110) # P: begin from stopped state, via the human UI
        opened=tool('get_profile')['capture']
        assert opened['status']=='collecting'
        click(90,65)
        await_state('running')
        time.sleep(.9)
        subprocess.run(['grim','-o','HEADLESS-1',str(run/'flame-live.png')],env=env,check=True,timeout=5)
        click(290,110) # stop perf while target continues
        capture=tool('get_profile')['capture']
        assert capture['status']=='manual' and capture['stored_samples']>20,capture
        assert snapshot()['state']=='running'
        click(90,65)
        stopped=await_state('stopped')
        tid=stopped['threads'][0]['tid']
        before=tool('get_registers',tid=tid)['registers']
        deadline=time.monotonic()+10
        while True:
            graph=tool('get_flamegraph',capture_id=capture['id'],revision=capture['revision'])
            if not graph.get('pending'): break
            assert time.monotonic()<deadline, graph
            time.sleep(.01)
        node=next(n for n in graph['nodes'] if n['name']=='hot_hash')
        # Geometry is expressed in sample units; locate the saved graph's frame.
        view_x,view_w,view_bottom=18,1244,351  # flames above the timeline: 91+111+(round(800*0.64)-96-267)
        x=view_x+(node['x']+node['inclusive']/2)/graph['samples']*view_w
        y=view_bottom-(node['depth']+1)*24+11
        click(round(x),round(y))
        time.sleep(.2)
        subprocess.run(['grim','-o','HEADLESS-1',str(run/'flame-selected.png')],env=env,check=True,timeout=5)
        click(440,110) # Z: selected frame zoom
        time.sleep(.2)
        subprocess.run(['grim','-o','HEADLESS-1',str(run/'flame-zoom.png')],env=env,check=True,timeout=5)
        click(815,110) # Enter: browse source/assembly
        time.sleep(.2)
        assert snapshot()['generation']==stopped['generation']
        assert tool('get_registers',tid=tid)['registers']==before
        subprocess.run(['grim','-o','HEADLESS-1',str(run/'flame-source.png')],env=env,check=True,timeout=5)
        click(450,22)
        (run/'flames.json').write_text(json.dumps(dict(capture=capture,graph=graph,selected=node),indent=2)+'\n')
    elif graph_mode:
        def tool(name, **args):
            result = request('tools/call', {'name':name,'arguments':args})
            assert not result['isError'], result
            return result['structuredContent']
        click(700,65)
        await_state('stopped',scope='control')
        tool('set_breakpoint',symbol='flow_fixture',generation=snapshot()['generation'])
        click(90,65)
        stopped = await_state('stopped',reason='breakpoint')
        tid = stopped['threads'][0]['tid']
        before = tool('get_registers',tid=tid)['registers']
        graph = tool('get_function_graph',symbol='flow_fixture',limit=16)
        assert graph['total_blocks']>=3
        click(1135,65)  # Flow G
        time.sleep(.3)
        subprocess.run(['grim','-o','HEADLESS-1',str(run/'flow.png')],env=env,check=True,timeout=5)
        click(740,322)  # Second block in the initial graph viewport
        time.sleep(.2)
        assert tool('get_registers',tid=tid)['registers']==before, 'Graph browsing changed registers'
        assert snapshot()['generation']==stopped['generation'], 'Graph browsing changed target generation'
        subprocess.run(['grim','-o','HEADLESS-1',str(run/'flow-browse.png')],env=env,check=True,timeout=5)
        click(1135,65)  # Assembly at the selected block
        time.sleep(.2)
        subprocess.run(['grim','-o','HEADLESS-1',str(run/'flow-assembly.png')],env=env,check=True,timeout=5)
        assert tool('get_registers',tid=tid)['registers']==before
        click(1135,65)  # Return to graph before resize coverage
        subprocess.run([str(pointer),'750','300','1280','800','60'],env=env,check=True,timeout=5)
        time.sleep(.2)
        subprocess.run(['grim','-o','HEADLESS-1',str(run/'flow-scrolled.png')],env=env,check=True,timeout=5)
        (run/'flow.json').write_text(json.dumps(graph,indent=2)+'\n')
    elif m1:
        def tool(tool_name, **args):
            result = request('tools/call', {'name':tool_name,'arguments':args})
            assert not result['isError'], result
            return result['structuredContent']
        def action(tool_name, **args): return tool(tool_name, generation=snapshot()['generation'], **args)
        assert initial['agent_scope']=='observe'
        click(700,65)
        await_state('stopped',scope='control')
        bp = action('set_breakpoint',symbol='change_value')['id']
        state = tool('find_symbol',name='state')
        click(90,65)
        stopped = await_state('stopped',reason='breakpoint')
        tid = stopped['threads'][0]['tid']
        before = tool('get_registers',tid=tid)['registers']['rip']
        click(420,65)
        await_state('stopped',reason='single_step')
        assert tool('get_registers',tid=tid)['registers']['rip'] != before
        action('remove_breakpoint',id=bp)
        click(1130,195)  # expanded item->value field
        click(990,65)    # W watch toolbar action
        watchpoints = tool('get_breakpoints')['watchpoints']
        assert any(w is not None and w['address']==int(state['address'],16) for w in watchpoints), watchpoints
        click(90,65)
        await_state('stopped',reason='watchpoint')
        hit = [e for e in tool('query_events')['events'] if e['kind']=='watchpoint_hit'][-1]
        assert (hit['before'],hit['after'])==(7,12)
        assert tool('get_investigation',id=1)['observations'][0]['value']['display']=='12'
        click(700,65)
        snap = await_state('stopped',scope='observe')
        assert 'continue' not in {t['name'] for t in request('tools/list')['tools']}
        denied = request('tools/call',{'name':'continue','arguments':{'generation':snap['generation']}})
        assert denied['isError'] and denied['content'][0]['text']=='AgentScopeDenied'
        assert len([n for n in notifications if n['method']=='notifications/tools/list_changed'])==2
        assert snap['session_id']==initial['session_id']
        time.sleep(.1)
        subprocess.run(['grim','-o','HEADLESS-1',str(run/'watchpoint.png')],env=env,check=True,timeout=5)
    else:
        # Drive the GUI while the external read-only client observes the same session.
        click(90, 65)
        running = await_state("running", 2)
        assert running["session_id"] == initial["session_id"]
        click(90, 65)
        stopped = await_state("stopped", 2)
        assert stopped["generation"] > initial["generation"]
        for thread in stopped["threads"]:
            result = request("tools/call", {"name": "get_registers", "arguments": {"tid": thread["tid"], "generation": stopped["generation"]}})
            assert not result["isError"]
        subprocess.run(["grim", "-o", "HEADLESS-1", str(run / "paused.png")], env=env, check=True, timeout=5)
    # Resize the private output and require the application to survive recreation.
    for size in ('720x480','500x360','2560x1440','1440x900'):
        subprocess.run(["swaymsg", "output", "HEADLESS-1", "mode", size], env=env, check=True, capture_output=True, timeout=5)
        time.sleep(.15)
    time.sleep(.5)
    assert app.poll() is None, (run / "xodb.log").read_text()
    subprocess.run(["grim", "-o", "HEADLESS-1", str(run / "resized.png")], env=env, check=True, timeout=5)
    subprocess.run(["swaymsg", '[app_id="xodb"]', "kill"], env=env, check=True, capture_output=True, timeout=5)
    assert app.wait(timeout=5) == 0, (run / "xodb.log").read_text()
    assert not Path(f"/proc/{target_pid}").exists(), "Owned target survived window close"
    if m1:
        assert json.loads((run/'investigations.json').read_text())['investigations'][0]['observations'][0]['value']['display']=='12'
    print((run / "xodb.log").read_text())
    print(f"GUI {'M2 flames' if profile_mode else 'M2 flow' if graph_mode else 'M1 control' if m1 else 'M0'} smoke passed: shared session, execution controls, inspection, resize and cleanup. Artifacts: {run}")
finally:
    for proc in reversed(processes):
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
