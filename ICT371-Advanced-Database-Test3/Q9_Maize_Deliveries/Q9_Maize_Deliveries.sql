DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- (a) Tables and farmer seed data
CREATE TABLE farmers (
  farmer_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  farmer_number VARCHAR(20) NOT NULL UNIQUE,
  full_name     VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
  delivery_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
  grade        CHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
  weight_kg    NUMERIC(10,2) NOT NULL,
  unit_rate    NUMERIC(10,2) NOT NULL,
  total_value  NUMERIC(14,2) NOT NULL,
  delivered_on DATE NOT NULL,
  is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
  purchase_date DATE PRIMARY KEY,
  total_weight  NUMERIC(14,2) NOT NULL,
  total_value   NUMERIC(14,2) NOT NULL
);
INSERT INTO farmers (farmer_number, full_name) VALUES
 ('F001', 'Edwin Mumba'), ('F002', 'Florence Chisenga'), ('F003', 'George Lubinda');

-- (b) Function
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
BEGIN
  IF p_grade IS NULL THEN
    RAISE EXCEPTION 'Grade is required';
  END IF;
  IF p_grade = 'A' THEN RETURN 5;
  ELSIF p_grade = 'B' THEN RETURN 4;
  ELSIF p_grade = 'C' THEN RETURN 3;
  ELSE
    RAISE EXCEPTION 'Unsupported grade: %', p_grade;
  END IF;
END $$;

-- (c) Procedure (unit_rate and total_value come from the trigger in (d))
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade CHAR, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_grade IS NULL OR p_weight IS NULL OR p_date IS NULL THEN
    RAISE EXCEPTION 'Grade, weight and date are required';
  END IF;
  IF p_weight <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive';
  END IF;
  PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
  END IF;
  PERFORM fn_maize_rate(p_grade);
  INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
  VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_delivery_price() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
  END IF;
  NEW.unit_rate   := fn_maize_rate(NEW.grade);
  NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_deliveries_price
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_delivery_price();

-- (a) continued: six deliveries loaded after the trigger (all grades, paid and unpaid)
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
 (1, 'A', 100, CURRENT_DATE - 2, TRUE),
 (1, 'B',  80, CURRENT_DATE - 1, FALSE),
 (2, 'C', 150, CURRENT_DATE - 2, FALSE),
 (2, 'A',  60, CURRENT_DATE - 1, TRUE),
 (3, 'B', 200, CURRENT_DATE - 1, TRUE),
 (3, 'A',  40, CURRENT_DATE - 1, TRUE);

SELECT fn_maize_rate('A') AS a, fn_maize_rate('B') AS b, fn_maize_rate('C') AS c;   -- 5, 4, 3
CALL pr_receive_delivery(1, 'C', 50, CURRENT_DATE - 1);     -- valid, goes through the procedure
SELECT * FROM deliveries ORDER BY delivery_id;
-- Rejection tests (run one at a time):
-- SELECT fn_maize_rate('D');
-- SELECT fn_maize_rate(NULL);
-- CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);     -- unknown farmer
-- CALL pr_receive_delivery(1, 'A', -3, CURRENT_DATE);      -- bad weight
-- INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on)
--   VALUES (1, 'B', -5, CURRENT_DATE);                     -- trigger rejects direct SQL

-- (e) View
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE d.is_paid = FALSE), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

-- (f) Index
-- Justification: one farmer (equality) between two dates (range) matches the column
-- order of this composite index, so a single range scan answers the query.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
SET enable_seqscan = off;
EXPLAIN SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
  SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
  FROM deliveries WHERE delivered_on = p_day
  ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight, total_value = EXCLUDED.total_value;
END $$;

-- SELECT cron.schedule('refresh_purchases', '30 1 * * *', $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);
DO $do$
BEGIN
  PERFORM cron.schedule('refresh_purchases', '30 1 * * *',
    $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron not available here; job not created';
END
$do$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);   -- rerun: same totals, not doubled
SELECT * FROM daily_purchases;