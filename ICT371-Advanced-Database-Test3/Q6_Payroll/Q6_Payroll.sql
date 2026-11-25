DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- (a) Tables and seed data
CREATE TABLE employees (
  employee_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name    VARCHAR(100) NOT NULL,
  basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
  deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
  active       BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
  payroll_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  pay_month   DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
  gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
  net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
  CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
  audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  old_salary  NUMERIC(12,2) NOT NULL,
  new_salary  NUMERIC(12,2) NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
 ('John Mwale',    8000, 1500, 1000, TRUE),
 ('Ruth Chilufya', 6000, 1000,  800, TRUE),
 ('Moses Ngoma',   7000,  500,  700, TRUE),
 ('Linda Kunda',   5000,  400,  500, FALSE);
INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay) VALUES
 (1, DATE '2026-09-01', 9500, 8500),
 (2, DATE '2026-09-01', 7000, 6200),
 (3, DATE '2026-09-01', 7500, 6800),
 (4, DATE '2026-09-01', 5400, 4900),
 (1, DATE '2026-10-01', 9500, 8500),
 (2, DATE '2026-10-01', 7000, 6200),
 (3, DATE '2026-10-01', 7500, 6800);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_net NUMERIC;
BEGIN
  SELECT basic_salary + allowance - deduction INTO v_net
  FROM employees WHERE employee_id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
  END IF;
  IF v_net < 0 THEN
    RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
  END IF;
  RETURN v_net;
END $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_net NUMERIC;
BEGIN
  IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
    RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
  END IF;
  FOR r IN SELECT employee_id, basic_salary, allowance
           FROM employees WHERE active = TRUE ORDER BY employee_id
  LOOP
    v_net := fn_net_pay(r.employee_id);      -- an error aborts the whole call
    INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
    VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
    ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
  END LOOP;
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_salary_audit() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO salary_audit (employee_id, old_salary, new_salary)
  VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_salary_audit();

SELECT fn_net_pay(1) AS net_pay_emp1;                          -- 8500
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;   -- audited
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;   -- unchanged: no audit row
SELECT * FROM salary_audit;                                       -- exactly one row
UPDATE employees SET active = FALSE WHERE employee_id = 3;        -- becomes inactive
CALL pr_process_payroll(DATE '2026-11-01');                       -- processes employees 1 and 2
CALL pr_process_payroll(DATE '2026-11-01');                       -- rerun: nothing changes
SELECT * FROM payroll ORDER BY pay_month, employee_id;
-- Rejection tests (run one at a time):
-- CALL pr_process_payroll(DATE '2026-11-15');
-- SELECT fn_net_pay(999);

-- (e) View
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;     -- no active filter: keeps history

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) Index
-- Justification: the unique index starts with employee_id, so it cannot efficiently find
-- "all employees in one month". This index leads with pay_month and does not duplicate it.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) Scheduled job: 02:00 on the 1st of each month, for the previous month
-- SELECT cron.schedule('monthly_payroll', '0 2 1 * *',
--   $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);
DO $do$
BEGIN
  PERFORM cron.schedule('monthly_payroll', '0 2 1 * *',
    $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron not available here; job not created';
END
$do$;

-- Inspect the job and its run history (run where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time, end_time
--   FROM cron.job_run_details
--   WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'monthly_payroll')
--   ORDER BY start_time DESC;