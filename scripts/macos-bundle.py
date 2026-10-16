#!/usr/bin/env python3
"""Package the native client without installing anything outside the build prefix."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def main():
    if sys.platform != 'darwin':
        raise SystemExit('native macOS packaging requires Darwin')
    binary, library, destination = map(Path, sys.argv[1:])
    contents = destination / 'Contents'
    executable = contents / 'MacOS/xodb'
    dylib = contents / 'Frameworks/libMoltenVK.dylib'
    executable.parent.mkdir(parents=True, exist_ok=True)
    dylib.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, executable)
    shutil.copy2(library, dylib)
    os.chmod(executable, 0o755)
    os.chmod(dylib, 0o755)
    # The build-tree executable keeps its debug map; the redistributable copy
    # must not retain compiler/cache object paths in Mach-O N_OSO symbols.
    run('/usr/bin/strip', '-S', str(executable))
    # No account-private tool paths in the relocatable bundle.
    commands = run('/usr/bin/otool', '-l', str(executable)).splitlines()
    for i, line in enumerate(commands):
        if line.strip() == 'cmd LC_RPATH':
            path = commands[i + 2].strip().split(' (offset ', 1)[0].removeprefix('path ')
            run('/usr/bin/install_name_tool', '-delete_rpath', path, str(executable))
    for line in run('/usr/bin/otool', '-L', str(executable)).splitlines()[1:]:
        old = line.strip().split(' (', 1)[0]
        if old.endswith('/libMoltenVK.dylib'):
            run('/usr/bin/install_name_tool', '-change', old, '@rpath/libMoltenVK.dylib', str(executable))
    run('/usr/bin/install_name_tool', '-add_rpath', '@executable_path/../Frameworks', str(executable))
    run('/usr/bin/install_name_tool', '-id', '@rpath/libMoltenVK.dylib', str(dylib))
    with (contents / 'Info.plist').open('wb') as out:
        plistlib.dump(dict(CFBundleExecutable='xodb', CFBundleIdentifier='org.xodb.client',
                          CFBundleName='xodb', CFBundlePackageType='APPL', CFBundleVersion='1',
                          CFBundleShortVersionString='0.1', NSHighResolutionCapable=True,
                          LSMinimumSystemVersion='13.0'), out)
    for path in (dylib, destination):
        run('/usr/bin/codesign', '--force', '--sign', '-', str(path))
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(destination))
    print('native app packaged and ad-hoc signature verified')


if __name__ == '__main__':
    main()
