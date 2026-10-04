# Local Linux packages

These recipes build the current **Linux x86-64 GUI** with Zig **0.16.0** and
ReleaseSafe, targeting the baseline CPU rather than the builder's CPU. GNU build
IDs let package tools associate binaries with their debug symbols. These are
initial local packaging, not a claim of acceptance into any distribution.
`0.0.0-1` is a development package version, not a published xodb release. Before
a release, update `packaging/debian/changelog`, `packaging/rpm/xodb.spec` and
`packaging/arch/PKGBUILD.in` together.

Install the [application build dependencies](../README.md#build-and-run) first.
Package builders need the additional tools below. No build command installs
system packages or changes tracing policy. Run builds as an ordinary user in
an external directory; `scripts/build` keeps its caches inside its source tree.

## Make a source snapshot

From the checkout, choose a new output directory:

```sh
./scripts/package-source "$HOME/tmp/xodb-packages"
cd "$HOME/tmp/xodb-packages"
sha256sum -c xodb-0.0.0.tar.gz.sha256
tar -tzf xodb-0.0.0.tar.gz
```

The exporter includes current tracked contents and new files under the source,
test, documentation and packaging directories, including uncommitted local
fixes. It omits Git metadata, hidden files, editor backups and ignored build
outputs. Archive ownership and timestamps are normalized; `SOURCE_DATE_EPOCH`
can override the default timestamp from HEAD. It refuses to overwrite an
existing output directory. Review the source list before sharing the archive.

Debian recipes live in `packaging/debian/` in the checkout. The archive includes
them there and copies them to the source-root `debian/` directory required by
Debian's build tools. Build Debian packages from the exported source tree.

It also generates `PKGBUILD` beside the archive with that archive's SHA-256
pinned. There is no source download during the package build.

## Arch Linux / pacman

Build tools: `base-devel` and the application dependencies from the README.
In the exported directory:

```sh
makepkg
# Install explicitly when ready:
sudo pacman -U ./xodb-0.0.0-1-x86_64.pkg.tar.zst
```

`makepkg` checks dependencies; these instructions intentionally omit its
automatic install options. The template is
[`arch/PKGBUILD.in`](arch/PKGBUILD.in). The font comes from `ttf-dejavu`.

## Debian / Ubuntu

Additional build tools: `debhelper`, `dpkg-dev`, and `build-essential`.
In the exported directory:

```sh
tar -xzf xodb-0.0.0.tar.gz
cd xodb-0.0.0
dpkg-buildpackage -us -uc -b
# Install explicitly when ready:
sudo apt install ../xodb_0.0.0-1_amd64.deb
```

The normal dependency check expects a Zig 0.16.0 **package**. If you supplied
the official standalone compiler on PATH instead, use the explicit build profile:

```sh
dpkg-buildpackage -us -uc -b -Ppkg.xodb.external-zig
```

That profile removes only the Zig package requirement. The build still checks
`zig version` and all other package dependencies. The recipes are in
[`debian/`](debian/); debhelper derives shared-library runtime dependencies.
`fonts-dejavu-core` supplies the default font, through its `fonts-dejavu-mono`
dependency on newer releases. No personal maintainer identity is embedded;
replace the `.invalid` contact before submission to a distribution.

## RPM: Fedora / openSUSE Tumbleweed

Additional build tool: `rpm-build`. In the exported directory:

```sh
tar -xzf xodb-0.0.0.tar.gz
mkdir -p rpm/BUILD rpm/BUILDROOT rpm/RPMS rpm/SRPMS rpm/SOURCES rpm/SPECS
rpmbuild -ba --define "_topdir $PWD/rpm" --define "_sourcedir $PWD" \
  xodb-0.0.0/packaging/rpm/xodb.spec
# Install the resulting binary RPM explicitly with dnf or zypper when ready.
```

RPM checks build dependencies and generates shared-library runtime requirements.
The [spec](rpm/xodb.spec) selects Fedora's `glslc` and
`dejavu-sans-mono-fonts`, or openSUSE's `shaderc` and `dejavu-fonts` using the
distribution's `suse_version` macro. To use an externally supplied Zig 0.16.0
compiler, add `--with external_zig`; the compiler version is still checked.

## Installed files and checks

Every package installs `/usr/bin/xodb`, a desktop entry, documentation and the
GPL/MIT notices. It depends on system libraries and fonts instead of bundling
them. You still need a Wayland compositor and a Vulkan driver for your GPU.
The optional allocation helper is an ordinary mode-0755 executable:

| Package | Helper path | Compiled default font |
| --- | --- | --- |
| Arch | `/usr/lib/xodb/xodb-allocation-helper` | `/usr/share/fonts/TTF/DejaVuSansMono.ttf` |
| Debian / Ubuntu | `/usr/libexec/xodb-allocation-helper` | `/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf` |
| Fedora | `/usr/libexec/xodb-allocation-helper` | `/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf` |
| openSUSE | `/usr/libexec/xodb-allocation-helper` | `/usr/share/fonts/truetype/DejaVuSansMono.ttf` |

Pass the helper path explicitly with `--allocation-helper` after following
[the allocation tracing guide](../docs/ALLOCATIONS.md). Packages do not install
sudoers rules, capabilities, setuid bits, sysctl settings or services.
`--font FILE` can override any compiled font path.

Package builds compile the application and helper, then run `xodb --help` as a
display-free smoke check. They do not run the privileged live test suite during
packaging. For release validation, use the existing
[`scripts/release-check`](../scripts/release-check) tiers in a separate source
snapshot with the required test tools and permissions.

Dependency and recipe references: [Arch PKGBUILD](https://man.archlinux.org/man/PKGBUILD.5.en),
[Debian debhelper](https://manpages.debian.org/trixie/debhelper/dh.1.en.html),
[Debian DejaVu](https://packages.debian.org/trixie/fonts-dejavu-core),
[Fedora glslc](https://packages.fedoraproject.org/pkgs/shaderc/glslc/),
[Fedora DejaVu files](https://packages.fedoraproject.org/pkgs/dejavu-fonts/dejavu-sans-mono-fonts/fedora-44.html).
