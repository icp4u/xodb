#!/bin/sh
# Opt-in riscv64 guest step: hold the lease, build or use the remote
# binaries, run the software-step driver, remove only a directory this
# script created.
# Usage: tests/riscv64-guest.sh SSH AGENT FIXTURE
# XODB_GUEST_LEASE is the lease lock. ssh comes from PATH.
# When AGENT or FIXTURE is not executable on the guest, both are built
# in a fresh guest directory and that directory is removed afterwards.
set -eu
umask 022
if [ "$#" -ne 3 ]; then
    echo "usage: tests/riscv64-guest.sh SSH AGENT FIXTURE" >&2
    exit 2
fi
dest=$1
agent=$2
fixture=$3
if [ -z "${XODB_GUEST_LEASE:-}" ]; then
    echo "riscv64 guest: XODB_GUEST_LEASE is unset" >&2
    exit 2
fi
case $agent in *[!A-Za-z0-9_./+-]*) echo "riscv64 guest: agent path refused" >&2; exit 2;; esac
case $fixture in *[!A-Za-z0-9_./+-]*) echo "riscv64 guest: fixture path refused" >&2; exit 2;; esac
exec 9>"$XODB_GUEST_LEASE"
echo "riscv64 guest: waiting for lease"
flock 9
echo "riscv64 guest: lease held"
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"
config_args=
ssh_config=
if [ -n "${XODB_SSH_CONFIG:-}" ]; then
    config_args="--ssh-config $XODB_SSH_CONFIG"
    ssh_config="-F $XODB_SSH_CONFIG"
fi
# shellcheck disable=SC2086
ssh_base() {
    ssh $ssh_config -o BatchMode=yes -o ConnectTimeout=8 -T "$dest" "$@"
}
# shellcheck disable=SC2086
remote() {
    ssh $ssh_config -n -o BatchMode=yes -o ConnectTimeout=8 -T "$dest" "$@"
}
built=
cleanup() {
    status=$?
    if [ -n "$built" ]; then
        remote "rm -rf -- '$built'" || true
        echo "guest dir removed"
    fi
    exit "$status"
}
trap cleanup EXIT
if remote "test -x '$agent' && test -x '$fixture'"; then
    echo "riscv64 guest: using remote agent and fixture"
else
    echo "riscv64 guest: building agent and fixture"
    built=$(remote 'mktemp -d')
    case $built in
        ''|*[!A-Za-z0-9_./+-]*) echo "riscv64 guest: guest directory refused" >&2; built=; exit 1;;
    esac
    find src tests/fixtures/runtime-riscv64.c -type f \
        \( -name '*.c' -o -name '*.h' -o -name Makefile \) -print \
        | tar -c -T - | ssh_base "tar -x -C '$built'"
    remote "cd '$built' && make -s -j4 -C src/runtime"
    remote "cd '$built' && gcc -g -O0 -fno-omit-frame-pointer -fno-pie -no-pie -pthread -o fixture tests/fixtures/runtime-riscv64.c"
    agent=$built/.work/c-runtime/xodb-agent
    fixture=$built/fixture
    echo "riscv64 guest: build finished"
fi
# shellcheck disable=SC2086
python3 -B tests/runtime-riscv64.py --ssh "$dest" --agent "$agent" --fixture "$fixture" $config_args
left=$(remote "ps -u \"\$(id -un)\" -o pid=,args=" | grep -F "$agent" || true)
if [ -n "$left" ]; then
    echo "riscv64 guest: leftover process" >&2
    printf '%s\n' "$left" | awk '{print $1}' | while read -r pid; do
        case $pid in
            ''|*[!0-9]*) ;;
            *) remote "kill $pid" || true ;;
        esac
    done
    exit 1
fi
echo "riscv64 guest: no leftover agent"
