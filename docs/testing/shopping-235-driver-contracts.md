# Simulator text-size driver contracts (SHOPPING-235)

The host driver separates lease state, serial request transport, native commands
and child supervision. Injected clocks, command runners and child processes prove
ordering without launching Simulator. UIKit workflows retain ownership of real
category changes, same-process lifecycle, layout, interaction and app restoration.

## Local gates

```sh
PYTHONDONTWRITEBYTECODE=1 python3 .github/scripts/check-driver-contracts.py
```

This entry point uses existing unittest discovery (`test_system_text_size*.py`),
selects 33 deterministic cases and fails on empty selection, failures or skips.
It blocks subprocess launch, shell execution, native signals and network sockets.
A boundary test attempts xcrun/simctl, xcodebuild, shell and network operations and
requires rejection before execution. Command-adapter tests supply fake runners.

The four existing real Python-child lifecycle tests remain outside that zero-process
gate. The complete 37-case inventory, including those smoke tests, runs with:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s .github/scripts -p 'test_system_text_size*.py'
```

Those four launch temporary Python fixtures and a fake xcrun in their private PATH;
none launches Simulator. They retain success-with-abandonment, child failure,
child signal exit and host cancellation proof. All original 17 tests remain.
The original late-setter test now advances an injected clock instead of mocking
global time. SHOPPING-237 owns enforcement in dispatch/CI; this issue introduces
only the local entry point. Full, coverage and exact-source policy are unchanged.

## Fault ownership

Methods live in `test_system_text_size.py` (existing) or
`test_system_text_size_protocol.py` (new).

| Boundary / fault | Owning test method |
|---|---|
| Acquire read failure, no invented original | `test_acquire_read_failure_never_captures_an_original_or_mutates` |
| Set success followed by readback timeout | `test_readback_timeout_requires_restore_before_next_lease` |
| Failed setter may already have mutated | `test_failed_set_can_have_mutated_and_cleanup_restores_original` |
| In-flight setter, expired completion, queued restore | `test_pending_restore_runs_only_after_inflight_set_finishes` |
| Late acknowledgement is an error | `test_timed_out_setter_finishes_before_restoration` |
| Response retains request identity/nonce | `test_response_preserves_all_identity_fields_and_is_atomically_published` |
| Expired and duplicate requests | `test_expired_request_never_mutates`, `test_duplicate_request_is_not_replayed` |
| Wrong token/lease/device/device-set | `test_wrong_token_never_mutates`, `test_wrong_lease_never_mutates`, `test_unknown_device_never_retargets_current_lease`, `test_wrong_device_set_cannot_change_an_active_lease` |
| Stale lease arriving during next test | `test_stale_old_lease_cannot_mutate_next_test` |
| Invalid deadlines, UUID types and envelopes | `test_future_deadline_and_malformed_identity_never_mutate`, `test_malformed_or_misnamed_requests_fail_without_mutation` |
| Exact clone device/set and bounded command | `test_native_command_uses_exact_clone_device_set_and_bounded_timeout` |
| Invalid captured category | `test_native_read_rejects_unsupported_original` |
| Clone independence, including poisoned clone | `test_clone_devices_have_independent_originals`, `test_clone_failure_does_not_poison_other_clone` |
| Failed readback permits restore only | `test_readback_mismatch_poisons_lease_until_restored` |
| Failed cleanup prevents reacquisition | `test_failed_cleanup_quarantines_device_before_new_acquire` |
| Abandoned lease restores but fails run | `test_abandoned_lease_restores_and_prevents_success` |
| Cancellation stops queued mutation | `test_cancellation_stops_queued_mutation` |
| Unresponsive child killed/reaped before cleanup | `test_stubborn_cancelled_child_is_killed_then_reaped_before_cleanup` |
| Parent exit does not leave descendants racing restore | `test_exited_parent_descendants_are_stopped_before_restoration` |
| Host exception restores state and signal handlers | `test_host_exception_reaps_child_and_restores_abandoned_lease` |
| Exit races signal forwarding | `test_child_exit_race_during_signal_forwarding_is_not_an_error` |
| Failure exit/signal preserved | `test_child_exit_status_and_driver_failure_are_preserved`, existing `WrapperLifecycleTests` |
| External service calls forbidden in cheap gate | `test_gate_rejects_process_and_network_calls_before_execution` |

Malformed JSON bodies and non-string UUID fields previously escaped as
AttributeError. Failed emergency restoration discarded its lease and allowed a
reused Driver to capture an unverified changed category as its new original.
Tests first failed on these cases. Validation now rejects malformed input and
quarantines unrecovered devices for the rest of the run, retaining the original
for diagnosis. It does not reset Simulator or silently retry failed cleanup.
The command's private process group is stopped after parent exit and before
emergency restoration, so surviving descendants cannot race the restore.

## Evidence and limits

Evidence is retained at `/tmp/shopping-235-evidence/`. Baseline source:
`95aa72a06d9f4433366b8668b87e3b419af8126f`. Responsibility extraction was committed
before fault repairs. Python 3.14.6 on local macOS; no simulator or Xcode execution.

| Selection | Command wall time | Test execution | Result |
|---|---:|---:|---|
| Baseline 17 existing tests | 1.80 s | 1.688 s | Pass |
| Final 33-case deterministic gate | 0.08 s | 0.008 s | Pass |
| Final complete 37-case inventory | 1.83 s | 1.758 s | Pass |

These selections differ. The measurements demonstrate cheap protocol feedback,
not a same-inventory speedup or any established ShoppingFull saving. Baseline,
final, and initial fault failures are retained in their named log files.

Eight isolated deliberate mutations were each rejected: disabled expiry, token,
duplicate and poisoned-lease checks; incorrect original restoration; disabled
unrecovered-device quarantine; erased child failure; and missing response identity.
`mutations.json` maps each mutation to its test/nonzero exit; individual logs
retain the failures. Mutation work used temporary copies, never the candidate.

The native command allowance remains 60 seconds; request allowance remains
`4 * COMMAND_TIMEOUT_SECONDS + 15` (255 seconds), covering two workers' two-command
set/readback pairs plus IPC margin. The eight-second app observation bound is
unchanged. Tests verify budget derivation and timeout forwarding. Fake-clock
success does not prove native latency, OS compatibility or UIKit lifecycle.
SHOPPING-236 owns real-runtime compatibility evidence.
