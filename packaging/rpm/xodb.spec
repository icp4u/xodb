Name:           xodb
Version:        0.0.0
Release:        1%{?dist}
Summary:        Native Linux debugger and profiler
License:        GPL-3.0-only AND MIT
Source0:        %{name}-%{version}.tar.gz
ExclusiveArch:  x86_64

# Use --with external_zig when a standalone Zig compiler is already on PATH.
%bcond_with external_zig
%if %{without external_zig}
BuildRequires:  zig >= 0.16.0
%endif
BuildRequires:  gcc
BuildRequires:  pkgconfig(capstone)
BuildRequires:  pkgconfig(libdw)
BuildRequires:  pkgconfig(libelf)
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(wayland-scanner)
BuildRequires:  pkgconfig(wayland-protocols) >= 1.36
BuildRequires:  pkgconfig(xkbcommon)
BuildRequires:  pkgconfig(vulkan)
BuildRequires:  pkgconfig(freetype2)
BuildRequires:  pkgconfig(harfbuzz)
%if 0%{?suse_version}
BuildRequires:  shaderc
Requires:       dejavu-fonts
%global xodb_font /usr/share/fonts/truetype/DejaVuSansMono.ttf
%else
BuildRequires:  glslc
Requires:       dejavu-sans-mono-fonts
%global xodb_font /usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf
%endif

%description
A native Linux debugger, disassembler and profiler with a Wayland/Vulkan
interface and an MCP server. The allocation helper is installed as an ordinary
executable; its use requires explicit administrator authorization.

%prep
%setup -q

%build
./packaging/build %{xodb_font}

%install
./packaging/install "%{buildroot}" "%{_libexecdir}"

%check
.work/package/bin/xodb --help >/dev/null 2>&1

%files
%license %{_datadir}/licenses/xodb/
%doc %{_datadir}/doc/xodb/
%{_bindir}/xodb
%{_libexecdir}/xodb-allocation-helper
%{_datadir}/applications/xodb.desktop
