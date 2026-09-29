import { createHash } from 'node:crypto';

// The synthetic CLICK exists only in the classification menu; it is never dispatched.
const CONTINUE = 'CLICK button "Continue existing workflow" (Advance the original goal using an observed legal action) [e1]';
const CHECKPOINT = 'STOP request human checkpoint';
const ESCALATE = 'ESCALATE cannot proceed safely';
const metaChoices = [CONTINUE, CHECKPOINT, ESCALATE];
const kind = choice => choice === CONTINUE ? 'continue' : choice === CHECKPOINT ? 'checkpoint' :
  choice === ESCALATE ? 'escalate' : String(choice ?? '').split(' ')[0].toLowerCase();

function assess(answer, choices) {
  const probs = answer?.probabilities;
  if (!probs || typeof probs !== 'object' || Array.isArray(probs) ||
      Object.keys(probs).length !== choices.length || choices.some(c => !Object.hasOwn(probs, c) ||
        !Number.isFinite(probs[c]) || probs[c] < 0 || probs[c] > 1) ||
      Math.abs(Object.values(probs).reduce((total, p) => total + p, 0) - 1) > 0.001 ||
      !choices.includes(answer.choice) || !Number.isFinite(answer.latency_ms) || answer.latency_ms < 0)
    throw Error('invalid_model_output');
  const ranked = choices.map(c => probs[c]).sort((a, b) => b - a);
  return { confidence: ranked[0], margin: ranked[0] - (ranked[1] ?? 0),
    accepted: probs[answer.choice] === ranked[0] && ranked[0] >= 0.5 &&
      ranked[0] - (ranked[1] ?? 0) >= 0.05 };
}

const observationId = state => createHash('sha256').update(JSON.stringify([
  state.title, state.text, state.fields.map(f => [f.label, f.context, f.value]),
])).digest('hex');
const observedStage = title => {
  const match = /\b(?:stage|receipt)\s+(\d{1,3})\s+of\s+(\d{1,3})\b/i.exec(title ?? '');
  if (!match) return 'not shown';
  const current = Number(match[1]), total = Number(match[2]);
  return current > 0 && total >= current ? `${current} of ${total}` : 'not shown';
};

/** Fixture-only binary progress gate followed by an unchanged legal-action decision. */
export function createPolicy({ bridge, onEvent, mode = 'plain' } = {}) {
  if (typeof bridge !== 'function' || !['plain', 'memory'].includes(mode)) throw Error('invalid_policy_configuration');
  let memory = { goal: null, previousObservation: null, repeats: 0, decisions: [] };
  const emit = detail => { try { onEvent?.(detail); } catch { /* observation only */ } };
  return async function decide(input, { signal } = {}) {
    const { state, choices } = input;
    if (memory.goal !== state.goal) memory = { goal: state.goal, previousObservation: null, repeats: 0, decisions: [] };
    const id = observationId(state);
    memory.repeats = memory.previousObservation === id ? Math.min(memory.repeats + 1, 9) : 0;
    memory.previousObservation = id;
    const stage = observedStage(state.title);
    const history = mode === 'memory' ? `Observed heading stage: ${stage}. ` +
      `Previous decisions: ${memory.decisions.join(', ') || 'none'}. Same observation: ${memory.repeats}. ` : '';
    const metaState = { ...state, text: `Choose CONTINUE for task progress, STOP only for a caller checkpoint, ` +
      `ESCALATE if unsafe. A checkpoint is not business completion. ${history}${state.text}` };
    let meta;
    try { meta = await bridge({ state: metaState, choices: metaChoices }, { signal }); }
    catch (error) {
      emit({ event: 'binary_meta', mode, choice_kind: 'no_answer', candidates: metaChoices.length,
        accepted: false, reason: error.message, observed_stage: stage,
        repeat_observations: memory.repeats, history_labels: [...memory.decisions] });
      throw error;
    }
    const metaScore = assess(meta, metaChoices);
    emit({ event: 'binary_meta', mode, choice_kind: kind(meta.choice), candidates: metaChoices.length,
      accepted: metaScore.accepted, confidence: metaScore.confidence, margin: metaScore.margin,
      observed_stage: stage, repeat_observations: memory.repeats, history_labels: [...memory.decisions] });
    if (!metaScore.accepted) throw Error('uncertain');
    memory.decisions = [...memory.decisions, kind(meta.choice)].slice(-2);
    if (meta.choice !== CONTINUE) {
      const requested = meta.choice === CHECKPOINT ? 'STOP ' : 'ESCALATE ';
      const legal = choices.find(c => c.startsWith(requested));
      const escalation = choices.find(c => c.startsWith('ESCALATE '));
      const actual = legal ?? escalation;
      if (!actual) throw Error('invalid_model_output');
      emit({ event: 'binary_action', mode, choice_kind: actual.startsWith('STOP ') ? 'checkpoint' : 'escalate',
        candidates: choices.length, accepted: true, confidence: 1, margin: 1,
        source: legal ? 'legal_checkpoint_or_escalation' : 'checkpoint_unavailable',
        history_labels: [...memory.decisions] });
      return { choice: actual, probabilities: Object.fromEntries(choices.map(c => [c, Number(c === actual)])),
        latency_ms: meta.latency_ms };
    }
    // No filtering or preference for clicks: the model sees all original actions, including STOP and ESCALATE.
    const actionState = mode === 'memory' ? { ...state,
      text: `${history}STOP means caller checkpoint, not business completion. ${state.text}` } : state;
    let answer;
    try { answer = await bridge({ state: actionState, choices }, { signal }); }
    catch (error) {
      emit({ event: 'binary_action', mode, choice_kind: 'no_answer', candidates: choices.length,
        accepted: false, reason: error.message, history_labels: [...memory.decisions] });
      throw error;
    }
    const score = assess(answer, choices);
    emit({ event: 'binary_action', mode, choice_kind: kind(answer.choice), candidates: choices.length,
      accepted: score.accepted, confidence: score.confidence, margin: score.margin,
      history_labels: [...memory.decisions] });
    if (!score.accepted) throw Error('uncertain');
    return answer;
  };
}
