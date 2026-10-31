"""Offline settlement primitives only. No RPC, signing or production payout adapter."""
import hashlib
import json
import sqlite3
from dataclasses import dataclass, asdict

MAX_UINT256 = (1 << 256) - 1


def convert_units(received: int, source_decimals: int, target_decimals: int):
    """Return exact payout and source dust; reject unrepresentable payouts."""
    if type(received) is not int or not 0 < received <= MAX_UINT256:
        raise ValueError("invalid received amount")
    if any(type(d) is not int or not 0 <= d <= 36 for d in (source_decimals, target_decimals)):
        raise ValueError("invalid decimals")
    if source_decimals >= target_decimals:
        payout, dust = divmod(received, 10 ** (source_decimals - target_decimals))
    else:
        payout, dust = received * 10 ** (target_decimals - source_decimals), 0
    if not 0 < payout <= MAX_UINT256:
        raise ValueError("zero or excessive payout")
    return payout, dust


@dataclass(frozen=True)
class Intent:
    source_chain: str
    source_contract: str
    request_id: str
    destination_chain: str
    destination_asset: str
    recipient: str
    amount: int  # exact target-chain base units, serialized without floating point

    def payload(self):
        fields = asdict(self)
        if any(not isinstance(v, str) or not v.strip() for k, v in fields.items() if k != "amount"):
            raise ValueError("missing route or request identity")
        if type(self.amount) is not int or not 0 < self.amount <= MAX_UINT256:
            raise ValueError("invalid amount")
        fields["amount"] = str(self.amount)
        return json.dumps(fields, sort_keys=True, separators=(",", ":"))

    def key(self):
        # One source request cannot be paid twice by changing its recipient or route.
        self.payload()
        identity = [self.source_chain, self.source_contract, self.request_id]
        return hashlib.sha256(json.dumps(identity, separators=(",", ":")).encode()).hexdigest()


class SettlementJournal:
    """Persist a payout outbox. Entries are NOT proof of source or destination execution.

    'ready' means locally queued, not verified. A future adapter must verify source
    finality and destination route before prepare(). Exact signed transaction bytes
    are saved BEFORE broadcast. Unknown broadcast results must be reconciled; never
    create a fresh transfer or mark it paid just because a network call returned.
    """
    def __init__(self, path):
        self.db = sqlite3.connect(path, isolation_level=None)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("CREATE TABLE IF NOT EXISTS outbox (id TEXT PRIMARY KEY, payload TEXT NOT NULL, state TEXT NOT NULL, txid TEXT UNIQUE, signed BLOB)")

    def close(self):
        self.db.close()

    def enqueue(self, intent):
        key, payload = intent.key(), intent.payload()
        self.db.execute("BEGIN IMMEDIATE")
        try:
            row = self.db.execute("SELECT payload FROM outbox WHERE id=?", (key,)).fetchone()
            if row and row[0] != payload:
                raise ValueError("source request conflicts with existing recipient, amount or route")
            if not row:
                self.db.execute("INSERT INTO outbox(id,payload,state) VALUES(?,?,?)", (key, payload, "ready"))
            self.db.execute("COMMIT")
        except Exception:
            self.db.execute("ROLLBACK")
            raise
        return key

    def prepare(self, key, txid, signed):
        if not isinstance(txid, str) or not txid or not isinstance(signed, bytes) or not signed:
            raise ValueError("signed transaction and its derived transaction id required")
        # Only one worker can win this state transition; losers must NOT broadcast.
        cursor = self.db.execute("UPDATE outbox SET state='prepared', txid=?, signed=? WHERE id=? AND state='ready'", (txid, signed, key))
        if cursor.rowcount != 1:
            raise ValueError("not ready; reconcile existing transaction")

    def transaction(self, key):
        row = self.db.execute("SELECT state,txid,signed FROM outbox WHERE id=?", (key,)).fetchone()
        if not row or row[0] == "ready":
            raise ValueError("no persisted transaction")
        return row

    def record_verified_payment(self, key, txid):
        # Trusted internal adapter boundary, NOT a public API and NOT an on-chain verifier.
        # Adapter MUST check finality, successful execution, asset, recipient and amount.
        row = self.transaction(key)
        if row[1] != txid:
            raise ValueError("receipt does not match persisted transaction")
        self.db.execute("UPDATE outbox SET state='paid' WHERE id=? AND txid=?", (key, txid))
