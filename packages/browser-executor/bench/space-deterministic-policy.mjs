// Fixed navigation comparators: neither mode interprets a unique click as proof of task completion.
const normalize = text => String(text).normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();

function matchesTarget(choice, target) {
  const click = /^CLICK (?:button|link|checkbox|radio) "([^"\n]+)" \(([^()\n]*)\) \[e\d+\]$/.exec(choice);
  if (!click || !target) return false;
  const phrase = normalize(target);
  return [click[1], click[2]].some(value => (` ${normalize(value)} `).includes(` ${phrase} `));
}

export function createPolicy({ bridge, onEvent, mode = 'unique' } = {}) {
  if (!['unique', 'structural'].includes(mode)) throw Error('invalid_deterministic_mode');
  // bridge is intentionally unused: both arms are local, zero-model policies.
  void bridge;
  return async function decide({ state, choices }, { signal } = {}) {
    if (signal?.aborted) throw signal.reason ?? Error('aborted');
    const actions = choices.filter(choice => !/^(?:STOP|ESCALATE) /.test(choice));
    const clicks = actions.filter(choice => choice.startsWith('CLICK '));
    const target = state?.variables?.target;
    const grounded = mode === 'structural' && typeof target === 'string' ?
      clicks.filter(choice => matchesTarget(choice, target)) : [];
    const selected = actions.length === 1 && clicks.length === 1 &&
      (mode === 'unique' || grounded.length === 1) ? clicks[0] :
      mode === 'structural' && actions.length === clicks.length && grounded.length === 1 ? grounded[0] : null;
    const reason = selected ? 'unique_action' : actions.length ? 'ambiguous_navigation' : 'no_actions';
    const choice = selected ?? choices.find(c => c.startsWith(`${actions.length ? 'ESCALATE' : 'STOP'} `)) ??
      choices.find(c => c.startsWith('ESCALATE '));
    if (!choice) throw Error('no_local_choice');
    try { onEvent?.({ event: 'policy', reason, choices_count: choices.length }); } catch { /* metadata only */ }
    return { choice, probabilities: Object.fromEntries(choices.map(c => [c, Number(c === choice)])), latency_ms: 0 };
  };
}
