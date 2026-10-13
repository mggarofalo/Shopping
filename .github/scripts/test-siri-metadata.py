#!/usr/bin/env python3
"""Check that release metadata rejects omitted or expanded voice integrations."""
import importlib.util
import json
import plistlib
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('validator', Path(__file__).with_name('validate-siri-metadata.py'))
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class SiriMetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.app = Path(self.directory.name)
        (self.app / 'Metadata.appintents').mkdir()
        self.action = {
            'assistantDefinedSchemas': [{'domain': 'reminders', 'name': 'CreateReminderIntent'}],
            'authenticationPolicy': 2,
            'parameters': [{'name': 'title', 'valueType': {'primitive': {'wrapper': {'typeIdentifier': 0}}}}],
        }
        self.metadata = {'actions': {'AddSpokenGroceryIntent': self.action}, 'autoShortcuts': [
            {'actionIdentifier': name, 'phraseTemplates': [{'key': 'Add in ${applicationName}'}]}
            for name in ('AddGroceryIntent', 'SearchCatalogIntent')
        ]}
        self.info = {'INAlternativeAppNames': [{'INAlternativeAppName': 'Milk and Bananas'}]}

    def validate(self):
        (self.app / 'Metadata.appintents/extract.actionsdata').write_text(json.dumps(self.metadata))
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(self.info))
        validator.validate(self.app)

    def test_current_schema_and_static_shortcuts_pass(self):
        self.validate()

    def test_missing_schema_fails(self):
        self.action['assistantDefinedSchemas'] = []
        with self.assertRaisesRegex(ValueError, 'Missing Siri'):
            self.validate()

    def test_entity_title_fails(self):
        self.action['parameters'][0]['valueType'] = {'entity': {'typeName': 'CatalogItemEntity'}}
        with self.assertRaisesRegex(ValueError, 'free-form String'):
            self.validate()

    def test_unauthenticated_action_fails(self):
        self.action['authenticationPolicy'] = 0
        with self.assertRaisesRegex(ValueError, 'authentication'):
            self.validate()

    def test_catalog_phrase_fails(self):
        self.metadata['autoShortcuts'][0]['phraseTemplates'][0]['key'] = 'Add ${catalogItem} in ${applicationName}'
        with self.assertRaisesRegex(ValueError, 'enumerate catalog'):
            self.validate()

    def test_extra_shortcut_fails(self):
        self.metadata['autoShortcuts'].append({'actionIdentifier': 'OpenGroceryListIntent'})
        with self.assertRaisesRegex(ValueError, 'only static Add and Search'):
            self.validate()

    def test_missing_spoken_name_fails(self):
        self.info = {}
        with self.assertRaisesRegex(ValueError, 'spoken app-name'):
            self.validate()


if __name__ == '__main__':
    unittest.main()
