#!/usr/bin/env python3
"""Unprivileged rejection tests for the helper's inherited socket protocol."""
import array,ctypes,errno,os,signal,socket,struct,subprocess,sys
from pathlib import Path
helper=sys.argv[1]
def run(payload,descriptors=()):
    parent,child=socket.socketpair(socket.AF_UNIX,socket.SOCK_SEQPACKET)
    p=subprocess.Popen([helper,'--stdio'],stdin=child,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    child.close()
    try:
        ancillary=[(socket.SOL_SOCKET,socket.SCM_RIGHTS,array.array('i',descriptors))] if descriptors else []
        parent.sendmsg([payload],ancillary)
        parent.settimeout(2)
        data,anc,flags,_=parent.recvmsg(128,128)
        for level,kind,body in anc:
            if level==socket.SOL_SOCKET and kind==socket.SCM_RIGHTS:
                fds=array.array('i');fds.frombytes(body[:len(body)//fds.itemsize*fds.itemsize])
                for fd in fds:os.close(fd)
                raise AssertionError('Rejection transferred a descriptor')
        return data
    finally:
        parent.close()
        try:p.wait(timeout=2)
        except subprocess.TimeoutExpired:p.kill();p.wait();raise
fd=os.open('/proc/self/exe',os.O_RDONLY|os.O_CLOEXEC)
try:
    packet=lambda flags:struct.pack('=IiiIQ',0x58414c31,os.getpid(),os.getpid(),flags,0)
    assert run(b'x')==b''
    for descriptors,flags,expected in [((),2,errno.EINVAL),((fd,),4,errno.EINVAL),((fd,),2,errno.EPERM)]:
        reply=run(packet(flags),descriptors)
        assert struct.unpack('=Ii',reply)==(0x58414c31,expected),reply
    assert run(packet(2),(fd,fd,fd))==b''
finally:os.close(fd)
p=subprocess.run([helper,'--stdio'],input=b'',capture_output=True)
assert p.returncode==2,p
print('helper: truncated packet, descriptor count, invalid flags, untraced target, ancillary overflow and non-socket input rejected')

# An owned child proves that the validation proceeds past UID/tracer/stop checks.
child=os.fork()
if child==0:
    libc=ctypes.CDLL(None,use_errno=True)
    if libc.ptrace(0,0,None,None)!=0:os._exit(3) # PTRACE_TRACEME
    os.kill(os.getpid(),signal.SIGSTOP)
    os._exit(0)
try:
    got,status=os.waitpid(child,os.WUNTRACED)
    assert got==child and os.WIFSTOPPED(status),status
    mapped=next(line.split() for line in Path(f'/proc/{child}/maps').read_text().splitlines()
                if 'x' in line.split()[1] and line.split()[-1]==os.readlink(f'/proc/{child}/exe'))
    fd=os.open(f'/proc/{child}/exe',os.O_RDONLY|os.O_CLOEXEC)
    try:
        for offset in (0,os.fstat(fd).st_size,2**64-1):
            packet=struct.pack('=IiiIQ',0x58414c31,child,child,2,offset)
            assert struct.unpack('=Ii',run(packet,(fd,)))==(0x58414c31,errno.EINVAL)
        packet=struct.pack('=IiiIQ',0x58414c31,child,child,2,int(mapped[2],16))
        reply=struct.unpack('=Ii',run(packet,(fd,)))
        assert reply[0]==0x58414c31 and reply[1] in (errno.EACCES,errno.EPERM),reply
    finally:os.close(fd)
finally:
    try:os.kill(child,signal.SIGKILL)
    except ProcessLookupError:pass
    try:os.waitpid(child,0)
    except ChildProcessError:pass
print('helper: owned traced child reaches perf permission gate; non-executable and out-of-range ELF offsets rejected')
