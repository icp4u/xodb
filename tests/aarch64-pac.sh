#!/bin/sh
# Opt-in aarch64 PAC unwind proof.
# Usage: tests/aarch64-pac.sh SSH
# The destination must be Linux and aarch64. The proof is built and run there.
# SSH options on the command line keep the known-hosts file unchanged.
set -eu
set -o pipefail
umask 022
if [ "$#" -ne 1 ]; then
    echo "usage: tests/aarch64-pac.sh SSH" >&2
    exit 2
fi
dest=$1
case $dest in
    ''|*[!A-Za-z0-9_@./:+-]*) echo "aarch64 pac: destination refused" >&2; exit 2;;
esac
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"
ssh_opts="-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
remote() {
    # shellcheck disable=SC2086
    ssh -n $ssh_opts -T "$dest" "$@"
}
# A copy keeps stdin open. ssh -n would discard the archive.
copy_to() {
    # shellcheck disable=SC2086
    ssh $ssh_opts -T "$dest" "$@"
}
echo "aarch64 pac: checking uname"
uname_s=$(remote 'uname -s')
uname_m=$(remote 'uname -m')
if [ "$uname_s" != Linux ] || [ "$uname_m" != aarch64 ]; then
    echo "aarch64 pac: destination is ${uname_s} ${uname_m}; need Linux aarch64" >&2
    exit 1
fi
remote 'command -v zig >/dev/null && command -v gcc >/dev/null && command -v g++ >/dev/null && command -v python3 >/dev/null && command -v objdump >/dev/null && command -v readelf >/dev/null'
list=
built=
cleanup() {
    status=$?
    if [ -n "$built" ]; then
        remote "rm -rf -- '$built'" || true
        echo "aarch64 pac: remote tree removed"
    fi
    if [ -n "$list" ]; then
        rm -f "$list"
    fi
    exit "$status"
}
trap cleanup EXIT
built=$(remote 'mktemp -d')
case $built in
    ''|*[!A-Za-z0-9_./+-]*) echo "aarch64 pac: remote directory refused" >&2; built=; exit 1;;
esac
list=$(mktemp)
find src -type f ! -name '*.o' ! -name '*.orig' ! -name '*~' -print > "$list"
printf '%s\n' \
    build.zig \
    build_macos.zig \
    tests/aarch64-pac.py \
    tests/client.py \
    tests/helpers/exact.py \
    tests/helpers/tasks.py \
    tests/fixtures/profile.c >> "$list"
tar -c -T "$list" | copy_to "tar -x -C '$built'"
rm -f "$list"
list=
echo "aarch64 pac: building"
remote "cd '$built' && mkdir -p .cache .zig-cache && ZIG_GLOBAL_CACHE_DIR='$built/.cache' ZIG_LOCAL_CACHE_DIR='$built/.zig-cache' nice zig build -j2 -Dgui=false -Doptimize=ReleaseSafe app -p '$built/prefix'"
echo "aarch64 pac: running proof"
remote "cd '$built' && python3 -B tests/aarch64-pac.py --xodb '$built/prefix/bin/xodb'"
echo "aarch64 pac: proof passed"
