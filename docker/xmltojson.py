#!/usr/bin/env python3
import contextlib
import json
import sys

import xmltodict


@contextlib.contextmanager
def _smart_open(filename, mode="r"):
    if filename == "-":
        if mode is None or mode == "" or "r" in mode:
            fh = sys.stdin
        else:
            fh = sys.stdout
    else:
        fh = open(filename, mode)
    try:
        yield fh
    finally:
        if filename != "-":
            fh.close()


def main():
    args = sys.argv[1:]
    with _smart_open("-" if args == [] else args[0]) as f:
        data = xmltodict.parse(f.read())
        print(json.dumps(data))


if __name__ == "__main__":
    main()
