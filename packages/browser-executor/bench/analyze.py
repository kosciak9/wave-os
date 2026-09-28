"""Recompute synthetic browser evaluation tables from published, redacted JSONL."""

import argparse
import json
import math
import statistics
from collections import Counter, defaultdict
from pathlib import Path


DEFAULT_DATA = Path(__file__).resolve().parent / 'results' / 'measurements.jsonl'


def percentile(values, q):
    """Nearest-rank percentile, with no interpolation of observed latency samples."""
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[max(0, math.ceil(q * len(ordered)) - 1)], 2)


def wilson(successes, total, z=1.96):
    if not total:
        return None
    p = successes / total
    denominator = 1 + z * z / total
    center = (p + z * z / (2 * total)) / denominator
    radius = z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total)) / denominator
    return [round(max(0, center - radius), 3), round(min(1, center + radius), 3)]


def read_records(path):
    records = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    if not records or any(not isinstance(row, dict) or not row.get('suite') or not row.get('task')
                          or row.get('success') not in (True, False, None) for row in records):
        raise ValueError('missing or invalid browser measurements')
    identities = [(row['suite'], row['task']) for row in records]
    if len(identities) != len(set(identities)):
        raise ValueError('duplicate task within a suite')
    return records


def summarize(records):
    verified = [row for row in records if row['success'] is not None]
    passed = sum(row['success'] is True for row in verified)
    latencies = [value for row in records for value in row.get('local_latency_ms', [])]
    walls = [row['wall_seconds'] for row in records if row.get('wall_seconds') is not None]
    summed = lambda field: sum(row.get(field) or 0 for row in records)
    instrumented = [row for row in records if (row.get('local_calls') or 0) > 0]
    loop_observed = [row for row in records if row.get('loop_detected') is not None]
    recovery = sum(any(row.get('executor_results', {}).get('status:' + status)
                       for status in ('escalated', 'checkpoint')) for row in instrumented)
    return {
        'tasks': len(records), 'oracle_available': len(verified), 'passed': passed,
        'pass_rate': round(passed / len(verified), 3) if verified else None,
        'pass_wilson_95': wilson(passed, len(verified)),
        'wrong_actions_oracle_lower_bound': summed('wrong_actions'),
        'all_camofox_actions': summed('camofox_actions'),
        'wrong_action_rate_lower_bound': round(summed('wrong_actions') / summed('camofox_actions'), 4)
        if summed('camofox_actions') else None,
        'wall_mean_s': round(statistics.mean(walls), 2) if walls else None,
        'wall_p50_s': percentile(walls, .5), 'wall_p95_s': percentile(walls, .95),
        'turns_total': summed('turns'), 'model_input_plus_cache_total': summed('model_input_plus_cache'),
        'prompt_peak_tokens': max((row.get('prompt_peak_tokens') or 0 for row in records), default=0),
        'large_snapshots': summed('snapshots_exposed'), 'image_blocks': summed('image_blocks'),
        'compact_snapshots': summed('compact_snapshots_exposed'),
        'full_snapshots': summed('full_snapshots_exposed')
        if any(row.get('full_snapshots_exposed') is not None for row in records) else None,
        'local_calls': summed('local_calls'), 'local_steps': summed('local_steps'),
        'local_snapshots_unexposed_observed': summed('local_snapshots_unexposed')
        if any(row.get('local_snapshots_unexposed') is not None for row in records) else None,
        'local_latency_samples': len(latencies),
        'local_latency_p50_ms': percentile(latencies, .5), 'local_latency_p95_ms': percentile(latencies, .95),
        'agent_rss_peak_kib': max((row.get('agent_rss_peak_kib') or 0 for row in records), default=0),
        'camofox_server_rss_peak_mib': max((row.get('camofox_server_rss_peak_mib') or 0 for row in records), default=0),
        'budget_hits': sum(row.get('steps_budget_hit') is True for row in records),
        'timeouts': sum(row.get('timed_out') is True for row in records),
        'observed_action_loops': summed('loop_detected') if loop_observed else None,
        'loop_telemetry_tasks': len(loop_observed),
        'executor_recovery_tasks_observed': recovery if instrumented else None,
        'executor_recovery_task_rate_observed': round(recovery / len(instrumented), 3) if instrumented else None,
        'executor_results': dict(sorted(sum((Counter(row.get('executor_results', {})) for row in records), Counter()).items())),
    }


def paired(left, right):
    a = {row['task']: row for row in left}
    b = {row['task']: row for row in right}
    common = sorted(a.keys() & b.keys())
    available = [task for task in common if a[task]['success'] is not None and b[task]['success'] is not None]
    changes = {'both_pass': [], 'both_fail': [], 'left_only': [], 'right_only': []}
    for task in available:
        left_pass = a[task]['success']
        right_pass = b[task]['success']
        bucket = ('both_pass' if left_pass and right_pass else 'both_fail' if not left_pass and not right_pass
                  else 'left_only' if left_pass else 'right_only')
        changes[bucket].append(task)
    paired_walls = [b[task]['wall_seconds'] - a[task]['wall_seconds'] for task in available
                    if a[task].get('wall_seconds') is not None and b[task].get('wall_seconds') is not None]
    return {'common_tasks': len(common), 'verified_pairs': len(available), 'changes': changes,
            'unpaired_left': sorted(a.keys() - b.keys()), 'unpaired_right': sorted(b.keys() - a.keys()),
            'oracle_unavailable_in_pair': sorted(set(common) - set(available)),
            'right_minus_left_passes': len(changes['right_only']) - len(changes['left_only']),
            'right_minus_left_wall_mean_s': round(statistics.mean(paired_walls), 2) if paired_walls else None}


def analyze(records, pairs=()):
    suites = defaultdict(list)
    for row in records:
        suites[row['suite']].append(row)
    report = {
        'suites': {suite: summarize(items) for suite, items in sorted(suites.items())},
        'categories': {suite: {category: summarize([row for row in items if row['category'] == category])
                               for category in sorted({row['category'] for row in items})}
                       for suite, items in sorted(suites.items())},
        'splits': {suite: {split: summarize([row for row in items if row['split'] == split])
                           for split in sorted({row['split'] for row in items if row['split']})}
                   for suite, items in sorted(suites.items())},
        'pairs': {},
    }
    for left, right in pairs:
        if left not in suites or right not in suites:
            raise ValueError('pair references unknown suite')
        report['pairs'][left + ' -> ' + right] = paired(suites[left], suites[right])
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, default=DEFAULT_DATA)
    parser.add_argument('--pair', nargs=2, action='append', metavar=('LEFT', 'RIGHT'), default=[])
    parser.add_argument('--output', type=Path, help='Optional JSON report path')
    args = parser.parse_args()
    report = analyze(read_records(args.data), args.pair)
    text = json.dumps(report, indent=2, sort_keys=True) + '\n'
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end='')


if __name__ == '__main__':
    main()
