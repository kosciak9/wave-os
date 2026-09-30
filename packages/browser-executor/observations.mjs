import { randomBytes } from 'node:crypto';
import { constants, closeSync, fstatSync, fsyncSync, openSync, writeSync } from 'node:fs';
import { join } from 'node:path';
import process from 'node:process';
import { atomicProtected, protectedDirectory, protectedFile, readProtected } from './state.mjs';

const instances = new Map();
const MAX_BYTES = 5 * 1024 * 1024;
const MAX_EVENTS = 10_000;
const MAX_AGE = 7 * 24 * 60 * 60_000;
const opaque = value => typeof value === 'string' && /^[A-Za-z0-9_-]{22,64}$/.test(value);
const integer = (value, max = 1_000_000) => Number.isSafeInteger(value) && value >= 0 && value <= max;
const probability = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1;
const duration = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 120_000;
const oneOf = values => value => values.includes(value);
const incidentId = value => typeof value === 'string' && /^[0-9a-f]{32}$/.test(value);
const failureCode = oneOf(['invalid_request', 'invalid_continuation_shape', 'invalid_continuation_unknown',
  'invalid_continuation_expired', 'invalid_continuation_scope', 'origin_changed', 'incomplete_snapshot',
  'sensitive_fields', 'duplicate_refs', 'unsafe_url', 'timeout_or_cancelled', 'storage_error',
  'tab_state_unavailable', 'tab_busy', 'tab_quarantined', 'invalid_configuration',
  'backend_or_model_error', 'field_value_unverified', 'action_outcome_unknown', 'continuation_stale',
  'invalid_resolution', 'fact_not_grounded', 'invalid_choice', 'binding_not_grounded',
  'approved_choice_stale', 'action_not_grounded', 'other']);
const schema = {
  run_start: { mode: oneOf(['semantic']), owner: oneOf(['code']) },
  action: { step: integer, kind: oneOf(['CLICK', 'TYPE', 'SELECT', 'SCROLL', 'NAVIGATE', 'STOP', 'ESCALATE']),
    owner: oneOf(['code', 'local_model', 'luna', 'user']), deterministic: value => typeof value === 'boolean',
    outcome: oneOf(['verified', 'not_dispatched', 'unknown']) },
  local_decision: { step: integer, candidate_count: value => integer(value, 40) && value > 0,
    selected_index: value => integer(value, 39), probabilities: value => Array.isArray(value) && value.length > 0 &&
      value.length <= 8 && value.every(probability) && Math.abs(value.reduce((a, b) => a + b, 0) - 1) < 0.001,
    top1: probability, margin: probability, entropy: value => duration(value),
    latency_ms: duration, status: oneOf(['accepted', 'uncertain', 'invalid', 'error']),
    owner: oneOf(['local_model']) },
  semantic_handoff: { kind: oneOf(['semantic_boundary', 'ambiguous_mapping', 'missing_fact', 'unsupported_choice',
    'readonly_field', 'unsupported_number_replacement', 'ambiguous_choice', 'local_choice_unavailable', 'uncertain_choice',
    'action_loop', 'value_not_verified', 'existing_value_conflict', 'technical_recovery', 'form_choice']),
    candidate_count: value => integer(value, 8), resolution_owner: oneOf(['luna', 'user', 'unknown']),
    attribution: oneOf(['arbitration_requested', 'semantic_resolution', 'user_supplied', 'unverified']) },
  resume_result: { status: oneOf(['verified', 'stale', 'mismatch', 'unknown', 'acknowledged',
    'needs_user_input', 'handoff', 'failed']), owner: oneOf(['code', 'luna', 'user']) },
  recovery_result: { status: oneOf(['quarantined', 'verified', 'declined', 'unknown']), owner: oneOf(['code', 'user']),
    incident_id: incidentId },
  run_result: { status: oneOf(['completed', 'needs_reasoning', 'needs_user_input', 'ambiguity',
    'technical_failure', 'mutation_unknown', 'checkpoint']),
    outcome: oneOf(['unverified', 'semantic_arbitration']),
    steps: integer, reason: oneOf(['success_condition', 'semantic_finish_reported', 'handoff', 'safety_stop', 'timeout', 'unknown']),
    owner: oneOf(['code', 'local_model', 'luna', 'user']), failure_code: failureCode, incident_id: incidentId },
};
const shared = { run_id: opaque, task_id: opaque, task_count: integer };
const encode = (epoch, seq) => Buffer.from(JSON.stringify([epoch, seq])).toString('base64url');
const decode = token => {
  if (typeof token !== 'string' || token.length > 128 || !/^[A-Za-z0-9_-]+$/.test(token)) throw Error('invalid_cursor');
  try {
    const pair = JSON.parse(Buffer.from(token, 'base64url').toString('utf8'));
    if (!Array.isArray(pair) || pair.length !== 2 || !/^[0-9a-f]{32}$/.test(pair[0]) ||
        !Number.isSafeInteger(pair[1]) || pair[1] < 0 || encode(...pair) !== token) throw Error('invalid_cursor');
    return pair;
  } catch { throw Error('invalid_cursor'); }
};
const validate = event => {
  if (!event || typeof event !== 'object' || Array.isArray(event) || !Object.hasOwn(schema, event.event)) return false;
  const fields = { ...shared, ...schema[event.event] };
  return Object.keys(event).every(key => key === 'event' || Object.hasOwn(fields, key) &&
    (key === 'selected_index' && event[key] === undefined || fields[key](event[key]))) &&
    opaque(event.run_id) && opaque(event.task_id) &&
    (event.event !== 'run_result' || event.failure_code === undefined ||
      ['technical_failure', 'ambiguity', 'mutation_unknown'].includes(event.status)) &&
    (event.event !== 'local_decision' || event.probabilities === undefined ||
      event.probabilities.length === event.candidate_count && integer(event.selected_index, 39) &&
      event.selected_index < event.candidate_count);
};

