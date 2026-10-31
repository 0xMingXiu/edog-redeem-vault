import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from settlement import Intent, SettlementJournal, convert_units, MAX_UINT256


class SettlementTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="crosschain-test-")
        self.path = Path(self.tmp) / "outbox.db"
        self.journal = SettlementJournal(self.path)
        self.intent = Intent("bsc-test", "escrow-fixture", "request-1", "UNCONFIRMED-test", "asset-fixture", "recipient-fixture", 1000000)

    def tearDown(self):
        self.journal.close()
        # Keep temporary test artifacts; no file or directory deletion.

    def test_downscale_returns_dust(self):
        self.assertEqual(convert_units(10**18 + 1, 18, 6), (10**6, 1))

    def test_upscale_and_zero_decimals(self):
        self.assertEqual(convert_units(1, 0, 18), (10**18, 0))

    def test_overflow_and_zero_rejected(self):
        for args in [(MAX_UINT256, 0, 36), (1, 18, 6), (0, 18, 18), (1, 37, 18)]:
            with self.assertRaises(ValueError): convert_units(*args)

    def test_duplicate_source_event_is_idempotent(self):
        self.assertEqual(self.journal.enqueue(self.intent), self.journal.enqueue(self.intent))
        self.assertEqual(self.journal.db.execute("SELECT count(*) FROM outbox").fetchone()[0], 1)

    def test_changed_recipient_amount_or_route_rejected(self):
        self.journal.enqueue(self.intent)
        for update in [dict(recipient="attacker"), dict(amount=2), dict(destination_chain="other"), dict(destination_asset="other")]:
            with self.assertRaises(ValueError): self.journal.enqueue(replace(self.intent, **update))

    def test_distinct_source_contract_has_distinct_identity(self):
        self.assertNotEqual(self.intent.key(), replace(self.intent, source_contract="other").key())

    def test_restart_recovers_same_signed_transaction(self):
        key = self.journal.enqueue(self.intent)
        self.journal.prepare(key, "tx-fixture", b"signed-fixture")
        self.journal.close()
        self.journal = SettlementJournal(self.path)
        self.assertEqual(self.journal.transaction(key), ("prepared", "tx-fixture", b"signed-fixture"))
        with self.assertRaises(ValueError): self.journal.prepare(key, "new-tx", b"new-signed")

    def test_two_workers_cannot_prepare_twice(self):
        key = self.journal.enqueue(self.intent)
        second = SettlementJournal(self.path)
        try:
            self.journal.prepare(key, "first", b"first")
            with self.assertRaises(ValueError): second.prepare(key, "second", b"second")
        finally: second.close()

    def test_wrong_receipt_rejected_and_paid_is_idempotent(self):
        key = self.journal.enqueue(self.intent)
        self.journal.prepare(key, "tx", b"signed")
        with self.assertRaises(ValueError): self.journal.record_verified_payment(key, "other")
        self.journal.record_verified_payment(key, "tx")
        self.journal.record_verified_payment(key, "tx")
        self.assertEqual(self.journal.transaction(key)[0], "paid")

    def test_one_transaction_cannot_pay_two_requests(self):
        first = self.journal.enqueue(self.intent)
        second = self.journal.enqueue(replace(self.intent, request_id="request-2"))
        self.journal.prepare(first, "tx", b"signed")
        import sqlite3
        with self.assertRaises(sqlite3.IntegrityError): self.journal.prepare(second, "tx", b"signed")

if __name__ == "__main__": unittest.main()
