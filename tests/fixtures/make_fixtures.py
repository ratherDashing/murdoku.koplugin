#!/usr/bin/env python3
"""Convert puzzle JSON files into Lua table files for tests/test_i18n.lua.

Usage: make_fixtures.py out.lua file1.json [file2.json ...]

Writes: return { ["filename-without-json"] = <lua table>, ... }
Only used to build *local* fixtures from murdoku.com downloads; the generated
.lua fixtures must not be committed (they contain site content).
"""
import json
import re
import sys


def lua_str(s):
    return '"%s"' % (
        s.replace("\\", "\\\\").replace('"', '\\"')
        .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    )


def lua_val(v):
    if v is True:
        return "true"
    if v is False:
        return "false"
    if v is None:
        return "nil"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, list):
        return "{" + ",".join(lua_val(x) for x in v) + "}"
    if isinstance(v, dict):
        items = []
        for k, val in v.items():
            items.append(f"[{lua_str(k)}]={lua_val(val)}")
        return "{" + ",".join(items) + "}"
    raise TypeError(repr(v))


def main():
    out_path = sys.argv[1]
    entries = []
    for path in sys.argv[2:]:
        name = path.rsplit("/", 1)[-1].replace(".json", "")
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        entries.append("[%s]=%s" % (lua_str(name), lua_val(data)))
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("return {" + ",".join(entries) + "}\n")
    print(f"wrote {out_path} ({len(entries)} fixture(s))")


if __name__ == "__main__":
    main()
