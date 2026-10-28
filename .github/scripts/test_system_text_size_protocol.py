#!/usr/bin/env python3
"""Adversarial ordering contracts; every clock, command and child is controlled."""
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid

import test_system_text_size as fixtures
from test_system_text_size import FakeClock, module


class ProtocolTests(unittest.TestCase):
    setUp = fixtures.DriverTests.setUp
    request = fixtures.DriverTests.request
    command = fixtures.DriverTests.command
    acquire = fixtures.DriverTests.acquire

    def test_acquire_read_failure_never_captures_an_original_or_mutates(self):
        self.driver.command = lambda *args, **kwargs: (_ for _ in ()).throw(OSError("read unavailable"))
        self.assertIn("error", self.driver.handle(self.request("acquire")))
        self.assertEqual(self.driver.leases, {})
        self.assertEqual(self.writes, [])
        self.driver.command = self.command
        self.acquire()
        self.assertTrue(self.driver.failed)

    def test_readback_timeout_requires_restore_before_next_lease(self):
        self.acquire()
        def command(device, category=None, *, device_set):
            if category is None:
                raise subprocess.TimeoutExpired("fake read", module.COMMAND_TIMEOUT_SECONDS)
            return self.command(device, category, device_set=device_set)
        self.driver.command = command
        self.assertIn("error", self.driver.handle(self.request("set", category="small")))
        self.assertEqual(self.sizes[self.device], "small")
        self.driver.command = self.command
        self.assertIn("error", self.driver.handle(self.request("acquire", lease=str(uuid.uuid4()))))
        self.assertIn("error", self.driver.handle(self.request("set", category="medium")))
        self.assertNotIn("error", self.driver.handle(self.request("restore")))
        self.lease = str(uuid.uuid4())
        self.acquire()
        self.assertEqual(self.writes, [(self.device, "small"), (self.device, "large")])
        self.assertTrue(self.driver.failed)

    def test_failed_set_can_have_mutated_and_cleanup_restores_original(self):
        self.acquire()
        def command(device, category=None, *, device_set):
            result = self.command(device, category, device_set=device_set)
            if category is not None:
                raise subprocess.TimeoutExpired("fake write", module.COMMAND_TIMEOUT_SECONDS)
            return result
        self.driver.command = command
        self.assertIn("error", self.driver.handle(self.request("set", category="small")))
        self.driver.command = self.command
        self.driver.cleanup()
        self.assertEqual(self.writes, [(self.device, "small"), (self.device, "large")])
        self.assertTrue(self.driver.failed)

    def test_failed_cleanup_quarantines_device_before_new_acquire(self):
        self.acquire()
        self.driver.handle(self.request("set", category="small"))
        self.driver.command = lambda *args, **kwargs: (_ for _ in ()).throw(OSError("offline"))
        self.driver.cleanup()
        self.driver.command = self.command
        self.assertIn("error", self.driver.handle(self.request("acquire", lease=str(uuid.uuid4()))))
        self.assertEqual(self.sizes[self.device], "small")
        self.assertTrue(self.driver.failed)

    def test_unknown_device_never_retargets_current_lease(self):
        self.acquire()
        result = self.driver.handle(self.request("set", device=str(uuid.uuid4()), category="small"))
        self.assertIn("error", result)
        self.assertEqual(self.writes, [])
        self.assertEqual(self.driver.leases[self.device], (self.lease, "large"))

    def test_future_deadline_and_malformed_identity_never_mutate(self):
        self.acquire()
        for change in ({"expires": self.clock.time() + module.REQUEST_TIMEOUT_SECONDS + 1},
                       {"id": "not-a-uuid"}, {"lease": 7}, {"device": []}, {"deviceSet": "relative/path"}):
            with self.subTest(change=change):
                self.assertIn("error", self.driver.handle(self.request("set", category="small", **change)))
        self.assertEqual(self.writes, [])

    def test_stale_old_lease_cannot_mutate_next_test(self):
        self.acquire()
        old = self.request("set", category="small")
        self.driver.handle(self.request("restore"))
        self.lease = str(uuid.uuid4())
        self.acquire()
        self.assertIn("error", self.driver.handle(old))
        self.assertEqual(self.writes, [(self.device, "large")])

    def test_clone_failure_does_not_poison_other_clone(self):
        self.acquire()
        second = str(uuid.uuid4())
        self.sizes[second] = "medium"
        second_lease = str(uuid.uuid4())
        self.driver.handle(self.request("acquire", device=second, lease=second_lease, deviceSet="/clone-set"))
        self.driver.handle(self.request("set", category="small", token="wrong"))
        self.assertNotIn("error", self.driver.handle(self.request(
            "set", device=second, lease=second_lease, deviceSet="/clone-set", category="extra-large")))
        self.assertNotIn("error", self.driver.handle(self.request(
            "restore", device=second, lease=second_lease, deviceSet="/clone-set")))
        self.assertEqual(self.sizes[second], "medium")
        self.assertTrue(self.driver.failed)

    def test_native_command_uses_exact_clone_device_set_and_bounded_timeout(self):
        calls = []
        def run(command, **kwargs):
            calls.append((command, kwargs))
            return subprocess.CompletedProcess(command, 0, stdout="medium\n")
        self.assertEqual(module.simulator_size(self.device, device_set="/clone-set", run=run, clock=self.clock), "medium")
        module.simulator_size(self.device, "large", device_set="/clone-set", run=run, clock=self.clock)
        self.assertEqual(calls[0][0], ["xcrun", "simctl", "--set", "/clone-set", "ui", self.device, "content_size"])
        self.assertEqual(calls[1][0], calls[0][0] + ["large"])
        self.assertTrue(all(options["timeout"] == module.COMMAND_TIMEOUT_SECONDS and options["check"] for _, options in calls))
        self.assertEqual(module.REQUEST_TIMEOUT_SECONDS, 4 * module.COMMAND_TIMEOUT_SECONDS + 15)

    def test_native_read_rejects_unsupported_original(self):
        with self.assertRaises(ValueError):
            module.simulator_size(self.device, device_set="/clone-set", clock=self.clock,
                run=lambda *args, **kwargs: subprocess.CompletedProcess([], 0, stdout="unknown"))


