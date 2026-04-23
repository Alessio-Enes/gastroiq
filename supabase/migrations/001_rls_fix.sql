ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own subscription" ON subscriptions;
DROP POLICY IF EXISTS "Service role can manage subscriptions" ON subscriptions;
DROP POLICY IF EXISTS "service_role_all" ON subscriptions;
DROP POLICY IF EXISTS "Enable all for service_role" ON subscriptions;
DROP POLICY IF EXISTS "service_role_full_access" ON subscriptions;
DROP POLICY IF EXISTS "user_read_own_subscription" ON subscriptions;

CREATE POLICY "service_role_full_access"
  ON subscriptions FOR ALL TO service_role
  USING (true) WITH CHECK (true);

CREATE POLICY "user_read_own_subscription"
  ON subscriptions FOR SELECT TO authenticated
  USING (auth.uid() = user_id);

ALTER TABLE subscriptions
  ADD COLUMN IF NOT EXISTS stripe_customer_id TEXT,
  ADD COLUMN IF NOT EXISTS stripe_subscription_id TEXT,
  ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'trialing',
  ADD COLUMN IF NOT EXISTS plan TEXT DEFAULT 'bronze',
  ADD COLUMN IF NOT EXISTS trial_ends_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS current_period_end TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_sub_customer ON subscriptions (stripe_customer_id);
CREATE INDEX IF NOT EXISTS idx_sub_user ON subscriptions (user_id);