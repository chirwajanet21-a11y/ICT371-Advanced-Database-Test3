DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- (a) Tables and seed data
CREATE TABLE books (
  book_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title   VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
  loan_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  book_id       INT NOT NULL REFERENCES books(book_id),
  borrower_name VARCHAR(100) NOT NULL,
  borrowed_on   DATE NOT NULL,
  due_on        DATE NOT NULL,
  returned_on   DATE NULL,
  fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
  CONSTRAINT chk_due_after_borrow CHECK (due_on >= borrowed_on)
);
CREATE TABLE loan_audit (
  audit_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  loan_id         INT NOT NULL REFERENCES loans(loan_id),
  old_returned_on DATE NULL,
  new_returned_on DATE NULL,
  changed_at      TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
  snapshot_date DATE PRIMARY KEY,
  overdue_count INT NOT NULL,
  total_fine    NUMERIC(12,2) NOT NULL
);
INSERT INTO books (title) VALUES ('Database Systems'), ('Computer Networks'), ('Operating Systems');
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
 (1, 'Chanda',   CURRENT_DATE - 30, CURRENT_DATE - 16, NULL,              0),  -- open, overdue
 (2, 'Mutale',   CURRENT_DATE - 3,  CURRENT_DATE + 11, NULL,              0),  -- open, on time
 (3, 'Natasha',  CURRENT_DATE - 30, CURRENT_DATE - 20, CURRENT_DATE - 17, 6),  -- returned late
 (1, 'Bwalya',   CURRENT_DATE - 25, CURRENT_DATE - 11, CURRENT_DATE - 11, 0),  -- returned on due date
 (2, 'Thandiwe', CURRENT_DATE - 20, CURRENT_DATE - 3,  NULL,              0),  -- open, overdue
 (3, 'Kelvin',   CURRENT_DATE - 14, CURRENT_DATE,      NULL,              0);  -- due today

-- (b) Function
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_due DATE; v_ret DATE; v_end DATE;
BEGIN
  SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
  END IF;
  IF v_ret IS NOT NULL THEN v_end := LEAST(p_as_of, v_ret); ELSE v_end := p_as_of; END IF;
  RETURN 2 * GREATEST(v_end - v_due, 0);
END $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_due DATE; v_ret DATE; v_fine NUMERIC;
BEGIN
  IF p_returned_on IS NULL THEN
    RAISE EXCEPTION 'Return date is required';
  END IF;
  SELECT borrowed_on, due_on, returned_on INTO v_borrowed, v_due, v_ret
  FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
  END IF;
  IF v_ret IS NOT NULL THEN
    RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_ret;
  END IF;
  IF p_returned_on < v_borrowed THEN
    RAISE EXCEPTION 'Return date % is before borrow date %', p_returned_on, v_borrowed;
  END IF;
  v_fine := 2 * GREATEST(p_returned_on - v_due, 0);
  UPDATE loans SET returned_on = p_returned_on, fine_amount = v_fine
  WHERE loan_id = p_loan_id;
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_loan_audit() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
  VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_loans_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_loan_audit();

SELECT fn_loan_fine(1, CURRENT_DATE) AS open_overdue;   -- 32
SELECT fn_loan_fine(3, CURRENT_DATE) AS returned_late;  -- 6
SELECT fn_loan_fine(6, CURRENT_DATE) AS due_today;      -- 0
CALL pr_return_loan(6, CURRENT_DATE);
SELECT loan_id, returned_on, fine_amount FROM loans WHERE loan_id = 6;
SELECT * FROM loan_audit;
-- Rejection tests (run one at a time):
-- CALL pr_return_loan(6, CURRENT_DATE);        -- already returned
-- CALL pr_return_loan(999, CURRENT_DATE);      -- unknown loan
-- CALL pr_return_loan(2, CURRENT_DATE - 30);   -- before borrowed_on
-- SELECT fn_loan_fine(999, CURRENT_DATE);

-- (e) View
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (f) Index
-- Partial index: only unreturned loans are indexed, so it is small and matches the query.
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM loans WHERE book_id = 2 AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Scheduled job (counts unreturned loans that are overdue on p_as_of)
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
  SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
  FROM loans
  WHERE returned_on IS NULL AND due_on < p_as_of
  ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END $$;

-- SELECT cron.schedule('refresh_overdue', '10 0 * * *', $$CALL pr_refresh_overdue(CURRENT_DATE)$$);
DO $do$
BEGIN
  PERFORM cron.schedule('refresh_overdue', '10 0 * * *',
    $$CALL pr_refresh_overdue(CURRENT_DATE)$$);
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron not available here; job not created';
END
$do$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);   -- rerun replaces the row
SELECT * FROM overdue_summary;