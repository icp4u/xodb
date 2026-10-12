#!/usr/bin/env python3
"""Periodic bounded ASan/UBSan LLDB stop and thread parser fuzzing."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
from helpers import orphans

ROOT=Path(__file__).resolve().parents[1]


def usage(pid):
    try:
        fields=Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()
        return dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),
                    rss_kib=int(fields[21])*os.sysconf('SC_PAGE_SIZE')//1024)
    except FileNotFoundError:return None


def main():
    os.umask(0o022);orphans.adopt()
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work',type=Path,required=True)
    parser.add_argument('--wrong-result',action='store_true')
    args=parser.parse_args();work=args.work.resolve();work.mkdir(parents=True)
    result=dict(status='running',load=os.getloadavg());started=time.monotonic()
    try:
        binary=work/'fuzz'
        with (work/'compile.log').open('w') as out:
            subprocess.run(['clang','-std=c11','-DNDEBUG','-O1','-g','-fsanitize=fuzzer,address,undefined',
                            '-fno-sanitize-recover=all','-Isrc/runtime','tests/fuzz-gdb-lldb.c',
                            'src/runtime/gdb_lldb.c','-o',str(binary)],stdout=out,stderr=subprocess.STDOUT,check=True,timeout=60)
        corpus=work/'corpus';corpus.mkdir()
        values=set()
        for path in sorted((ROOT/'tests/fixtures/macos-names/transcripts').glob('*.json')):
            for query,replies in json.loads(path.read_text())['exchanges']:
                if query.startswith(('qHostInfo','qProcessInfo','jThreadsInfo','jGetLoadedDynamicLibrariesInfos:','qMemoryRegionInfo:')):
                    values.update(replies)
                values.update(r for r in replies if r.startswith('T'))
        assert any('metype:1;' in v for v in values) and any('xf-worker-1' in v for v in values)
        for i,value in enumerate(sorted(values)):(corpus/str(i)).write_bytes(value.encode())
        result['seeds']=len(values)
        env=dict(os.environ)
        # Bound sanitizer quarantine, which otherwise dominates the parser's
        # tiny live heap during repeated exact-sized input copies.
        env['ASAN_OPTIONS']=env.get('ASAN_OPTIONS','')+':quarantine_size_mb=16:thread_local_quarantine_size_kb=64'
        if args.wrong_result:env['XODB_LLDB_FUZZ_WRONG_RESULT']='1'
        with (work/'fuzz.log').open('w') as out:
            child=subprocess.Popen([str(binary),str(corpus),'-max_total_time=10','-timeout=3','-max_len=1048576',
                                    '-rss_limit_mb=256','-seed=771','-artifact_prefix='+str(work)+'/'],
                                   stdout=out,stderr=subprocess.STDOUT,env=env)
            measurements=[];until=time.monotonic()+45
            try:
                while child.poll() is None:
                    row=usage(child.pid)
                    if row and row['rss_kib']:measurements.append(row)
                    assert time.monotonic()<until,'bounded fuzz deadline exceeded'
                    time.sleep(.02)
            finally:
                if child.poll() is None:child.kill()
                child.wait()
        result.update(exit_code=child.returncode,resources_before=measurements[0],resources_after=measurements[-1],
                      peak_rss_kib=max(row['rss_kib'] for row in measurements))
        assert child.returncode==0,child.returncode
        log=(work/'fuzz.log').read_text()
        assert 'DONE' in log and 'Done ' in log,log[-1000:]
        result['status']='pass'
    finally:
        assert orphans.reap(),'fuzzer helper still running'
        if result['status']=='running':result['status']='fail'
        result['seconds']=time.monotonic()-started
        (work/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))


if __name__=='__main__':main()
