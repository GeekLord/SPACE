"""Contracts of the stopped-restart scenario the bench cannot exercise.

The bench currently exercises the QUARANTINED path (the restart fails with the
standing signature on every kind bench) and, once the product bug is fixed,
the PASS path. Neither run can show that an *unrelated* restart failure is
refused quarantine and fails the run, or that the classifier is exact rather
than "any failure". Those two are pinned here.
"""

from __future__ import annotations

import unittest

from space_smoke.scenarios.native_stopped_restart_preserves_rootfs import (
    KNOWN_RESTART_FAILURE,
    is_known_restart_failure,
)


class RestartFailureClassification(unittest.TestCase):
    def test_the_standing_signature_is_known_wherever_it_appears(self) -> None:
        self.assertTrue(
            is_known_restart_failure(
                "RuntimeError: Native operation op_1 ended in failed: {'state': 'failed', "
                f"'terminal_error': {{'message': '{KNOWN_RESTART_FAILURE}; retry execution recovery'}}}}"
            )
        )

    def test_the_readiness_budget_stall_is_the_same_condition(self) -> None:
        self.assertTrue(
            is_known_restart_failure(
                "RuntimeError: Native operation op_3 ended in failed: {'progress_message': "
                "'required Wake did not complete within the readiness budget; sandbox-manager "
                "may still be completing the same activation'}"
            )
        )

    def test_other_restart_failures_are_not_quarantined(self) -> None:
        for error in (
            "TimeoutError: Native sandbox sbx_x did not reach running in 180s",
            (
                "RuntimeError: Native operation op_2 ended in failed: {'terminal_error': "
                "{'message': 'no node has capacity'}}"
            ),
            "RuntimeError: Native POST /v1/sandboxes/sbx_x:start returned HTTP 500",
        ):
            with self.subTest(error=error):
                self.assertFalse(is_known_restart_failure(error))


if __name__ == "__main__":
    unittest.main()
