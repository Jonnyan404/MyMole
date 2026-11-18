#!/usr/bin/env python3
"""Bound the lifetime of our own child, including a blocked UI main thread."""
import argparse
import subprocess
import sys


def descendants(pid):
    """Our child's own processes, found through their parent IDs."""
    table = subprocess.run(["/bin/ps", "-Ao", "pid=,ppid="], capture_output=True, text=True).stdout
    children = {}
    for line in table.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    found, todo = [], [pid]
    while todo:
        for kid in children.get(todo.pop(), []):
            found.append(kid)
            todo.append(kid)
    return found


def report_stacks(pid):
    """Where every thread of a stuck run stands, before it is stopped, so a
    hang that only happens elsewhere can still be read from the log."""
    for process in [pid, *descendants(pid)]:
        try:
            out = subprocess.run(["/usr/bin/sample", str(process), "2", "-mayDie"],
                                 capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            continue
        print(f"Stacks of process {process}:\n{out.stdout}", file=sys.stderr, flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command or not 0 < args.timeout <= 3600:
        parser.error("a command and a timeout in (0, 3600] are required")
    # Popen owns the child and is its only reaper. An exited, unreaped child
    # retains its PID, so timeout handling cannot target a reused user PID.
    child = subprocess.Popen(args.command)
    try:
        return child.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        print("Owned test process exceeded its wall-clock deadline.", file=sys.stderr, flush=True)
        report_stacks(child.pid)
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        return 124


if __name__ == "__main__":
    sys.exit(main())
