#!/usr/bin/env python3
"""Source-level licence gate for a libVLC build: fails if any file compiled into the libVLC that
is about to be linked carries a GPL licence header.

    scripts/audit-libvlc-sources.py VLC_SOURCE_DIR BUILD_DIR PLUGIN_DIR [--core LIB.a ...]
                                    [--report FILE]

VLC_SOURCE_DIR  the libvlc checkout (e.g. Vendor/VLCKit/build/VLCKit/libvlc/vlc)
BUILD_DIR       its configured make tree for one platform and architecture
                (e.g. .../libvlc/vlc/build-MacOSXOS/arm64)
PLUGIN_DIR      the folder whose top-level lib*_plugin.a files are the modules that get linked
                (VLCKit links exactly these: buildMobileVLCKit.sh builds its module table from them)
--core LIB.a    libvlc.a, libvlccore.a, libcompat.a: checked like a module

How: for every linked archive, the configured Makefiles name the objects it is built from
(lib<name>_plugin_la_OBJECTS, plus the convenience libraries in its _LIBADD), and for every object
the compiler wrote a dependency file (<dir>/.deps/<object>.Plo) naming its source file and every
header it included. Each of those files inside VLC_SOURCE_DIR (VLC's own sources and the contrib
headers installed under it) is read; the first licence grant in its header decides: "GNU General
Public License" is GPL, the Lesser/Library GPL is not. This finds both the modules that declare
VLC_LICENSE_GPL_2_PLUS and the ones that link GPL code without declaring it (hqdn3d.h,
deinterlace's yadif.h/yadif_template.h, i420_rgb_mmx.h: lane 20).

Every object in an archive must be accounted for: one the Makefiles do not list (a stale object
left from an earlier build, for instance), one without a dependency file, or one whose dependency
file names no file in the VLC or build tree (a "# dummy" placeholder, or paths that do not match
VLC_SOURCE_DIR) fails the audit, since its sources cannot be checked.

Not covered here: the contrib libraries' own code (libavcodec.a, libzvbi.a ...). The contrib
bootstrap's --disable-gpl/--disable-gnuv3 keep GPL packages out; zvbi, whose LGPL library contains
GPL-only files, is excluded by scripts/build-vlckit.sh; scripts/audit-gpl-symbols.sh checks the
linked binary for both.

Exit status: 0 clean, 1 GPL or untraceable code found, 2 could not run the check.
"""
import os
import re
import subprocess
import sys

LICENCE_WINDOW = 6000  # bytes read from the top of each file: licence headers come first
# The first licence named in the header is the one the file is granted under. (Some GPL files go
# on to say their author may relicense them under the LGPL, e.g. stream_out/cycle.c: still GPL.)
LICENCE = re.compile(r"\b(Lesser\s+|Library\s+)?General\s+Public\s+License|"
                     r"SPDX-License-Identifier:\s*(L?GPL)", re.I)


def die(msg, code=2):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


# ---- Makefiles ------------------------------------------------------------------------------

def read_makefile(path):
    """Variable assignments of a configured automake Makefile (comments and rules skipped)."""
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read().replace("\\\n", " ")
    variables = {}
    for line in text.split("\n"):
        if not line or line[0] in "#\t":
            continue
        m = re.match(r"^([A-Za-z0-9_]+)\s*(\+?=)\s*(.*)$", line)
        if not m:
            continue
        name, op, value = m.groups()
        variables[name] = (variables.get(name, "") + " " + value) if op == "+=" else value
    return variables


def expand(variables, value, depth=0):
    if depth > 20:
        return value
    # $(VAR) and ${VAR}; autoconf's $U (an old ansi2knr suffix) is always empty.
    value = re.sub(r"\$\(([A-Za-z0-9_]+)\)|\$\{([A-Za-z0-9_]+)\}",
                   lambda m: expand(variables, variables.get(m.group(1) or m.group(2), ""), depth + 1),
                   value)
    return value.replace("$U", "")


class Build:
    def __init__(self, build_dir):
        self.makefiles = {}
        for root, dirs, files in os.walk(build_dir):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            if "Makefile" in files and "Makefile.in" not in files:  # configured, not a source tree
                self.makefiles[root] = read_makefile(os.path.join(root, "Makefile"))
        if not self.makefiles:
            die(f"no configured Makefiles under {build_dir}")

    def find(self, canon):
        for d, v in self.makefiles.items():
            if f"am_{canon}_OBJECTS" in v or f"{canon}_OBJECTS" in v:
                return d, v
        return None, None

    def objects(self, library, seen=None):
        """(makefile dir, object path) for a libtool library name such as libdeinterlace_plugin.la,
        including the convenience libraries it pulls in."""
        seen = seen if seen is not None else set()
        canon = re.sub(r"[^A-Za-z0-9]", "_", library)
        if canon in seen:
            return []
        seen.add(canon)
        d, v = self.find(canon)
        if d is None:
            return None
        objs = [(d, o) for o in expand(v, v.get(f"{canon}_OBJECTS", f"$(am_{canon}_OBJECTS)")).split()
                if o.endswith((".lo", ".o"))]
        for dep in expand(v, v.get(f"{canon}_LIBADD", "")).split():
            if dep.endswith((".lo", ".o")):  # replacement functions (LTLIBOBJS) and the like
                objs.append((d, dep))
            elif dep.endswith(".la"):
                sub = self.objects(os.path.basename(dep), seen)
                if sub:
                    objs += sub
        return objs