/** Installation-wide, value-free metrics for a single trusted owner. The wrapper
 * must gate the read tool to main + authorized owner context (not subagents or
 * other users). This module accepts no model-supplied paths or text labels.
 * No emitted event proves business completion or detects overrun by itself.
 */
export function createObservationStore(directory) {
  const root = protectedDirectory(directory);
  if (instances.has(root)) return instances.get(root);
  const path = join(root, 'observations.jsonl');
  let epoch, seq, events, bytes, failed = false, rejectedEventsSinceStart = 0;
  const header = () => JSON.stringify({ version: 1, epoch, seq }) + '\n';
  try {
    const text = readProtected(path);
    if (text === null) {
      epoch = randomBytes(16).toString('hex'); seq = 0; events = [];
      atomicProtected(path, header());
      bytes = Buffer.byteLength(header());
    } else {
      // A torn final append was never acknowledged by emit. Discard only that
      // incomplete line, rotate the cursor epoch, and signal a gap to readers.
      const torn = !text.endsWith('\n');
      const complete = torn ? text.slice(0, text.lastIndexOf('\n') + 1) : text;
      if (!complete) throw Error('storage_error');
      const lines = complete.trimEnd().split('\n');
      const first = JSON.parse(lines.shift());
      if (first.version !== 1 || !/^[0-9a-f]{32}$/.test(first.epoch) || !Number.isSafeInteger(first.seq) || first.seq < 0)
        throw Error('storage_error');
      epoch = first.epoch; seq = first.seq;
      events = lines.map(line => JSON.parse(line));
      if (events.length > MAX_EVENTS || Buffer.byteLength(text) > MAX_BYTES ||
          events.some((entry, index) => !Number.isSafeInteger(entry.seq) || entry.seq < 1 ||
            index && entry.seq !== events[index - 1].seq + 1 ||
            !integer(entry.timestamp, Number.MAX_SAFE_INTEGER) ||
            !validate(Object.fromEntries(Object.entries(entry).filter(([key]) => !['seq', 'timestamp'].includes(key)))) ||
            Object.keys(entry).some(key => !['seq', 'timestamp', 'event', ...Object.keys(shared),
              ...Object.keys(schema[entry.event])].includes(key))) ||
          events.length && events.at(-1).seq < seq) throw Error('storage_error');
      if (events.length) seq = events.at(-1).seq;
      if (torn) {
        epoch = randomBytes(16).toString('hex');
        atomicProtected(path, header() + events.map(entry => JSON.stringify(entry) + '\n').join(''));
      }
      bytes = Buffer.byteLength(torn ? header() + events.map(entry => JSON.stringify(entry) + '\n').join('') : text);
    }
  } catch { throw Error('storage_error'); }
  const compact = (now, { reserveEvents = 0, reserveBytes = 0 } = {}) => {
    const remaining = events.filter(entry => entry.timestamp >= now - MAX_AGE);
    // Keep the same epoch and a monotonic high water mark across compaction.
    if (Buffer.byteLength(header()) + reserveBytes > MAX_BYTES) throw Error('storage_error');
    const retained = remaining.slice(-(MAX_EVENTS - reserveEvents));
    const lines = retained.map(entry => JSON.stringify(entry) + '\n');
    let size = Buffer.byteLength(header()) + lines.reduce((total, line) => total + Buffer.byteLength(line), 0);
    while (size + reserveBytes > MAX_BYTES) {
      size -= Buffer.byteLength(lines.shift());
      retained.shift();
    }
    const text = header() + lines.join('');
    atomicProtected(path, text);
    events = retained; bytes = size;
  };
  const store = {
    emit(event) {
      if (failed) return false;
      if (!validate(event)) {
        // Schema drift is visible to the reader without retaining rejected input.
        rejectedEventsSinceStart = Math.min(Number.MAX_SAFE_INTEGER, rejectedEventsSinceStart + 1);
        return false;
      }
      if (seq >= Number.MAX_SAFE_INTEGER) { failed = true; return false; }
      try {
        const now = Date.now();
        const next = { event: event.event, run_id: event.run_id, task_id: event.task_id,
          ...Object.fromEntries(Object.keys(schema[event.event]).filter(key => event[key] !== undefined).map(key => [key, event[key]])),
          ...(event.task_count !== undefined && { task_count: event.task_count }), timestamp: now, seq: seq + 1 };
        const line = JSON.stringify(next) + '\n';
        const lineBytes = Buffer.byteLength(line);
        if (events.length + 1 > MAX_EVENTS || bytes + lineBytes > MAX_BYTES ||
            events.length && events[0].timestamp < now - MAX_AGE)
          compact(now, { reserveEvents: 1, reserveBytes: lineBytes });
        protectedFile(path);
        const fd = openSync(path, constants.O_WRONLY | constants.O_APPEND | constants.O_NOFOLLOW);
        try {
          const stat = fstatSync(fd);
          if (!stat.isFile() || stat.uid !== process.getuid() || stat.nlink !== 1 || stat.mode & 0o077) throw Error('storage_error');
          writeSync(fd, line); fsyncSync(fd);
        } finally { closeSync(fd); }
        seq++; events.push(next); bytes += lineBytes;
        return true;
      } catch { failed = true; return false; }
    },
    async read({ after, limit = 100 } = {}) {
      if (failed) throw Error('storage_error');
      if (!integer(limit, 200) || limit < 1) throw Error('invalid_limit');
      const cursor = after === undefined ? null : decode(after);
      try {
        if (events.length && events[0].timestamp < Date.now() - MAX_AGE) compact(Date.now());
      } catch { failed = true; throw Error('storage_error'); }
      const first = events[0]?.seq ?? seq + 1;
      const gap = cursor !== null && (cursor[0] !== epoch || cursor[1] < first - 1 || cursor[1] > seq);
      const position = cursor && !gap ? cursor[1] : first - 1;
      const available = events.filter(entry => entry.seq > position);
      const page = available.slice(0, limit);
      return { events: page.map(entry => ({ ...entry, ...(entry.probabilities && { probabilities: [...entry.probabilities] }) })),
        cursor: encode(epoch, page.at(-1)?.seq ?? (gap ? first - 1 : position)),
        has_more: available.length > page.length, rejected_events_since_start: rejectedEventsSinceStart,
        ...(gap && { gap: true }) };
    },
    close() { /* no open handles; singleton lives for the gateway lifetime */ },
  };
  instances.set(root, store);
  return store;
}
