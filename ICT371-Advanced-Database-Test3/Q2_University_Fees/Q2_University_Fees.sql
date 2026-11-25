DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

-- (a) Tables and seed data
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL,
  fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
  payment_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  paid_on    DATE NOT NULL DEFAULT CURRENT_DATE
);
CREATE TABLE payment_audit (
  audit_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  payment_id INT NOT NULL REFERENCES payments(payment_id),
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL,
  logged_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_collections (
  collection_date DATE PRIMARY KEY,
  payment_count   INT NOT NULL,
  total_amount    NUMERIC(14,2) NOT NULL
);
INSERT INTO students (student_number, full_name, fee_due) VALUES
 ('S1001', 'Mary Banda',   5000),
 ('S1002', 'Peter Phiri',  3000),
 ('S1003', 'Grace Mwansa', 2000);     -- no payments yet
INSERT INTO payments (student_id, amount, paid_on) VALUES
 (1, 1000, CURRENT_DATE - 10),
 (1, 1000, CURRENT_DATE - 6),
 (1,  500, CURRENT_DATE - 1),
 (1,  500, CURRENT_DATE - 1),
 (2, 1000, CURRENT_DATE - 8),
 (2, 1000, CURRENT_DATE - 4),
 (2, 1000, CURRENT_DATE - 1);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_fee NUMERIC; v_paid NUMERIC;
BEGIN
  SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
  END IF;
  SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE student_id = p_student_id;
  RETURN v_fee - v_paid;
END $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Payment amount must be greater than zero';
  END IF;
  IF p_paid_on IS NULL THEN
    RAISE EXCEPTION 'Payment date is required';
  END IF;
  PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
  END IF;
  v_balance := fn_fee_balance(p_student_id);
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
  END IF;
  INSERT INTO payments (student_id, amount, paid_on) VALUES (p_student_id, p_amount, p_paid_on);
END $$;

-- (d) Trigger (the procedure does not write the audit row)
CREATE OR REPLACE FUNCTION trg_payment_audit() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
  VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
  RETURN NEW;
END $$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_payment_audit();

SELECT fn_fee_balance(1) AS s1, fn_fee_balance(2) AS s2, fn_fee_balance(3) AS s3;  -- 2000, 0, 2000
CALL pr_receive_payment(3, 500, CURRENT_DATE);
SELECT * FROM payment_audit;      -- one row, created by the trigger
-- Rejection tests (run one at a time):
-- CALL pr_receive_payment(3, 99999, CURRENT_DATE);
-- CALL pr_receive_payment(3, -5, CURRENT_DATE);
-- CALL pr_receive_payment(3, NULL, CURRENT_DATE);
-- SELECT fn_fee_balance(999);

-- (e) View
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

SELECT * FROM v_fee_balances;      -- S1001 and S1003 only

-- (f) Index
-- Justification: equality on student_id then range on paid_on lets one index
-- range scan answer the filter; the reverse order could not narrow by student first.
CREATE INDEX idx_payments_student_paid ON payments (student_id, paid_on);
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_collections (collection_date, payment_count, total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
  FROM payments WHERE paid_on = p_day
  ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count, total_amount = EXCLUDED.total_amount;
END $$;

-- SELECT cron.schedule('refresh_collections', '0 1 * * *', $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);
DO $do$
BEGIN
  PERFORM cron.schedule('refresh_collections', '0 1 * * *',
    $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron not available here; job not created';
END
$do$;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);   -- rerun replaces the row
SELECT * FROM daily_collections;