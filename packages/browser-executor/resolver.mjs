const norm = value => String(value ?? '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
const aliases = [
  ['to', 'destination'], ['from', 'origin'], ['guests', 'party', 'party size', 'number of guests'],
  ['seat', 'seat preference'],
];
const related = (a, b) => aliases.some(group => group.includes(norm(a)) && group.includes(norm(b)));
const contextMatch = (actual, expected) => {
  const parts = value => String(value ?? '').split('/').map(norm).filter(Boolean);
  const a = parts(actual), b = parts(expected);
  return b.length > 0 && a.length >= b.length && b.every((part, i) => part === a[a.length - b.length + i]);
};
const label = field => ({ field: field.label, context: field.context });

/** Pure, value-independent field alignment. Never infer a field from its value. */
export function resolveSemanticFields({ fields, facts, bindings = {}, useAliases = true, useContext = true }) {
  const entries = Object.entries(facts).filter(([, value]) => value !== '');
  const target = useContext && typeof facts.target === 'string' ? norm(facts.target) : '';
  const contexts = [...new Set(fields.map(f => f.context).filter(Boolean))];
  const matchingContexts = target ? contexts.filter(c => c.split('/').some(part => norm(part) === target)) : [];
  const activeContext = matchingContexts.length === 1 ? matchingContexts[0] : null;
  const active = activeContext ? fields.filter(f => contextMatch(f.context, activeContext)) : fields;
  const search = active.filter(f => f.type === 'search' || f.axRole === 'searchbox' ||
    norm(f.label).split(' ').includes('search') && ['q', 'query', 'search'].includes(norm(f.name)));
  const candidates = new Map();
  for (const [key] of entries) {
    if (key === 'target' && !Object.hasOwn(bindings, key) && search.length !== 1) continue;
    const spec = bindings[key];
    if (key === 'target' && !spec) {
      candidates.set(key, { matches: search, evidence: 'type' });
      continue;
    }
    const expected = typeof spec === 'string' ? spec : spec?.field;
    const pool = active.filter(f => !spec || (typeof spec === 'string' || contextMatch(f.context, spec.context)));
    const by = (property, match) => pool.filter(f => match(f[property]));
    const exactLabel = by('label', value => norm(value) === norm(expected ?? key));
    const exactName = by('name', value => norm(value) && norm(value) === norm(expected ?? key));
    let matches = exactLabel, evidence = 'exactLabel';
    if (exactLabel.length && exactName.length && exactLabel.some(f => !exactName.includes(f)) &&
        exactName.some(f => !exactLabel.includes(f))) {
      matches = [...new Set([...exactLabel, ...exactName])]; evidence = 'conflict';
    } else if (!matches.length) { matches = exactName; evidence = 'exactName'; }
    if (!matches.length && !spec && useAliases) {
      matches = by('label', value => related(key, value)); evidence = 'alias';
      if (!matches.length) matches = by('name', value => related(key, value));
    }
    if (!matches.length && !spec && ['q', 'query', 'search', 'target'].includes(norm(key)) && search.length === 1) {
      matches = search; evidence = 'type';
    }
    if (!matches.length && !spec && norm(key).length > 3 && !['from', 'to', 'origin', 'destination', 'target'].includes(norm(key))) {
      const near = pool.filter(f => [f.label, f.name].some(value => {
        const a = norm(value), b = norm(key);
        return a && (a.startsWith(`${b} `) || b.startsWith(`${a} `)) && a.length > 3;
      }));
      if (near.length === 1) { matches = near; evidence = 'alias'; }
    }
    candidates.set(key, { matches, evidence });
  }
  const assignments = [], problems = [];
  for (const [key, { matches, evidence }] of candidates) {
    if (!matches.length) continue; // A future fact is not missing on this page.
    const competitors = [...candidates].filter(([other, item]) => other !== key &&
      item.matches.some(f => matches.includes(f))).map(([other]) => other);
    if (matches.length !== 1 || competitors.length || evidence === 'conflict') {
      problems.push({ kind: 'ambiguous_mapping', field: matches[0]?.label ?? key,
        fact_keys: [key, ...competitors].slice(0, 8),
        candidates: matches.slice(0, 6).map(label), context: matches[0]?.context });
      continue;
    }
    const field = matches[0];
    if (field.tag === 'select' && (field.optionsTruncated ||
        (field.options ?? []).filter(o => o.value === facts[key] || o.label === facts[key]).length !== 1)) {
      problems.push({ kind: field.optionsTruncated ? 'ambiguous_mapping' : 'unsupported_choice',
        field: field.label, fact_keys: [key],
        options: (field.options ?? []).slice(0, 8).map(o => ({ label: o.label, value: o.value })),
        context: field.context });
      continue;
    }
    assignments.push({ key, field, evidence: activeContext && evidence !== 'conflict' ? 'context' : evidence });
  }
  for (const field of active) {
    if (assignments.some(a => a.field === field) || problems.some(p => p.field === field.label && p.context === field.context)) continue;
    const unmatched = entries.filter(([key]) => key !== 'target' && !candidates.get(key)?.matches.length);
    if (field.tag === 'select' && unmatched.length === 1) {
      problems.push({ kind: 'ambiguous_mapping', field: field.label, fact_keys: [unmatched[0][0]],
        candidates: [label(field)], options: (field.options ?? []).slice(0, 8).map(o => ({ label: o.label, value: o.value })),
        context: field.context });
      continue;
    }
    const unassigned = active.filter(f => !assignments.some(a => a.field === f) &&
      !problems.some(p => p.field === f.label && p.context === f.context));
    if (unassigned.length === 1 && unmatched.length === 1 && field.tag !== 'select') {
      problems.push({ kind: 'ambiguous_mapping', field: field.label, fact_keys: [unmatched[0][0]],
        candidates: [label(field)], proposed_mapping: 'unknown', context: field.context });
      continue;
    }
    problems.push({ kind: 'missing_fact', field: field.label,
      options: (field.options ?? []).slice(0, 8).map(o => ({ label: o.label, value: o.value })),
      context: field.context });
  }
  return { assignments, problems, activeContext, active };
}
