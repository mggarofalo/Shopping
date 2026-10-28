#!/usr/bin/env python3
"""Run deterministic text-size contracts before allocating Simulator resources.

The four real Python-child lifecycle smoke tests remain in normal unittest
collection. This gate owns protocol and fake-child ordering, without subprocesses.
"""
from contextlib import ExitStack, contextmanager
from pathlib import Path
import os
import socket
import subprocess
import sys
import unittest
from unittest.mock import patch


def forbidden(*args, **kwargs):
    raise AssertionError("Driver contract gate cannot launch processes or use the network")


@contextmanager
def without_external_services():
    with ExitStack() as stack:
        for target, name in ((subprocess, "Popen"), (os, "system"),
                             (os, "posix_spawn"), (os, "posix_spawnp"),
                             (os, "kill"), (os, "killpg"),
                             (socket, "socket"), (socket, "create_connection")):
            if hasattr(target, name):
                stack.enter_context(patch.object(target, name, forbidden))
        yield


def cases(suite):
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from cases(test)
        else:
            yield test


def contract_suite():
    root = str(Path(__file__).resolve().parent)
    discovered = unittest.defaultTestLoader.discover(root, pattern="test_system_text_size*.py")
    return unittest.TestSuite(test for test in cases(discovered)
        if test.__class__.__name__ != "WrapperLifecycleTests")


def main():
    with without_external_services():
        suite = contract_suite()
        if suite.countTestCases() == 0:
            raise RuntimeError("Driver contract selection is empty")
        result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() and not result.skipped else 1


if __name__ == "__main__":
    sys.exit(main())
