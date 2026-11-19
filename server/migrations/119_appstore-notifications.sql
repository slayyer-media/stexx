-- App Store Server Notifications V2 (POST /v1/subscriptions/apple/notifications). See docs/api.md ("Stexx+") and
-- docs/security.md ("Privacy").
--
-- Idempotency only: the notification's UUID and when it arrived. No Apple payload is stored. The handler deletes rows
-- older than 30 days as it goes (Apple stops retrying a notification after about three days).
CREATE TABLE IF NOT EXISTS apple_notifications (
  notification_uuid  text PRIMARY KEY,
  received_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS apple_notifications_received_idx ON apple_notifications (received_at);

-- Apple's auto-renew status for the subscription, from the signed renewal info in notifications. NULL = not known yet
-- (the app's POST /subscriptions/apple carries no renewal info).
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS auto_renew boolean;
