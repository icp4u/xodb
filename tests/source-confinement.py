#!/usr/bin/env python3
"""Source path boundaries on owned files; no actual secrets or system reads."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--agent', type=Path, required=True)
p.add_argument('--library', type=Path, required=True)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--sanitize', action='store_true')
p.add_argument('--skip-kernel-filter', action='store_true', help='Remote SSH agent: a local filter cannot affect the remote kernel')
a = p.parse_args()
os.umask(0o022)
root = Path(__file__).resolve().parents[1]
work = a.work.resolve()
work.mkdir(parents=True, exist_ok=True, mode=0o755)
exe = work / 'check'
flags = ['-O1', '-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if a.sanitize else ['-O2']
subprocess.run(['clang' if a.sanitize else 'cc', '-g', '-std=c11', *flags,
    '-Wall', '-Wextra', '-Werror', '-I' + str(root / 'src/runtime'),
    str(root / 'tests/source-confinement.c'), str(a.library.resolve()), '-latomic', '-pthread',
    '-o', str(exe)], check=True, timeout=60)
(work / 'fake-home/.ssh').mkdir(parents=True, mode=0o700)
(work / 'fake-home/.ssh/id_test').write_text('owned synthetic canary\n')
(work / 'source.c').write_text('owned source text\n')
(work / 'empty.c').write_bytes(b'')
(work / 'outside.c').write_text('owned explicitly named outside-tree source\n')
(work / 'subdir').mkdir()
(work / 'link.c').symlink_to(work / 'fake-home/.ssh/id_test')
(work / 'linked-dir').symlink_to(work / 'fake-home/.ssh', target_is_directory=True)
os.mkfifo(work / 'pipe.c', 0o600)
cases = [
    ('ready', str(work / 'source.c')),
    ('ready', str(work / 'empty.c')),
    ('ready', str(work / 'outside.c')),
    ('unsafe', '/proc/self/cwd/fake-home/.ssh/id_test'),
    ('unsafe', '/proc/self/exe'),
    ('unsafe', '/proc/self/environ'),
    ('unsafe', '/proc/self/fd/0'),
    ('unsafe', '//proc/./self/maps'),
    ('unsafe', '/./sys/kernel/uevent_seqnum'),
    ('unsafe', '/dev/null'),
    ('unsafe', '/dev/zero'),
    ('unsafe', str(work / 'link.c')),
    ('unsafe', str(work / 'linked-dir/id_test')),
    ('ready', str(work) + '/subdir/../outside.c'),
    ('ready', str(work) + '/subdir/./../source.c'),
    ('unsafe', str(work) + '/subdir/../link.c'),
    ('unsafe', str(work) + '/subdir/../linked-dir/id_test'),
    ('unsafe', '/unused/../proc/self/exe'),
    ('unsafe', '/unused/../sys/kernel/uevent_seqnum'),
    ('unsafe', '/unused/../dev/null'),
    ('unavailable', str(work / 'pipe.c')),
    ('unavailable', str(work / 'missing.c')),
    ('ready', str(work / 'source.c')),
]
fixture = work / 'fixture.c'
source = ''.join('#line 1 ' + json.dumps(path) + '\nint f' + str(i) + '(void){return 0;}\n'
                 for i, (_, path) in enumerate(cases[:-1]))
source += '#line 1 "main.c"\nint main(void){return 0;}\n'
fixture.write_text(source)
(work / 'not-listed.c').write_text('owned unlisted source\n')
cases += [('unsafe', '/../' + str(work).lstrip('/') + '/source.c'),
          ('unsafe', '/unused/../../' + str(work).lstrip('/') + '/source.c'),
          ('not-listed', str(work / 'not-listed.c')),
          ('not-listed', str(work) + '/subdir/../not-listed.c')]
rows = []


def run(name, agent, image, requests):
    file = work / (name + '.requests')
    file.write_text(''.join(reason + '\t' + path + '\n' for reason, path in requests))
    result = subprocess.run([str(exe), str(agent), str(image), str(file)], cwd=work,
                            capture_output=True, text=True, timeout=60)
    (work / (name + '.log')).write_text(result.stdout + result.stderr)
    assert result.returncode == 0, (name, result.returncode, result.stdout, result.stderr)
    rows.append({'name': name, 'status': 'pass', 'checks': len(requests), 'stdout': result.stdout})


for version in (4, 5):
    image = work / ('fixture' + str(version))
    subprocess.run(['cc', '-g', '-gdwarf-' + str(version), '-O0', '-Wl,--build-id=sha1',
                    str(fixture), '-o', str(image)], check=True, timeout=30)
    run('dwarf-' + str(version), a.agent.resolve(), image, cases)
# Compiler output from a real out-of-tree build, not forged #line directives.
project = work / 'out-of-tree'
for name in ['build', 'src', 'include']:
    (project / name).mkdir(parents=True, exist_ok=True)
(project / 'src/main.c').write_text('#include "../include/value.h"\nint main(void){return value();}\n')
(project / 'include/value.h').write_text('static int value(void){return 0;}\n')
for compiler in ['gcc', 'clang']:
    for version in [4, 5]:
        image = project / 'build' / f'{compiler}-{version}'
        subprocess.run([compiler, '-O0', f'-gdwarf-{version}', '-Wl,--build-id=sha1', '../src/main.c', '-o', image.name], cwd=image.parent, check=True, timeout=30)
        requests = [('ready', str(project / relative)) for relative in ['src/main.c', 'include/value.h']]
        requests += [('ready', str(image.parent) + '/../' + relative) for relative in ['src/main.c', 'include/value.h']]
        run('out-of-tree-' + image.name, a.agent.resolve(), image, requests)
# A filter confines only the owned child. Simulate an older kernel refusing
# openat2, and prove that the agent never silently falls back to open().
filter_source = work / 'without-openat2.c'
filter_source.write_text('''#define _GNU_SOURCE 1
#include <errno.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>
int main(int argc,char **argv) {
    if(argc<2)return 2;
    struct sock_filter filter[]={
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS,offsetof(struct seccomp_data,nr)),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,SYS_openat2,0,1),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|ENOSYS),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW)};
    struct sock_fprog program={sizeof filter/sizeof *filter,filter};
    if(prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0)||prctl(PR_SET_SECCOMP,SECCOMP_MODE_FILTER,&program))return 3;
    execv(argv[1],argv+1);return 4;
}
''')
filter_exe = work / 'without-openat2'
subprocess.run(['cc', '-O2', '-Wall', '-Wextra', '-Werror', str(filter_source), '-o', str(filter_exe)], check=True, timeout=30)
wrapper = work / 'old-kernel-agent'
wrapper.write_text('#!/bin/sh\nexec ' + shlex.join([str(filter_exe), str(a.agent.resolve())]) + ' "$@"\n')
wrapper.chmod(0o755)
if a.skip_kernel_filter:
    rows.append({'name': 'old-kernel', 'status': 'skip', 'checks': 0, 'reason': 'local filter cannot affect the remote SSH agent'})
else:
    run('old-kernel', wrapper, work / 'fixture5', [('kernel', str(work / 'source.c'))])
# Interpose only the owned agent's fstatfs result. This tests filesystem policy
# without mounting anything or reading actual virtual-filesystem files.
filesystem_source = work / 'filesystem-type.c'
filesystem_source.write_text('''#define _GNU_SOURCE 1
#include <dlfcn.h>
#include <linux/magic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/statfs.h>
static long magic(void) {
    const char *name=getenv("XODB_TEST_SOURCE_FILESYSTEM");
    if(!name)return 0;
    if(!strcmp(name,"proc"))return PROC_SUPER_MAGIC;
    if(!strcmp(name,"sys"))return SYSFS_MAGIC;
    if(!strcmp(name,"devpts"))return DEVPTS_SUPER_MAGIC;
    if(!strcmp(name,"debug"))return DEBUGFS_MAGIC;
    if(!strcmp(name,"trace"))return TRACEFS_MAGIC;
    if(!strcmp(name,"cgroup2"))return CGROUP2_SUPER_MAGIC;
    return 0;
}
int fstatfs(int fd,struct statfs *out) {
    int (*original)(int,struct statfs *)=dlsym(RTLD_NEXT,"fstatfs");
    if(!original)return -1;
    int status=original(fd,out);if(!status&&magic())out->f_type=magic();return status;
}
int fstatfs64(int fd,struct statfs64 *out) {
    int (*original)(int,struct statfs64 *)=dlsym(RTLD_NEXT,"fstatfs64");
    if(!original)return -1;
    int status=original(fd,out);if(!status&&magic())out->f_type=magic();return status;
}
''')
filesystem_library = work / 'filesystem-type.so'
subprocess.run(['cc', '-O2', '-Wall', '-Wextra', '-Werror', '-shared', '-fPIC', str(filesystem_source), '-ldl', '-o', str(filesystem_library)], check=True, timeout=30)
if a.skip_kernel_filter:
    rows.append({'name': 'filesystem-types', 'status': 'skip', 'checks': 0, 'reason': 'local interposer cannot affect the remote SSH agent'})
else:
    for name in ['proc', 'sys', 'devpts', 'debug', 'trace', 'cgroup2']:
        wrapper = work / ('filesystem-' + name)
        wrapper.write_text('#!/bin/sh\nexec ' + shlex.join(['env', 'LD_PRELOAD=' + str(filesystem_library), 'XODB_TEST_SOURCE_FILESYSTEM=' + name, str(a.agent.resolve())]) + ' "$@"\n')
        wrapper.chmod(0o755)
        run('filesystem-' + name, wrapper, work / 'fixture5', [('filesystem', str(work / 'source.c'))])
(work / 'results.json').write_text(json.dumps({'status': 'pass', 'checks': rows}, indent=2) + '\n')
print('Source confinement passed:', sum(row['checks'] for row in rows))
