"""pulso serve | pulso snapshot [--pretty] | pulso puertos"""

import json
import sys

from . import server
from .cli import ports_table, summary


def main(argv):
    cmd = argv[0] if argv else "puertos"
    if cmd == "serve":
        server.serve()
    elif cmd == "snapshot":
        snap = server.snapshot()
        print(json.dumps(snap, ensure_ascii=False, indent=2 if "--pretty" in argv else None))
    elif cmd in ("puertos", "ports"):
        snap = server.snapshot()
        print(summary(snap))
        print()
        print(ports_table(snap))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
