import { createHash, randomBytes } from 'node:crypto';
import { constants, closeSync, fchmodSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeSync } from 'node:fs';
import { dirname, isAbsolute, join, parse, resolve } from 'node:path';
import process from 'node:process';

const instances = new Map();
const MAX_ENTRIES = 256;
const validTab = tab => typeof tab === 'string' && /^[\w-]{1,128}$/.test(tab);
const validScope = scope => typeof scope === 'string' && scope.length > 0 && scope.length <= 512 &&
  scope === scope.trim() && !/[\x00-\x1f\x7f]/.test(scope);
const keyFor = (scope, tab) => {
  if (!validScope(scope) || !validTab(tab)) throw Error('invalid_tab_scope');
  return createHash('sha256').update(JSON.stringify([scope, tab])).digest('hex');
};

// Only a trusted, absolute deployment path is accepted. Neither tool arguments nor
// model-visible text may reach this function. Never follow a symlink at any level.
export function protectedDirectory(directory) {
  if (typeof directory !== 'string' || !isAbsolute(directory) || directory !== resolve(directory) ||
      directory === parse(directory).root)
    throw Error('invalid_store_directory');
  const parts = directory.slice(parse(directory).root.length).split('/').filter(Boolean);
  let current = parse(directory).root;
  for (let i = 0; i < parts.length; i++) {
    current = join(current, parts[i]);
    let stat;
    try { stat = lstatSync(current); }
    catch (error) {
      if (error.code !== 'ENOENT' || i !== parts.length - 1) throw Error('unsafe_store_directory');
      mkdirSync(current, { mode: 0o700 });
      stat = lstatSync(current);
    }
    if (!stat.isDirectory() || (stat.uid !== process.getuid() && stat.uid !== 0) ||
        (i === parts.length - 1 && (stat.uid !== process.getuid() || stat.mode & 0o077)) ||
        (i !== parts.length - 1 && stat.mode & 0o022 && !(stat.uid === 0 && stat.mode & 0o1000)))
      throw Error('unsafe_store_directory');
  }
  return directory;
}

export function protectedFile(path) {
  let stat;
  try { stat = lstatSync(path); }
  catch (error) { if (error.code === 'ENOENT') return false; throw Error('storage_error'); }
  if (!stat.isFile() || stat.uid !== process.getuid() || stat.nlink !== 1 || stat.mode & 0o077)
    throw Error('storage_error');
  return true;
}

export function readProtected(path) {
  if (!protectedFile(path)) return null;
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.uid !== process.getuid() || stat.nlink !== 1 || stat.mode & 0o077)
      throw Error('storage_error');
    return readFileSync(fd, 'utf8');
  } finally { closeSync(fd); }
}