class InboxTests(unittest.TestCase):
    request = fixtures.DriverTests.request
    command = fixtures.DriverTests.command
    acquire = fixtures.DriverTests.acquire
    def setUp(self):
        fixtures.DriverTests.setUp(self)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def put(self, request):
        path = self.root / (request["id"] + ".request.json")
        path.write_text(json.dumps(request))
        return path

    def test_response_preserves_all_identity_fields_and_is_atomically_published(self):
        request = self.request("acquire")
        path = self.put(request)
        module.process_requests(self.root, self.driver)
        response = json.loads((self.root / (request["id"] + ".response.json")).read_text())
        for key in ("id", "token", "lease", "device", "deviceSet", "operation", "category"):
            self.assertEqual(response[key], request[key])
        self.assertFalse(path.exists())
        self.assertEqual(list(self.root.glob("*.tmp")), [])

    def test_pending_restore_runs_only_after_inflight_set_finishes(self):
        self.acquire()
        setter = self.request("set", category="small")
        self.put(setter)
        def delayed(device, category=None, *, device_set):
            result = self.command(device, category, device_set=device_set)
            if category == "small":
                self.clock.sleep(16)
                self.put(self.request("restore"))
            return result
        self.driver.command = delayed
        module.process_requests(self.root, self.driver)
        response = json.loads((self.root / (setter["id"] + ".response.json")).read_text())
        self.assertIn("error", response)
        self.assertEqual(self.writes, [(self.device, "small")])
        module.process_requests(self.root, self.driver)
        self.assertEqual(self.writes, [(self.device, "small"), (self.device, "large")])
        self.assertEqual(self.driver.leases, {})
        self.assertTrue(self.driver.failed)

    def test_malformed_or_misnamed_requests_fail_without_mutation(self):
        for payload in ([], "not json", {"id": str(uuid.uuid4())}):
            with self.subTest(payload=payload):
                path = self.root / (str(uuid.uuid4()) + ".request.json")
                path.write_text(json.dumps(payload) if payload != "not json" else payload)
                module.process_requests(self.root, self.driver)
                self.assertFalse(path.exists())
        self.assertTrue(self.driver.failed)
        self.assertEqual(self.writes, [])
        self.assertEqual(list(self.root.glob("*.response.json")), [])

    def test_cancellation_stops_queued_mutation(self):
        self.acquire()
        self.put(self.request("set", category="small"))
        module.process_requests(self.root, self.driver, lambda: True)
        self.assertEqual(self.writes, [])
        self.driver.cleanup()
        self.assertEqual(self.writes, [(self.device, "large")])
        self.assertTrue(self.driver.failed)


class FakeChild:
    pid = 12345
    def __init__(self, code=None):
        self.code = code
        self.waited = False
    def poll(self):
        return self.code
    def wait(self):
        self.waited = True
        return self.code


