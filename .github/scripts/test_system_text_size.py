#!/usr/bin/env python3
"""Failure/isolation contracts for the host Simulator driver, without a simulator."""
import importlib.util
from pathlib import Path
import time
import json
import os
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

spec = importlib.util.spec_from_file_location("driver", Path(__file__).with_name("with-system-text-size.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DriverTests(unittest.TestCase):
    def setUp(self):
        self.device = str(uuid.uuid4())
        self.lease = str(uuid.uuid4())
        self.sizes = {self.device: "large"}
        self.writes = []
        self.driver = module.Driver("test-token", self.command)

    def command(self, device, category=None, *, device_set):
        if category is not None:
            self.writes.append((device, category))
            self.sizes[device] = category
        return self.sizes[device]

    def request(self, operation, **changes):
        request = dict(id=str(uuid.uuid4()), token="test-token", device=self.device,
                       lease=self.lease, operation=operation, category=None, deviceSet="/simulators",
                       expires=time.time() + 15)
        request.update(changes)
        return request

    def acquire(self):
        result = self.driver.handle(self.request("acquire"))
        self.assertEqual(result["observed"], "large")

    def test_exact_readback_and_original_restoration(self):
        self.acquire()
        result = self.driver.handle(self.request("set", category="accessibility-extra-extra-extra-large"))
        self.assertEqual(result["observed"], "accessibility-extra-extra-extra-large")
        result = self.driver.handle(self.request("restore"))
        self.assertEqual(result["observed"], "large")
        self.driver.cleanup()
        self.assertFalse(self.driver.failed)
        self.assertEqual(len(self.writes), 2)

    def test_clone_devices_have_independent_originals(self):
        self.acquire()
        second = str(uuid.uuid4())
        self.sizes[second] = "small"
        self.driver.handle(self.request("acquire", device=second))
        self.driver.handle(self.request("set", device=second, category="extra-large"))
        self.driver.handle(self.request("restore", device=second))
        self.assertEqual(self.sizes, {self.device: "large", second: "small"})
        self.assertIn(self.device, self.driver.leases)

    def test_expired_request_never_mutates(self):
        self.acquire()
        result = self.driver.handle(self.request("set", category="small", expires=time.time() - 1))
        self.assertIn("error", result)
        self.assertEqual(self.writes, [])

    def test_wrong_token_never_mutates(self):
        self.acquire()
        self.assertIn("error", self.driver.handle(self.request("set", category="small", token="stale")))
        self.assertEqual(self.writes, [])

    def test_wrong_lease_never_mutates(self):
        self.acquire()
        self.assertIn("error", self.driver.handle(self.request("set", category="small", lease=str(uuid.uuid4()))))
        self.assertEqual(self.writes, [])

    def test_duplicate_request_is_not_replayed(self):
        self.acquire()
        request = self.request("set", category="small")
        self.driver.handle(request)
        self.assertIn("error", self.driver.handle(request))
        self.assertEqual(self.writes, [(self.device, "small")])

    def test_readback_mismatch_poisons_lease_until_restored(self):
        self.acquire()
        def no_effect(device, category=None, *, device_set):
            return "large"
        self.driver.command = no_effect
        self.assertIn("error", self.driver.handle(self.request("set", category="small")))
        self.driver.command = self.command
        self.assertIn("error", self.driver.handle(self.request("set", category="medium")))
        self.assertEqual(self.writes, [])
        self.assertNotIn("error", self.driver.handle(self.request("restore")))
        self.assertTrue(self.driver.failed)

    def test_timed_out_setter_finishes_before_restoration(self):
        self.acquire()
        request = self.request("set", category="small")
        with patch.object(module.time, "time", side_effect=[request["expires"] - 1, request["expires"] - 1, request["expires"] + 1]):
            self.assertIn("error", self.driver.handle(request))
        self.assertEqual(self.sizes[self.device], "small")
        self.driver.handle(self.request("restore"))
        self.assertEqual(self.writes, [(self.device, "small"), (self.device, "large")])

    def test_abandoned_lease_restores_and_prevents_success(self):
        self.acquire()
        self.driver.handle(self.request("set", category="small"))
        self.driver.cleanup()
        self.assertEqual(self.sizes[self.device], "large")
        self.assertTrue(self.driver.failed)

    def test_cleanup_failure_prevents_success(self):
        self.acquire()
        def broken(device, category=None, *, device_set):
            raise OSError("simulator unavailable")
        self.driver.command = broken
        self.driver.cleanup()
        self.assertTrue(self.driver.failed)

    def test_second_test_cannot_acquire_active_simulator(self):
        self.acquire()
        self.assertIn("error", self.driver.handle(self.request("acquire", lease=str(uuid.uuid4()))))
        self.assertEqual(self.driver.leases[self.device][0], self.lease)

    def test_wrong_device_set_cannot_change_an_active_lease(self):
        self.acquire()
        self.assertIn("error", self.driver.handle(self.request("set", category="small", deviceSet="/other-simulators")))
        self.assertEqual(self.writes, [])

    def test_unknown_category_never_mutates(self):
        self.acquire()
        self.assertIn("error", self.driver.handle(self.request("set", category="not-a-category")))
        self.assertEqual(self.writes, [])


class WrapperLifecycleTests(unittest.TestCase):
    def run_wrapper(self, exit_code=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state.json"
            state.write_text(json.dumps("large"))
            marker = root / "ready"
            fake = root / "xcrun"
            fake.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state = Path(os.environ['FAKE_SYSTEM_SIZE'])
assert sys.argv[1:4] == ['simctl', '--set', '/simulators']
assert sys.argv[4] == 'ui' and sys.argv[6] == 'content_size'
if len(sys.argv) == 8:
    state.write_text(json.dumps(sys.argv[7]))
else:
    print(json.loads(state.read_text()))
""")
            fake.chmod(0o755)
            child = root / "runner.py"
            child.write_text("""import json, os, signal, sys, time, uuid
from pathlib import Path
root = Path(os.environ['TEST_RUNNER_SHOPPING_SYSTEM_TEXT_SIZE_ROOT'])
token = os.environ['TEST_RUNNER_SHOPPING_SYSTEM_TEXT_SIZE_TOKEN']
assert os.environ['TEST_RUNNER_SHOPPING_SYSTEM_TEXT_SIZE_TIMEOUT'] == '255'
device, lease = str(uuid.uuid4()), str(uuid.uuid4())
for operation, category in [('acquire', None), ('set', 'small')]:
    identity = str(uuid.uuid4())
    request = dict(id=identity, token=token, device=device, lease=lease,
                   operation=operation, category=category, deviceSet="/simulators", expires=time.time()+15)
    path = root / (identity + '.request.json')
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(request))
    temporary.replace(path)
    response = root / (identity + '.response.json')
    deadline = time.monotonic()+5
    while not response.exists() and time.monotonic() < deadline:
        time.sleep(.02)
    assert 'error' not in json.loads(response.read_text())
Path(os.environ['FAKE_READY']).write_text('ready')
if sys.argv[1] == 'wait':
    signal.pause()
elif sys.argv[1] == 'signal':
    os.kill(os.getpid(), signal.SIGTERM)
else:
    sys.exit(int(sys.argv[1]))
""")
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                               FAKE_SYSTEM_SIZE=str(state), FAKE_READY=str(marker))
            process = subprocess.Popen([sys.executable, str(Path(__file__).with_name("with-system-text-size.py")),
                                        "--", sys.executable, str(child), "wait" if exit_code is None else str(exit_code)],
                                       env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                if exit_code is None:
                    deadline = time.monotonic() + 5
                    while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(.02)
                    self.assertTrue(marker.exists(), "Child did not acquire and mutate its lease")
                    process.send_signal(signal.SIGTERM)
                output, error = process.communicate(timeout=10)
                self.assertEqual(json.loads(state.read_text()), "large", output + error)
                return process.returncode
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

    def test_successful_child_with_abandoned_lease_is_failure(self):
        self.assertEqual(self.run_wrapper(0), 1)

    def test_child_failure_is_preserved_after_cleanup(self):
        self.assertEqual(self.run_wrapper(7), 7)

    def test_child_signal_status_is_preserved_after_cleanup(self):
        self.assertEqual(self.run_wrapper("signal"), 128 + signal.SIGTERM)

    def test_cancellation_restores_and_preserves_signal_failure(self):
        self.assertEqual(self.run_wrapper(), 128 + signal.SIGTERM)


if __name__ == "__main__":
    unittest.main()
