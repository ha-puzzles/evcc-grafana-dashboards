#!/usr/bin/env python3
"""Compare Python versions with read-only historical CLI runs; never invoke Bash.

Both versions must support --profile. Reference is the saved pre-optimization
Python port. Runs alternate order to expose VM cache/order effects.
"""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import sys
import time


def samples(text):
    result = {}
    for line in text.splitlines():
        series, value, timestamp = line.rsplit(' ', 2)
        key = series, int(timestamp)
        if key in result:
            raise ValueError('Duplicate sample')
        result[key] = float(value)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--optimized', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--first', required=True, help='Completed day YYYY-MM-DD')
    parser.add_argument('--last', required=True, help='Completed day YYYY-MM-DD')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    variants = {'baseline': (args.baseline, []), 'optimized_daily': (args.optimized, ['--batch-days', '1']),
                'optimized_weekly': (args.optimized, ['--batch-days', '7'])}
    report = dict(first=args.first, last=args.last, runs=[],
                  baseline_sha256=hashlib.sha256(args.baseline.read_bytes()).hexdigest(),
                  optimized_sha256=hashlib.sha256(args.optimized.read_bytes()).hexdigest())
    expected = None
    for number, name in enumerate(['baseline', 'optimized_daily', 'optimized_weekly',
                                   'optimized_weekly', 'optimized_daily', 'baseline']):
        script, flags = variants[name]
        prefix = args.output / f'{number}-{name}'
        profile_path = prefix.with_suffix('.profile.json')
        command = [sys.executable, str(script), '--config', str(args.config), '--dry-run',
                   '--from', *args.first.split('-'), '--to', *args.last.split('-'),
                   '--profile', str(profile_path), *flags]
        start = time.perf_counter()
        process = subprocess.run(command, capture_output=True, text=True)
        seconds = time.perf_counter() - start
        prefix.with_suffix('.prom').write_text(process.stdout)
        prefix.with_suffix('.log').write_text(process.stderr)
        if process.returncode:
            raise RuntimeError('Dry run failed: ' + name + '; see saved log')
        actual = samples(process.stdout)
        if expected is None:
            expected = actual
        if actual != expected:
            raise RuntimeError('Values/identities differ from Python baseline: ' + name)
        p = json.loads(profile_path.read_text())
        entry = dict(variant=name, seconds=seconds, requests=p['requests'], samples=len(actual), exact=True,
                     http_seconds=p['http_seconds'], decode_seconds=p['decode_seconds'])
        report['runs'].append(entry)
        report['median_seconds'] = {n: statistics.median(r['seconds'] for r in report['runs'] if r['variant'] == n)
                                    for n in variants if any(r['variant'] == n for r in report['runs'])}
        (args.output / 'summary.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(entry), flush=True)


if __name__ == '__main__':
    main()