def dep_file(makefile_dir, obj):
    sub, base = os.path.split(obj)
    stem = base.rsplit(".", 1)[0]
    ext = ".Plo" if base.endswith(".lo") else ".Po"
    return os.path.join(makefile_dir, sub, ".deps", stem + ext)


def dependencies(path, makefile_dir):
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    rule = text.split("\n\n", 1)[0].replace("\\\n", " ")  # the first rule; later ones are phony
    if ":" not in rule:
        return []
    deps = rule.split(":", 1)[1].split()
    return [os.path.normpath(d if os.path.isabs(d) else os.path.join(makefile_dir, d)) for d in deps]


# ---- licences -------------------------------------------------------------------------------

_licence = {}


def is_gpl(path):
    if path not in _licence:
        try:
            with open(path, "rb") as f:
                head = f.read(LICENCE_WINDOW).decode("utf-8", errors="replace")
        except OSError:
            head = ""
        head = re.sub(r"[\s*/#@;!]+", " ", head)  # comment markers and line breaks
        m = LICENCE.search(head)
        _licence[path] = bool(m) and not m.group(1) and (m.group(2) or "GPL").upper() == "GPL"
    return _licence[path]


def licence_line(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for n, line in enumerate(f, 1):
                if "General Public License" in line or "SPDX-License-Identifier" in line:
                    return f"line {n}: {line.strip()}"
                if n > 80:
                    break
    except OSError:
        pass
    return "?"


def members(archive):
    try:
        out = subprocess.run(["ar", "t", archive], check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        die(f"cannot list {archive}: {e}")
    # libtool renames clashing basenames inside one archive to lt<N>-name.o
    return [re.sub(r"^lt\d+-", "", m) for m in out.split() if m.endswith(".o")]


def main(argv):
    args = list(argv)
    report = None
    core = []
    if "--report" in args:
        i = args.index("--report")
        report = args[i + 1]
        del args[i:i + 2]
    while "--core" in args:
        i = args.index("--core")
        core.append(args[i + 1])
        del args[i:i + 2]
    if len(args) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    src, build_dir, plugins = (os.path.realpath(a) for a in args)
    for d in (src, build_dir, plugins):
        if not os.path.isdir(d):
            die(f"{d} is not a directory")
    build = Build(build_dir)

    archives = sorted(os.path.join(plugins, f) for f in os.listdir(plugins)
                      if f.startswith("lib") and f.endswith("_plugin.a"))
    if len(archives) < 50:
        die(f"only {len(archives)} plugin archives in {plugins}; is this the plugin folder?")
    archives += [os.path.realpath(c) for c in core]

    src_prefix = src + os.sep
    build_prefix = build_dir + os.sep
    failures = {}    # archive -> {GPL file}
    untraced = []    # objects whose sources could not be determined
    checked = set()
    for archive in archives:
        name = os.path.basename(archive)
        objs = build.objects(name[:-2] + ".la")
        if objs is None:
            untraced.append(f"{name} (not built by any Makefile under {build_dir})")
            continue
        listed = {os.path.basename(o).rsplit(".", 1)[0] for _, o in objs}
        for m in members(archive):
            if m[:-2] not in listed:
                untraced.append(f"{name}({m}): not one of the objects its Makefile builds")
        for makefile_dir, obj in objs:
            df = dep_file(makefile_dir, obj)
            if not os.path.isfile(df):
                untraced.append(f"{name}({obj}): no dependency file")
                continue
            in_tree = False
            for path in dependencies(df, makefile_dir):
                if path.startswith(src_prefix) or path.startswith(build_prefix):
                    in_tree = True
                if not path.startswith(src_prefix) or path.startswith(build_prefix):
                    continue  # SDK, toolchain, or a generated file such as config.h
                checked.add(path)
                if is_gpl(path):
                    failures.setdefault(name, set()).add(path)
            # Its source file is in the VLC tree (or, generated, in the build tree): a "# dummy"
            # dependency file, or paths that do not match VLC_SOURCE_DIR (a symlinked checkout),
            # would otherwise let the object pass unchecked.
            if not in_tree:
                untraced.append(f"{name}({obj}): its dependency file names no file in {src} or "
                                f"{build_dir}")

    lines = [f"libVLC source licence audit: {len(archives)} archives, {len(checked)} source "
             f"files ({src})"]
    for name in sorted(failures):
        lines.append(f"FAIL (GPL source linked): {name}")
        for path in sorted(failures[name]):
            lines.append(f"    {os.path.relpath(path, src)}  [{licence_line(path)}]")
    for u in untraced:
        lines.append(f"FAIL (cannot trace to sources): {u}")
    if not failures and not untraced:
        lines.append("libVLC source licence audit passed")
    out = "\n".join(lines)
    print(out)
    if report:
        with open(report, "w", encoding="utf-8") as f:
            f.write(out + "\n")
    sys.exit(1 if failures or untraced else 0)


if __name__ == "__main__":
    main(sys.argv[1:])
