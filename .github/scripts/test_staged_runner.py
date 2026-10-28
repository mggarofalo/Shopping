"""Parent-only cancellation must reach the in-process canary supervisor."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPTS = Path(__file__).resolve().parent


class StagedRunnerCancellationTests(unittest.TestCase):
    def test_parent_only_sigterm_and_sigint_restore_and_stop_native_standin(self):
        for signum in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=signum), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'phase.py').write_text("""import os, signal, subprocess, sys, time
from pathlib import Path
root = Path(sys.argv[1])
(root / 'phase_pid').write_text(str(os.getpid()))
native = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], start_new_session=True)
(root / 'native_pid').write_text(str(native.pid))
def cancel(signum, frame):
    os.killpg(native.pid, signal.SIGTERM)
    native.wait(timeout=5)
    (root / 'restored').write_text('yes')
    sys.exit(0)
signal.signal(signal.SIGTERM, cancel)
(root / 'ready').write_text('yes')
while True: time.sleep(0.05)
""")
                (root / 'parent.py').write_text("""import importlib.util, os, sys
from pathlib import Path
scripts, root = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(scripts))
spec = importlib.util.spec_from_file_location('staged_runner', scripts / 'run-local-staged-validation.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.canary.main = lambda argv: runner.canary.bounded_call(
    [sys.executable, root / 'phase.py', root], env=dict(os.environ), timeout=20)
runner.run_canary('unused-simulator', root)
""")
                parent = subprocess.Popen([sys.executable, root / 'parent.py', SCRIPTS, root],
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                try:
                    deadline = time.monotonic() + 5
                    while not (root / 'ready').exists() and parent.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue((root / 'ready').exists(), 'Native stand-in did not become ready')
                    # Signal only this PID, not its process group: the supervisor
                    # must forward cancellation and wait for restoration itself.
                    parent.send_signal(signum)
                    stdout, stderr = parent.communicate(timeout=10)
                    self.assertNotEqual(parent.returncode, 0, (stdout, stderr))
                    self.assertIn(f'Canary cancelled by signal {signum}'.encode(), stderr)
                    self.assertEqual((root / 'restored').read_text(), 'yes')
                    with self.assertRaises(ProcessLookupError):
                        os.kill(int((root / 'native_pid').read_text()), 0)
                finally:
                    if parent.poll() is None:
                        os.killpg(parent.pid, signal.SIGKILL)
                        parent.wait(timeout=5)
                    for name in ('phase_pid', 'native_pid'):
                        if (root / name).exists():
                            try:
                                os.killpg(int((root / name).read_text()), signal.SIGKILL)
                            except ProcessLookupError:
                                pass


if __name__ == '__main__':
    unittest.main()