export function atomicProtected(path, text) {
  protectedFile(path);
  const temp = join(dirname(path), `.browser-${randomBytes(16).toString('hex')}`);
  let fd;
  try {
    fd = openSync(temp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    fchmodSync(fd, 0o600);
    writeSync(fd, text);
    fsyncSync(fd);
    closeSync(fd); fd = undefined;
    renameSync(temp, path);
    const dir = openSync(dirname(path), constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    try { fsyncSync(dir); } finally { closeSync(dir); }
  } catch {
    if (fd !== undefined) closeSync(fd);
    try { unlinkSync(temp); } catch { /* rename may have succeeded */ }
    throw Error('storage_error');
  }
}

/** Process-local singleton: one gateway process owns the directory; external
 * writers or multiple gateway processes require an exclusive deployment lock.
 * The ledger survives process restarts; no age-based quarantine eviction exists.
 */
export function createTabState(directory) {
  const root = protectedDirectory(directory);
  if (instances.has(root)) return instances.get(root);
  const path = join(root, 'tab-ledger.json');
  let entries;
  try {
    const text = readProtected(path);
    const ledger = text === null ? { version: 2, entries: {} } : JSON.parse(text);
    if (!ledger || typeof ledger !== 'object' || Array.isArray(ledger) ||
        Object.keys(ledger).toSorted().join(',') !== 'entries,version' || ledger.version !== 2)
      throw Error('storage_error');
    entries = ledger.entries;
    if (!entries || Array.isArray(entries) || typeof entries !== 'object' ||
        Object.keys(entries).length > MAX_ENTRIES || Object.entries(entries).some(([key, value]) =>
          !/^[0-9a-f]{64}$/.test(key) || !value || typeof value !== 'object' ||
          !/^[0-9a-f]{32}$/.test(value.operation) || !Number.isSafeInteger(value.started) ||
          value.started < 0 || !validScope(value.scope) || !validTab(value.tabId) ||
          keyFor(value.scope, value.tabId) !== key ||
          Object.keys(value).toSorted().join(',') !== 'operation,scope,started,tabId'))
      throw Error('storage_error');
    if (new Set(Object.values(entries).map(value => value.operation)).size !== Object.keys(entries).length)
      throw Error('storage_error');
  } catch { throw Error('storage_error'); }
  const active = new Set();
  let failed = false;
  const save = next => {
    if (failed) throw Error('storage_error');
    try { atomicProtected(path, JSON.stringify({ version: 2, entries: next })); entries = next; }
    catch { failed = true; throw Error('storage_error'); }
  };
  const allowed = key => !failed && !active.has(key) && !Object.hasOwn(entries, key);
  const state = {
    isAllowed(scope, tabId) { return allowed(keyFor(scope, tabId)); },
    inspect(scope, tabId) {
      const key = keyFor(scope, tabId);
      return { status: failed ? 'storage_error' : active.has(key) ? 'tab_busy' : Object.hasOwn(entries, key) ? 'tab_quarantined' : 'available',
        ...(!failed && !active.has(key) && Object.hasOwn(entries, key) && { incidentId: entries[key].operation }) };
    },
    // Trusted operator handler only. Never register incident lookup as an agent tool.
    incident(incidentId) {
      if (failed) throw Error('storage_error');
      if (typeof incidentId !== 'string' || !/^[0-9a-f]{32}$/.test(incidentId)) throw Error('invalid_incident');
      const found = Object.values(entries).find(value => value.operation === incidentId);
      return found ? { scope: found.scope, tabId: found.tabId, started: found.started } : null;
    },
    acquire(scope, tabId) {
      const key = keyFor(scope, tabId);
      if (!allowed(key)) throw Error(failed ? 'storage_error' : active.has(key) ? 'tab_busy' : 'tab_quarantined');
      active.add(key);
      let released = false, marked = false;
      return {
        markMutation() {
          if (released || marked) throw Error('invalid_lease');
          if (Object.keys(entries).length >= MAX_ENTRIES) throw Error('quarantine_capacity');
          // Durable BEFORE dispatch. A crash or a lost response leaves quarantine.
          const incidentId = randomBytes(16).toString('hex');
          save({ ...entries, [key]: { operation: incidentId, started: Date.now(), scope, tabId } });
          marked = true;
          return incidentId;
        },
        release({ outcome } = {}) {
          if (released || !['verified', 'not_dispatched', 'unknown'].includes(outcome) ||
              outcome === 'verified' && !marked) throw Error('invalid_lease');
          // not_dispatched is valid only when the trusted caller knows no remote
          // effect was possible; unknown retains the durable quarantine.
          if (marked && outcome !== 'unknown') save(Object.fromEntries(Object.entries(entries).filter(([id]) => id !== key)));
          released = true;
          active.delete(key);
        },
      };
    },
    async trustedRecover(scope, tabId, { freshVerified, confirm } = {}) {
      const key = keyFor(scope, tabId);
      if (typeof freshVerified !== 'function' || typeof confirm !== 'function') throw Error('invalid_recovery');
      if (failed) throw Error('storage_error');
      if (active.has(key) || !Object.hasOwn(entries, key)) return false;
      active.add(key);
      try {
        if (await freshVerified() !== true || await confirm() !== true) return false;
        save(Object.fromEntries(Object.entries(entries).filter(([id]) => id !== key)));
        return true;
      } finally { active.delete(key); }
    },
  };
  instances.set(root, state);
  return state;
}
