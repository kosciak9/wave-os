import { createHash } from 'node:crypto';

// These are categorical *planning* choices, not refs to browser controls.
const strategies = [
  ['prepare-known-fields', 'Prepare known fields', 'Match supplied facts to visible editable fields before advancing.'],
  ['advance-current-workflow', 'Advance current workflow', 'Choose a visible control that moves the original task forward.'],
  ['verify-terminal/handoff', 'Verify terminal or handoff', 'Inspect completion evidence and decide whether to checkpoint or continue.'],
  ['check-progress', 'Check progress', 'Reassess the current page and prior actions before choosing a safe next step.'],
];
const virtualChoices = strategies.map(([, label, description], i) =>
  `CLICK button "${label}" (${description}) [e${i + 1}]`);
const virtualEscalate = 'ESCALATE cannot proceed safely';
const limit = (value, length) => String(value ?? '').slice(0, length);
const fingerprint = state => createHash('sha256').update(JSON.stringify([
  state.title, state.text, state.fields.map(f => [f.label, f.context, f.value]),
])).digest('hex');

function checked(answer, choices) {
  const probs = answer?.probabilities;
  if (!probs || typeof probs !== 'object' || Array.isArray(probs) ||
      Object.keys(probs).length !== choices.length || choices.some(c =>
        !Object.hasOwn(probs, c) || !Number.isFinite(probs[c]) || probs[c] < 0 || probs[c] > 1) ||
      Math.abs(Object.values(probs).reduce((sum, value) => sum + value, 0) - 1) > 0.001 ||
      !choices.includes(answer.choice) || !Number.isFinite(answer.latency_ms) || answer.latency_ms < 0)
    throw Error('invalid_model_output');
  const ranked = choices.map(c => probs[c]).sort((a, b) => b - a);
  if (probs[answer.choice] !== ranked[0] || ranked[0] < 0.5 || ranked[0] - (ranked[1] ?? 0) < 0.05)
    throw Error('uncertain');
  return { confidence: ranked[0], margin: ranked[0] - (ranked[1] ?? 0) };
}

/** Fixture-only two-stage decision policy; the only dispatched actions come from input.choices. */
export function createPolicy({ bridge, onEvent } = {}) {
  if (typeof bridge !== 'function') throw Error('invalid_policy_bridge');
  let memory = { goal: null, last: null, repeats: 0, subgoal: null, previous: [] };
  const emit = event => { try { onEvent?.(event); } catch { /* telemetry cannot change decisions */ } };
  return async function decide(input, { signal } = {}) {
    const { state, choices } = input;
    if (memory.goal !== state.goal) memory = { goal: state.goal, last: null, repeats: 0, subgoal: null, previous: [] };
    const hash = fingerprint(state);
    memory.repeats = memory.last === hash ? Math.min(memory.repeats + 1, 9) : 0;
    memory.last = hash;
    const history = memory.previous.map((label, i) => `${i + 1}:${label}`).join(', ') || 'none';
    const context = `Last subgoal: ${memory.subgoal ?? 'none'}; previous strategies: ${history}; repeated observation: ${memory.repeats}.`;
    const metaState = { ...state,
      text: `Select a local strategy, not a browser action. Original goal remains binding. ${context} ` +
        `Visible evidence: ${limit(state.text, 260)}`,
    };
    const metaChoices = [...virtualChoices, virtualEscalate];
    const meta = await bridge({ state: metaState, choices: metaChoices }, { signal });
    let score;
    try { score = checked(meta, metaChoices); }
    catch (error) {
      emit({ event: 'strategy', label: 'refused', accepted: false, reason: error.message,
        repeat_observations: memory.repeats, candidates: metaChoices.length });
      throw error;
    }
    const index = virtualChoices.indexOf(meta.choice);
    const label = index < 0 ? 'escalate' : strategies[index][0];
    emit({ event: 'strategy', label, accepted: true, confidence: score.confidence,
      margin: score.margin, repeat_observations: memory.repeats, candidates: metaChoices.length });
    if (index < 0) {
      const escalation = choices.find(c => c.startsWith('ESCALATE '));
      if (!escalation) throw Error('invalid_model_output');
      return { choice: escalation, probabilities: Object.fromEntries(choices.map(c => [c, Number(c === escalation)])),
        latency_ms: meta.latency_ms };
    }
    memory.subgoal = label;
    memory.previous = [...memory.previous, label].slice(-2);
    // The original goal, actual observed fields, and full legal action menu stay intact.
    // Strategy context is bounded and placed first so both native and compact Kev see it.
    const actionState = { ...state,
      text: `Local strategy: ${label}. ${strategies[index][2]} Original goal remains binding. ` +
        `Previous strategies: ${history}; repeated observation: ${memory.repeats}. ` +
        `STOP means caller checkpoint, not business completion; compare receipt with full goal. ` +
        limit(state.text, 320),
    };
    const actual = await bridge({ state: actionState, choices }, { signal });
    // The core validates the actual distribution at the same threshold and margin.
    return actual;
  };
}
