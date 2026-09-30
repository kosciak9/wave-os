const norm = value => String(value ?? '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
export const contextMatches = (actual, expected) => {
  const parts = value => String(value ?? '').split('/').map(norm).filter(Boolean);
  const a = parts(actual), b = parts(expected);
  return b.length > 0 && a.length >= b.length && b.every((part, i) => part === a[a.length - b.length + i]);
};
const aliases = [['to', 'destination'], ['from', 'origin'], ['guests', 'party', 'party size', 'number of guests']];
const equivalent = (a, b) => norm(a) === norm(b) || aliases.some(group => group.includes(norm(a)) && group.includes(norm(b)));

// Mapping is based on observed labels, never on the value of a fact or a positional guess.
export function resolveSemanticFields({ fields, facts, bindings = {} }) {
  const assignments = [], problems = [];
  const candidateMap = new Map();
  for (const [key, value] of Object.entries(facts)) {
    if (value === '') continue;
    const binding = bindings[key];
    const label = binding?.label ?? key;
    const matches = fields.filter(field => binding ?
      norm(field.label) === norm(label) && contextMatches(field.context, binding.context) :
      equivalent(field.label, label) || Boolean(norm(field.name)) && norm(field.name) === norm(key));
    candidateMap.set(key, matches);
  }
  for (const field of fields) {
    const keys = [...candidateMap].filter(([, matches]) => matches.includes(field)).map(([key]) => key);
    const exact = keys.filter(key => candidateMap.get(key).length === 1);
    if (keys.length === 1 && exact.length === 1) {
      const key = keys[0], value = facts[key];
      if (field.tag === 'select' && (field.optionsTruncated ||
          (field.options ?? []).filter(o => o.value === value || o.label === value).length !== 1)) {
        problems.push({ kind: 'unsupported_choice', field, keys, options: field.options });
      } else assignments.push({ key, field });
    } else problems.push({ kind: keys.length ? 'ambiguous_mapping' : 'missing_fact', field, keys,
      options: field.tag === 'select' ? field.options : undefined });
  }
  return { assignments, problems };
}
