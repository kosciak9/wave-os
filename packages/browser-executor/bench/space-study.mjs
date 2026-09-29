// Entry point for the isolated synthetic local comparator.
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const script = fileURLToPath(new URL('./space-study.py', import.meta.url));
const child = spawnSync('python3', [script, ...process.argv.slice(2)], { stdio: 'inherit' });
if (child.error) throw child.error;
process.exitCode = child.status ?? 1;
