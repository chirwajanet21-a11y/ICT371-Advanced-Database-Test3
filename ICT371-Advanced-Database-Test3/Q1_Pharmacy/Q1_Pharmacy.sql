DROP TABLE IF EXISTS daily_sales, stock_audit, sales, medicines CASCADE;

-- (a) Tables
CREATE TABLE medicines (
  medicine_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_name VARCHAR(100) NOT NULL UNIQUE,
  unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  stock_qty     INT NOT NULL CHECK (stock_qty >= 0)
);
CREATE TABLE sales (
  sale_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  quantity    INT NOT NULL CHECK (quantity > 0),
  unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  sold_on     DATE NOT NULL DEFAULT CURRENT_DATE
);
CREATE TABLE stock_audit (
  audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  old_qty     INT NOT NULL,
  new_qty     INT NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_sales (
  sales_date   DATE PRIMARY KEY,
  total_qty    INT NOT NULL DEFAULT 0,
  total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
 ('Paracetamol', 2.50, 100),
 ('Amoxicillin', 8.00, 25),
 ('Ibuprofen',   4.00, 12);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
  END IF;
  SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
  END IF;
  RETURN v_price * p_quantity;
END $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(10,2); v_stock INT;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be positive';
  END IF;
  IF p_sold_on IS NULL THEN
    RAISE EXCEPTION 'Sale date is required';
  END IF;
  SELECT unit_price, stock_qty INTO v_price, v_stock
  FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
  END IF;
  IF v_stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock: have %, need %', v_stock, p_quantity;
  END IF;
  INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
  VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);
  UPDATE medicines SET stock_qty = stock_qty - p_quantity
  WHERE medicine_id = p_medicine_id;
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_stock_audit() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
  VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_stock_audit();

-- (a) continued: six valid sales loaded through the procedure
CALL pr_record_sale(1, 10, CURRENT_DATE);
CALL pr_record_sale(1,  5, CURRENT_DATE);
CALL pr_record_sale(2,  8, CURRENT_DATE);
CALL pr_record_sale(2, 10, CURRENT_DATE - 1);
CALL pr_record_sale(3,  4, CURRENT_DATE - 1);
CALL pr_record_sale(3,  2, CURRENT_DATE);

SELECT fn_sale_value(1, 4) AS sale_value;      -- 10.00
SELECT * FROM stock_audit;
-- Rejection tests (run one at a time; each errors and changes nothing):
-- CALL pr_record_sale(3, 999, CURRENT_DATE);
-- SELECT fn_sale_value(99, 1);

-- (e) View
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

SELECT * FROM v_low_stock;      -- Amoxicillin 7, Ibuprofen 6

-- (f) Index
-- Justification: medicine_id (equality) first, sold_on (range) second, so one
-- B-tree range scan finds one medicine's sales in a date range.
CREATE INDEX idx_sales_med_date ON sales (medicine_id, sold_on);
SET enable_seqscan = off;   -- only so the tiny demo table uses the index
EXPLAIN SELECT * FROM sales
WHERE medicine_id = 1 AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_sales (sales_date, total_qty, total_amount)
  SELECT p_day, COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0)
  FROM sales WHERE sold_on = p_day
  ON CONFLICT (sales_date) DO UPDATE
    SET total_qty = EXCLUDED.total_qty, total_amount = EXCLUDED.total_amount;
END $$;

-- SELECT cron.schedule('refresh_sales', '15 0 * * *', $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$);
DO $do$
BEGIN
  PERFORM cron.schedule('refresh_sales', '15 0 * * *',
    $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$);
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron not available here; job not created';
END
$do$;

CALL pr_refresh_sales(CURRENT_DATE);
CALL pr_refresh_sales(CURRENT_DATE);    -- rerun: no double counting
SELECT * FROM daily_sales;