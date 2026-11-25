DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- (a) Tables and seed data
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
  application_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id         INT NOT NULL REFERENCES students(student_id),
  age_at_application INT NOT NULL CHECK (age_at_application > 0),
  monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
  average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
  submitted_on       DATE NOT NULL DEFAULT CURRENT_DATE,
  status             VARCHAR(10) NOT NULL DEFAULT 'PENDING',
  CONSTRAINT chk_status CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);
CREATE TABLE decision_audit (
  audit_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  application_id INT NOT NULL REFERENCES applications(application_id),
  old_status     VARCHAR(10) NOT NULL,
  new_status     VARCHAR(10) NOT NULL,
  changed_at     TIMESTAMP NOT NULL DEFAULT now()
);
INSERT INTO students (student_number, full_name) VALUES
 ('SC01','Agnes Phiri'), ('SC02','Benson Zimba'), ('SC03','Catherine Musonda');
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
 (1, 18, 3000.00, 70.00, CURRENT_DATE - 6, 'PENDING'),   -- all lower boundaries: qualifies
 (1, 25, 3000.00, 70.00, CURRENT_DATE - 5, 'PENDING'),   -- upper age boundary: qualifies
 (2, 22, 1500.00, 85.00, CURRENT_DATE - 4, 'PENDING'),   -- clearly qualifies
 (2, 17, 1000.00, 90.00, CURRENT_DATE - 3, 'PENDING'),   -- too young
 (3, 20, 3000.01, 80.00, CURRENT_DATE - 2, 'PENDING'),   -- income just above limit
 (3, 26, 2000.00, 69.99, CURRENT_DATE - 1, 'PENDING');   -- too old and mark too low

-- (b) Function
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
  IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
    RAISE EXCEPTION 'Age, income and mark must not be NULL';
  END IF;
  IF p_age <= 0 THEN RAISE EXCEPTION 'Age must be positive'; END IF;
  IF p_income < 0 THEN RAISE EXCEPTION 'Income must not be negative'; END IF;
  IF p_mark < 0 OR p_mark > 100 THEN RAISE EXCEPTION 'Mark must be between 0 and 100'; END IF;
  RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE v_status VARCHAR(10); v_age INT; v_inc NUMERIC; v_mark NUMERIC;
BEGIN
  SELECT status, age_at_application, monthly_income, average_mark
    INTO v_status, v_age, v_inc, v_mark
  FROM applications WHERE application_id = p_application_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
  END IF;
  IF v_status <> 'PENDING' THEN
    RAISE EXCEPTION 'Application % already assessed (status %)', p_application_id, v_status;
  END IF;
  UPDATE applications
  SET status = CASE WHEN fn_scholarship_eligible(v_age, v_inc, v_mark)
                    THEN 'APPROVED' ELSE 'REJECTED' END
  WHERE application_id = p_application_id;
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_decision_audit() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
  VALUES (OLD.application_id, OLD.status, NEW.status, now());
  RETURN NEW;
END $$;

CREATE TRIGGER trg_applications_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_decision_audit();

SELECT fn_scholarship_eligible(18, 3000, 70) AS t1,    -- true
       fn_scholarship_eligible(26, 1000, 90) AS t2;    -- false
CALL pr_assess_application(1);
SELECT * FROM decision_audit;                          -- one row for application 1
-- Rejection tests (run one at a time):
-- CALL pr_assess_application(1);                      -- already assessed
-- CALL pr_assess_application(999);                    -- unknown
-- SELECT fn_scholarship_eligible(NULL, 1000, 90);
-- SELECT fn_scholarship_eligible(20, -1, 90);
-- SELECT fn_scholarship_eligible(20, 1000, 101);

-- (e) View
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';          -- household income deliberately omitted

-- (f) Index
-- Justification: equality on status then a range on submitted_on gives a single index
-- range scan for "applications with a given status submitted between two dates".
CREATE INDEX idx_app_status_submitted ON applications (status, submitted_on);
SET enable_seqscan = off;
EXPLAIN SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT application_id FROM applications
           WHERE status = 'PENDING' ORDER BY application_id
  LOOP
    CALL pr_assess_application(r.application_id);
  END LOOP;
END $$;

-- SELECT cron.schedule('assess_pending', '0 8 * * 1', $$CALL pr_assess_pending()$$);
DO $do$
BEGIN
  PERFORM cron.schedule('assess_pending', '0 8 * * 1', $$CALL pr_assess_pending()$$);
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron not available here; job not created';
END
$do$;

CALL pr_assess_pending();
CALL pr_assess_pending();     -- rerun: nothing PENDING, so no reassessment or duplicate audit rows
SELECT * FROM applications ORDER BY application_id;
SELECT * FROM decision_audit ORDER BY audit_id;     -- 6 rows total (1 + 5)
SELECT * FROM v_approved_applicants;                -- applications 1, 2 and 3