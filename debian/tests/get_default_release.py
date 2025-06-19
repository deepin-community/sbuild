#!/usr/bin/env python3

import platform
import sys

import apt_pkg

os_release = platform.freedesktop_os_release()
if os_release["ID"] != "debian" and os_release.get("VERSION_CODENAME"):
    print(os_release["VERSION_CODENAME"])
    sys.exit(0)

apt_pkg.init()
c = apt_pkg.Cache(None)
d = apt_pkg.DepCache(c)
s = apt_pkg.SourceList()
s.read_main_list()

highest_prio = -1
highest_archive = None
for pkgfile, _ in d.get_candidate_ver(c["base-files"]).file_list:
    print("processing: %s" % pkgfile, file=sys.stderr)
    index = s.find_index(pkgfile)
    if index is None:
        print("index is none -- skipping", file=sys.stderr)
        continue
    if not index.is_trusted:
        print("index is not trusted -- skipping", file=sys.stderr)
        continue
    archive = pkgfile.archive
    if archive not in ["stable", "testing", "unstable", "proposed-updates"]:
        print("index archive %s is %s -- skipping" % (index, archive), file=sys.stderr)
        continue
    if archive == "proposed-updates":
        archive = "stable"
    prio = d.policy.get_priority(pkgfile)
    if prio > highest_prio:
        highest_prio = prio
        highest_archive = archive
if highest_archive is None:
    print(
        "highest priority apt archive is neither stable, testing or unstable",
        file=sys.stderr,
    )
    for f in c.file_list:
        print("========================", file=sys.stderr)
        for a in [
            "architecture",
            "archive",
            "codename",
            "component",
            "filename",
            "id",
            "index_type",
            "label",
            "not_automatic",
            "not_source",
            "origin",
            "site",
            "size",
            "version",
        ]:
            print("%s: %s" % (a, getattr(f, a, None)), file=sys.stderr)
        print("priority: ", d.policy.get_priority(f), file=sys.stderr)
    exit(1)
print("highest archive priority: %s" % highest_archive, file=sys.stderr)
print(highest_archive)
