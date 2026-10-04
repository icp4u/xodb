#!/usr/bin/env python3
"""Private desktop GUI checks for the JNI demo; optional reviewed Pixel session."""
import argparse
import importlib.util
import json
from pathlib import Path
import runpy
import socket
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--demo", type=Path, required=True)
    parser.add_argument("--server", type=Path, default=ROOT / "zig-out/bin/xodb")
    parser.add_argument("--fixture", type=Path, help="Owned host fixture from check.py")
    parser.add_argument("--device", action="store_true")
    parser.add_argument("--execute-reviewed-plan", action="store_true")
    args = parser.parse_args()
    if args.device and not args.execute_reviewed_plan:
        parser.error("Device writes require docs/ANDROID_APP_PLAN.md review and --execute-reviewed-plan")
    if not args.device and not args.fixture:
        parser.error("Host check needs --fixture")
    spec = importlib.util.spec_from_file_location("display", ROOT / "tests/helpers/display.py")
    helper = importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
    display = helper.Display("jni-gui")
    run = Path(display.dir)
    processes, sockets, transcript, failures = [], [], [], []
    latest, requests, lock = None, {}, threading.Lock()
    device = None
    forwarded_signals = set()
    def wait(predicate, advance_signals=False):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if failures: raise AssertionError(failures)
            with lock:
                view = latest
            if view is not None and predicate(view):
                time.sleep(.2)  # Let the GUI consume and paint the observed reply.
                return view
            if args.device and advance_signals and view and view["state"] == "stopped" and any(t["reason"] == "signal" for t in view["threads"]) and view["generation"] not in forwarded_signals:
                # Exercise ordinary GUI Continue for the fixture's handled ART
                # signals; record the stop and never suppress signal delivery.
                assert len(forwarded_signals) < 3, view
                forwarded_signals.add(view["generation"])
                display.shot("runtime-signal-" + str(len(forwarded_signals)))
                click(90,64)
            time.sleep(.02)
        raise AssertionError((latest, run))
    def click(x,y): display.pointer("click",x,y);time.sleep(.1)
    def site(v): return v["frames"][0].get("source") if v.get("frames") else None
    def symbol(v): return v["frames"][0].get("symbol") if v.get("frames") else None
    def relay(src,dst,direction):
        nonlocal latest
        pending = b""
        try:
            while data := src.recv(65536):
                dst.sendall(data);pending += data
                while b"\n" in pending:
                    line,pending = pending.split(b"\n",1);message=json.loads(line)
                    with lock:
                        transcript.append(dict(direction=direction,message=message))
                        if direction=="request" and "id" in message: requests[message["id"]]=message
                        request=requests.get(message.get("id"),{})
                        params=request.get("params",{})
                        if direction=="response" and params.get("name")=="get_debug_view" and not params.get("arguments",{}).get("summary_only"):
                            view=message.get("result",{}).get("structuredContent")
                            if view:latest=view
        except OSError: pass
        except Exception as exc: failures.append(str(exc))
        finally:
            try:dst.shutdown(socket.SHUT_WR)
            except OSError:pass
    try:
        if args.device:
            AppDemo=runpy.run_path(str(ROOT/"scripts/demo-android-app"))["AppDemo"]
            device=AppDemo(args.server,args.demo,90);device.start();device.identity()
            port=device.port
        else:
            with socket.socket() as s:s.bind(("127.0.0.1",0));port=s.getsockname()[1]
            with (run/"server.log").open("wb") as log:
                server=subprocess.Popen([str(args.server.resolve()),"--headless","--mcp","--listen",f"127.0.0.1:{port}",
                    "--agent-scope","control","--source",str(args.demo.resolve()/"xodb_demo.c"),"--break","main","--",str(args.fixture.resolve())],stdout=log,stderr=log)
            processes.append(server)
            deadline=time.monotonic()+5
            while "listening on" not in (run/"server.log").read_text():
                assert server.poll() is None and time.monotonic()<deadline
                time.sleep(.02)
        listener=socket.socket();listener.bind(("127.0.0.1",0));listener.listen(1);sockets.append(listener)
        def proxy():
            client,_=listener.accept();upstream=socket.create_connection(("127.0.0.1",port));sockets.extend([client,upstream])
            sender=threading.Thread(target=relay,args=(client,upstream,"request"),daemon=True);sender.start()
            relay(upstream,client,"response");sender.join(2)
        threading.Thread(target=proxy,daemon=True).start()
        with (run/"gui.log").open("wb") as log:
            gui=subprocess.Popen([str(ROOT/"zig-out/bin/xodb"),"--connect",f"127.0.0.1:{listener.getsockname()[1]}"],env=display.env,stdout=log,stderr=log)
        processes.append(gui)
        initial=wait(lambda v:v["state"]=="stopped");time.sleep(.3)
        if args.device:
            click(20,600)  # Explicitly inspect the main thread before Continue.
            time.sleep(.3)
        click(90,64)
        first=wait(lambda v:v["generation"]>initial["generation"] and symbol(v)==("xodb_demo_tick" if args.device else "main"), advance_signals=True)
        if args.device:
            assert first["tid"] != first["pid"], "GUI must follow the stopped JNI worker"
        line=next(i for i,t in enumerate((args.demo/"xodb_demo.c").read_text().splitlines(),1) if "XODB_WATCH_WRITE" in t)
        def probe(v):return any((p.get("source") or {}).get("line")==line for p in v["breakpoints"])
        # Host main is in a different source; the shared JNI source starts at row 0.
        scroll=max(0,site(first)["line"]-6) if args.device and site(first) else 0
        if args.device:
            entry_line=site(first)["line"]
            entry_ids={p["id"] for p in first["breakpoints"] if p["address"]==first["frames"][0]["pc"]}
            click(20,132+(entry_line-1-scroll)*23+8)
            wait(lambda v: not any(p["id"] in entry_ids for p in v["breakpoints"]))
        click(20,132+(line-1-scroll)*23+8);wait(probe)
        click(90,64)
        at_line=wait(lambda v:symbol(v)=="xodb_demo_tick" and site(v) and site(v)["line"]==line, advance_signals=True)
        values={v["name"]:v for v in at_line["locals"]};before=int(values["value"]["display"])
        assert int(values["amount"]["display"])==5 and int(values["next"]["display"])==before+5,values
        display.shot("01-source-locals")
        index=next(i for i,v in enumerate(at_line["locals"]) if v["name"]=="value")
        click(1010,132+46*index+8);click(999,64)
        armed=wait(lambda v:len(v["watchpoints"])==1)
        click(20,132+(line-1-max(0,line-6))*23+8);wait(lambda v:not probe(v))
        click(90,64)
        hit=wait(lambda v:any(h["before"]==before and h["after"]==before+5 for h in v.get("watch_hits",[])), advance_signals=True)
        assert hit["watch_hits"][0]["phase"]==("completed" if args.device else "after_access")
        display.shot("02-hardware-write")
        click(1130,64);time.sleep(.1);display.shot("03-watch-list")
        click(1020,140);click(999,64);wait(lambda v:not v["watchpoints"])
        click(1130,64)
        old=site(hit)["line"];click(250,64)
        stepped=wait(lambda v:v["generation"]>hit["generation"] and site(v) and site(v)["line"]!=old)
        click(845,64);display.shot("04-registers")
        # Close the GUI with the target stopped; service EOF must restore probes/detach.
        gui.terminate();assert gui.wait(timeout=8)==0
        if device:device.close()
        else:assert server.wait(timeout=8)==0
        result=dict(architecture=hit["architecture"],initial_value=before,hit=hit["watch_hits"][0],
                    source_line=site(stepped)["line"],forwarded_signal_generations=sorted(forwarded_signals),checks="GUI source gutter, locals, hardware watch create/hit/remove, source step, registers, EOF cleanup")
        (run/"results.json").write_text(json.dumps(result,indent=2)+"\n")
        print(json.dumps(result,indent=2));print(run)
    finally:
        (run/"transcript.json").write_text(json.dumps(transcript,indent=2)+"\n")
        for s in sockets:
            try:s.close()
            except OSError:pass
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:process.kill();process.wait()
        if device:device.close()
        display.close()


if __name__=="__main__":main()
