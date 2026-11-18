-- Refunded / revoked App Store transactions. A revoked subscription never grants Plus again, even if a stale
-- (non-revoked) signed transaction for the same original_transaction_id is replayed later.
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS revoked_at timestamptz;
