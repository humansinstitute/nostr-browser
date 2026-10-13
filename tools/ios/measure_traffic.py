#!/usr/bin/env python3
"""Timestamp nettop process socket totals; never log endpoint addresses."""
import csv
import io
import os
import subprocess
import sys
import time

pid = int(sys.argv[1])
writer = csv.writer(sys.stdout)
writer.writerow(["unixTime", "bytesIn", "bytesOut", "available"])
sys.stdout.flush()
while True:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        break
    # Short-lived snapshots avoid losing buffered infinite-logger output on
    # cancellation. Sample timestamps bracket collection, not packet arrival.
    began = time.time()
    values = None
    try:
        result = subprocess.run(
            ["nettop", "-P", "-L", "1", "-x", "-n", "-p", str(pid),
             "-J", "bytes_in,bytes_out"],
            capture_output=True, text=True, timeout=3, check=True)
        for row in csv.reader(io.StringIO(result.stdout)):
            if len(row) >= 3 and row[0].endswith(f".{pid}"):
                values = (int(row[1]), int(row[2]))
                break
    except (subprocess.SubprocessError, ValueError, OSError) as error:
        print(f"nettop sample unavailable: {type(error).__name__}", file=sys.stderr)
    writer.writerow([began, *(values or ("", "")), values is not None])
    sys.stdout.flush()
    time.sleep(max(0, 1 - (time.time() - began)))
