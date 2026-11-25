DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- (a) Tables and vehicle seed data
CREATE TABLE vehicles (
  vehicle_id            INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  registration          VARCHAR(15) NOT NULL UNIQUE,
  current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
  last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
  CONSTRAINT chk_service_le_current CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
  trip_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
  trip_on        DATE NOT NULL,
  start_odometer INT NOT NULL CHECK (start_odometer >= 0),
  end_odometer   INT NOT NULL CHECK (end_odometer >= 0)
);
CREATE TABLE service_alerts (
  vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
  km_since_service INT NOT NULL,
  flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
 ('ABC 1001', 10000,  9000),
 ('BCD 2002', 20000, 17000),
 ('CDE 3003',  5000,     0);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE v_cur INT; v_last INT;
BEGIN
  SELECT current_odometer, last_service_odometer INTO v_cur, v_last
  FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
  END IF;
  RETURN (v_cur - v_last) >= 5000;
END $$;

-- (c) Procedure (does not touch the vehicle odometer)
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
    RAISE EXCEPTION 'Trip date, start and end odometer are required';
  END IF;
  PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
  END IF;
  IF p_end <= p_start THEN
    RAISE EXCEPTION 'end_odometer must be greater than start_odometer';
  END IF;
  INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
  VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_trip_odometer() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE v_current INT;
BEGIN
  SELECT current_odometer INTO v_current
  FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
  END IF;
  IF NEW.end_odometer <= NEW.start_odometer THEN
    RAISE EXCEPTION 'end_odometer (%) must exceed start_odometer (%)',
      NEW.end_odometer, NEW.start_odometer;
  END IF;
  IF NEW.start_odometer <> v_current THEN
    RAISE EXCEPTION 'Trip must start at current odometer %, got %', v_current, NEW.start_odometer;
  END IF;
  UPDATE vehicles SET current_odometer = NEW.end_odometer
  WHERE vehicle_id = NEW.vehicle_id;                   -- exactly once
  RETURN NEW;
END $$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trip_odometer();

-- (a) continued: six trips added through the procedure, after the trigger exists
CALL pr_record_trip(1, CURRENT_DATE - 10, 10000, 10300);
CALL pr_record_trip(1, CURRENT_DATE - 5,  10300, 10800);
CALL pr_record_trip(2, CURRENT_DATE - 9,  20000, 21200);
CALL pr_record_trip(2, CURRENT_DATE - 4,  21200, 22000);
CALL pr_record_trip(3, CURRENT_DATE - 8,   5000,  5600);
CALL pr_record_trip(3, CURRENT_DATE - 3,   5600,  6100);

SELECT vehicle_id, registration, current_odometer, fn_service_due(vehicle_id) AS service_due
FROM vehicles ORDER BY vehicle_id;      -- false, true, true
-- Rejection tests (run one at a time):
-- CALL pr_record_trip(1, CURRENT_DATE, 9999, 10900);    -- wrong starting odometer
-- CALL pr_record_trip(1, CURRENT_DATE, 10800, 10700);   -- end not greater than start
-- CALL pr_record_trip(99, CURRENT_DATE, 0, 10);         -- unknown vehicle
-- SELECT fn_service_due(99);

-- (e) View
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;

-- (f) Index
-- Justification: equality on vehicle_id then a range on trip_on is served by one
-- ordered index range scan instead of scanning every trip.
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);
SET enable_seqscan = off;
EXPLAIN SELECT * FROM trips
WHERE vehicle_id = 2 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
  SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
  FROM vehicles
  WHERE current_odometer - last_service_odometer >= 5000
  ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service;

  DELETE FROM service_alerts sa
  USING vehicles v
  WHERE v.vehicle_id = sa.vehicle_id
    AND v.current_odometer - v.last_service_odometer < 5000;   -- serviced: remove the alert
END $$;

-- SELECT cron.schedule('refresh_service_alerts', '0 6 * * 1', $$CALL pr_refresh_service_alerts()$$);
DO $do$
BEGIN
  PERFORM cron.schedule('refresh_service_alerts', '0 6 * * 1', $$CALL pr_refresh_service_alerts()$$);
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron not available here; job not created';
END
$do$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;     -- vehicles 2 and 3
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;   -- vehicle 2 serviced
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;     -- only vehicle 3