class SupervisionTests(unittest.TestCase):
    def test_stubborn_cancelled_child_is_killed_then_reaped_before_cleanup(self):
        clock = FakeClock()
        child = FakeChild()
        calls = []
        def kill(pid, signum):
            calls.append((pid, signum))
            child.code = -signum
        class Driver:
            failed = False
            def cleanup(self):
                self.assert_reaped = child.waited
        driver = Driver()
        with tempfile.TemporaryDirectory() as directory:
            result = module.supervise(child, Path(directory), driver,
                lambda: (signal.SIGTERM, 1000), clock=clock, killpg=kill)
        self.assertEqual(result, 128 + signal.SIGTERM)
        self.assertEqual(calls, [(child.pid, signal.SIGKILL), (child.pid, signal.SIGKILL)])
        self.assertTrue(driver.assert_reaped)
        self.assertGreater(clock.now, 1000 + module.CANCEL_GRACE_SECONDS)

    def test_child_exit_status_and_driver_failure_are_preserved(self):
        for code, failed, expected in ((0, False, 0), (0, True, 1), (7, True, 7), (-signal.SIGTERM, True, 143)):
            with self.subTest(code=code, failed=failed), tempfile.TemporaryDirectory() as directory:
                child = FakeChild(code)
                driver = module.Driver("token")
                driver.failed = failed
                self.assertEqual(module.supervise(child, Path(directory), driver,
                    lambda: (None, None), clock=FakeClock(), killpg=lambda *args: None), expected)
                self.assertTrue(child.waited)

    def test_exited_parent_descendants_are_stopped_before_restoration(self):
        child = FakeChild(0)
        events = []
        class Driver:
            failed = False
            def cleanup(self):
                events.append("restore")
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(module.supervise(child, Path(directory), Driver(),
                lambda: (None, None), clock=FakeClock(),
                killpg=lambda pid, sig: events.append((pid, sig))), 0)
        self.assertEqual(events, [(child.pid, signal.SIGKILL), "restore"])
        self.assertTrue(child.waited)

    def test_host_exception_reaps_child_and_restores_abandoned_lease(self):
        fixture = fixtures.DriverTests()
        fixture.setUp()
        fixture.acquire()
        fixture.driver.handle(fixture.request("set", category="small"))
        child = FakeChild()
        events = []
        def signal_child(process, signum):
            events.append(("signal", signum))
            process.code = -signum
        def wait(timeout=None):
            events.append(("wait", timeout))
            child.waited = True
            return child.code
        child.wait = wait
        handlers = []
        def register(sig, handler):
            handlers.append((sig, handler))
            return signal.SIG_DFL
        with patch.object(module, "Driver", return_value=fixture.driver), \
             patch.object(module.subprocess, "Popen", return_value=child), \
             patch.object(module.signal, "signal", side_effect=register), \
             patch.object(module, "signal_child", side_effect=signal_child), \
             patch.object(module, "supervise", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                module.main(["fake-child"])
        self.assertEqual(events, [("signal", signal.SIGTERM), ("wait", module.CANCEL_GRACE_SECONDS), ("signal", signal.SIGKILL)])
        self.assertEqual(fixture.writes, [(fixture.device, "small"), (fixture.device, "large")])
        self.assertTrue(fixture.driver.failed)
        self.assertEqual(handlers[-2:], [(signal.SIGINT, signal.SIG_DFL), (signal.SIGTERM, signal.SIG_DFL)])

    def test_child_exit_race_during_signal_forwarding_is_not_an_error(self):
        def already_exited(pid, signum):
            raise ProcessLookupError()
        module.signal_child(FakeChild(0), signal.SIGTERM, already_exited)



class GateBoundaryTests(unittest.TestCase):
    def test_gate_rejects_process_and_network_calls_before_execution(self):
        import importlib.util
        import os
        import socket
        spec = importlib.util.spec_from_file_location("gate", Path(__file__).with_name("check-driver-contracts.py"))
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        with gate.without_external_services():
            for operation in (
                lambda: subprocess.run(["xcrun", "simctl", "list"]),
                lambda: subprocess.Popen(["xcodebuild", "-version"]),
                lambda: os.system("simctl list"),
                lambda: socket.create_connection(("example.invalid", 443)),
            ):
                with self.assertRaisesRegex(AssertionError, "cannot launch"):
                    operation()


if __name__ == "__main__":
    unittest.main()
