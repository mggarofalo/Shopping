#!/usr/bin/env python3
"""Reject a release archive that omitted the iOS 27 Siri schema or restored item phrases."""
import argparse
import json
import plistlib
from pathlib import Path


def validate(app):
    app = Path(app)
    metadata = json.loads((app / 'Metadata.appintents/extract.actionsdata').read_text())
    action = metadata.get('actions', {}).get('AddSpokenGroceryIntent', {})
    schemas = action.get('assistantDefinedSchemas', [])
    if not any(s.get('domain') == 'reminders' and s.get('name') == 'CreateReminderIntent' for s in schemas):
        raise ValueError('Missing Siri create-reminder schema; build this release with Xcode 27.')
    parameters = {p['name']: p for p in action.get('parameters', [])}
    if parameters.get('title', {}).get('valueType', {}).get('primitive', {}).get('wrapper', {}).get('typeIdentifier') != 0:
        raise ValueError('Siri item title must be a free-form String.')
    if action.get('authenticationPolicy') != 2:
        raise ValueError('Siri add must require local device authentication.')
    # Observed Xcode 27 encoding: background 1, dynamic foreground 8 (openAppWhenRun is 2).
    # The deprecated ForegroundContinuableIntent declared foreground-only (8) (SHOPPING-258).
    if action.get('supportedModes', 0) & 9 != 9:
        raise ValueError('Siri add must run in the background and continue in the foreground only when needed.')
    shortcuts = metadata.get('autoShortcuts', [])
    if {s.get('actionIdentifier') for s in shortcuts} != {'AddGroceryIntent', 'SearchCatalogIntent'} or len(shortcuts) != 2:
        raise ValueError('Expected only static Add and Search App Shortcuts.')
    for shortcut in shortcuts:
        for phrase in shortcut.get('phraseTemplates', []):
            text = phrase.get('key', '').replace('${applicationName}', '')
            if '${' in text:
                raise ValueError('Shortcut trigger phrases must not enumerate catalog parameters.')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    names = [s.get('INAlternativeAppName') for s in info.get('INAlternativeAppNames', [])]
    if 'Milk and Bananas' not in names:
        raise ValueError('Missing spoken app-name synonym.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    validate(args.app)
    print('Siri schema, authentication, and catalog-independent phrase metadata verified.')
