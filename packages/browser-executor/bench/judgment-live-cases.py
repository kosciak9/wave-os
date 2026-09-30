#!/usr/bin/env python3
"""Freeze four observed synthetic Camofox transitions as separate offline judgments.

The model-facing projection is performed by judgment-engine.py. These are
counterfactual replay cases, not the payloads sent during the original run.
"""

import argparse
import hashlib
import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURE_SHA256 = 'b409daf0b142a6a6c1b02e6d2c16c532dc96341bf94714526762d58a2f2343e7'
QUESTIONS = {
    'candidate_continues_goal': 'Does the candidate action safely advance the current goal?',
    'post_action_intended_effect_observed': 'Does the after-state show the intended local effect of the candidate action?',
}
CASES = (
    ('normal_submit', 0, 'Submit stage details', 'Archive inquiry stage 1 of 12', 'Details receipt 1 of 12', 'YES'),
    ('normal_continue', 0, 'Continue inquiry', 'Details receipt 1 of 12', 'Archive inquiry stage 2 of 12', 'YES'),
    ('wrong_south_branch', 1, 'South Pier archive', 'Choose archive directory', 'South Pier archive unavailable', 'NO'),
    ('restart_after_final', 2, 'Start another request', 'Final receipt', 'Archive inquiry stage 1 of 12', 'NO'),
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def frozen_goals():
    source = (HERE / 'space-fixtures.js').read_bytes()
    if digest(source) != FIXTURE_SHA256:
        raise ValueError('fixture_source_changed')
    goals = dict(re.findall(r"\['(space-0[124])', '([^']+)', '[^']+'\]", source.decode()))
    if set(goals) != {'space-01', 'space-02', 'space-04'}:
        raise ValueError('fixture_goals_unavailable')
    return goals


def convert(source):
    goals = frozen_goals()
    result = json.loads(source.read_text())
    captures = result['captures']
    if len(captures) < 3 or any(captures[i]['backend'] != 'laya' or len(captures[i]['rows']) != 1
                                for i in range(3)):
        raise ValueError('unexpected_source_capture_order')
    output = []
    for name, capture_index, label, before_title, after_title, expected in CASES:
        capture = captures[capture_index]
        row = capture['rows'][0]
        matches = [(index, event) for index, event in enumerate(row['rows'])
                   if event.get('kind') == 'post' and event['candidate']['text'] == label and
                   event['before']['title'] == before_title and
                   event['after']['title'] == after_title]
        if not matches or capture_index != 0 and len(matches) != 1 or row.get('error') or row.get('runner_error'):
            raise ValueError('transition_missing_or_ambiguous_' + name)
        # The normal run overran and revisited stage 1: freeze its first visit.
        event_index, event = matches[0]
        if name == 'wrong_south_branch' and not row['oracle']['first_error_server_step'] or (
                name == 'restart_after_final' and not row['oracle']['post_success_overrun']):
            raise ValueError('negative_outcome_unverified_' + name)
        if not event['technical_state_changed']:
            raise ValueError('not_an_observed_transition_' + name)
        before, after = event['before'], event['after']
        fields = [{'ref': f'f{i}', 'role': 'textbox', 'name': field['name'],
                   'label': field['label'], 'context': before['title'], 'value': field['value']}
                  for i, field in enumerate(before['fields'], 1)]
        control = {**event['candidate'], 'ref': 'c1'}
        evidence = {'goal': goals[row['task']], 'title': before['title'], 'text': before['text'],
                    'fields': fields, 'required_facts': {}, 'controls': [control],
                    'pages_seen': [], 'recent_actions': []}
        output.append({'id': name,
            'provenance': {'kind': 'frozen_live_synthetic_transition_counterfactual',
                           'source_sha256': digest(source.read_bytes()),
                           'source_capture_index': capture_index, 'source_row_index': 0,
                           'source_event_index': event_index, 'fixture_sha256': FIXTURE_SHA256,
                           'not_original_live_model_payload': True},
            'evidence': evidence, 'candidate': {'control_ref': 'c1'},
            'transition': {'after': after, 'intended_local_effect': event['intended_local_effect']},
            'judgments': {
                'candidate_continues_goal': {'expected': expected,
                    'basis': 'The candidate either continues the observed operation or conflicts with its stated goal.'},
                'post_action_intended_effect_observed': {'expected': expected,
                    'basis': 'The observed next page either establishes the local effect or contradicts it.'}},
        })
    payload = {'schema_version': 1, 'capture_type': 'counterfactual_replay_of_observed_synthetic_pairs',
               'questions': QUESTIONS, 'cases': output}
    # Reject original run URLs/IDs, native refs, answer keys in the model-facing data.
    for case in output:
        model_data = json.dumps({'evidence': case['evidence'], 'candidate': case['candidate'],
                                 'transition': case['transition']})
        if re.search(r'https?://|/space/run/|\[e\d+\]|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', model_data, re.I):
            raise ValueError('unsafe_model_evidence')
        if '"expected"' in model_data or '"oracle"' in model_data or case['id'] in model_data:
            raise ValueError('answer_or_id_leak')
    return payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if args.output.exists() or not args.output.parent.is_dir():
        parser.error('output must be a new file in an existing directory')
    args.output.write_text(json.dumps(convert(args.source), ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
