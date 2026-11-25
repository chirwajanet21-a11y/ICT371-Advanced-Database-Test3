DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

-- (a) Tables and seed data
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
  room_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  room_number VARCHAR(10) NOT NULL UNIQUE,
  capacity    INT NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
  allocation_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id    INT NOT NULL REFERENCES students(student_id),
  room_id       INT NOT NULL REFERENCES rooms(room_id),
  allocated_on  DATE NOT NULL,
  released_on   DATE NULL,
  status        VARCHAR(10) NOT NULL,
  CONSTRAINT chk_status  CHECK (status IN ('ACTIVE', 'ENDED')),
  CONSTRAINT chk_release CHECK (
    (status = 'ACTIVE' AND released_on IS NULL) OR
    (status = 'ENDED'  AND released_on IS NOT NULL))
);
CREATE TABLE occupancy_snapshot (
  snapshot_date DATE NOT NULL,
  room_id       INT NOT NULL REFERENCES rooms(room_id),
  occupied_beds INT NOT NULL,
  free_beds     INT NOT NULL,
  PRIMARY KEY (snapshot_date, room_id)
);
INSERT INTO students (student_number, full_name) VALUES
 ('H001','Anna Kapesa'), ('H002','Bupe Mulenga'), ('H003','Chola Nkonde'),
 ('H004','Dalitso Moyo'), ('H005','Esther Sinyangwe');
INSERT INTO rooms (room_number, capacity) VALUES ('101', 2), ('102', 3), ('103', 2);
-- Room 101 full, room 102 partly occupied, room 103 empty (only an ENDED record)
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
 (1, 1, CURRENT_DATE - 60,  NULL,             'ACTIVE'),
 (2, 1, CURRENT_DATE - 55,  NULL,             'ACTIVE'),
 (3, 2, CURRENT_DATE - 40,  NULL,             'ACTIVE'),
 (4, 3, CURRENT_DATE - 120, CURRENT_DATE - 30,'ENDED');

-- (b) Function
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_active INT;
BEGIN
  SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
  END IF;
  SELECT COUNT(*) INTO v_active FROM allocations
  WHERE room_id = p_room_id AND status = 'ACTIVE';
  RETURN v_cap - v_active;
END $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_allocated_on IS NULL THEN
    RAISE EXCEPTION 'Allocation date is required';
  END IF;
  PERFORM 1 FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student_id: %', p_student_id; END IF;
  PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room_id: %', p_room_id; END IF;
  PERFORM 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE';
  IF FOUND THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
  END IF;
  IF fn_free_beds(p_room_id) <= 0 THEN
    RAISE EXCEPTION 'Room % has no free beds', p_room_id;
  END IF;
  INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
  VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_alloc_rules() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_count INT;
BEGIN
  IF NEW.status = 'ACTIVE' THEN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
    END IF;
    SELECT COUNT(*) INTO v_count FROM allocations
    WHERE student_id = NEW.student_id AND status = 'ACTIVE'
      AND allocation_id IS DISTINCT FROM NEW.allocation_id;
    IF v_count > 0 THEN
      RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;
    SELECT COUNT(*) INTO v_count FROM allocations
    WHERE room_id = NEW.room_id AND status = 'ACTIVE'
      AND allocation_id IS DISTINCT FROM NEW.allocation_id;
    IF v_count >= v_cap THEN
      RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_cap;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_alloc_rules();

SELECT fn_free_beds(1) AS room101, fn_free_beds(2) AS room102, fn_free_beds(3) AS room103;  -- 0, 2, 2
CALL pr_allocate_room(4, 2, CURRENT_DATE);     -- valid: student 4 only has an ENDED record
-- Rejection tests (run one at a time):
-- CALL pr_allocate_room(5, 1, CURRENT_DATE);                 -- room full
-- CALL pr_allocate_room(1, 3, CURRENT_DATE);                 -- student already ACTIVE
-- CALL pr_allocate_room(99, 3, CURRENT_DATE);                -- unknown student
-- INSERT INTO allocations (student_id, room_id, allocated_on, status)
--   VALUES (5, 1, CURRENT_DATE, 'ACTIVE');                   -- trigger blocks direct SQL

-- (e) View
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id) AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_id;

-- (f) Index
-- Justification: capacity checks only count ACTIVE rows; a partial index skips ENDED
-- history, so it stays small and fast as history grows.
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
SET enable_seqscan = off;
EXPLAIN SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE, r.room_id, COUNT(a.allocation_id), r.capacity - COUNT(a.allocation_id)
  FROM rooms r
  LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
  GROUP BY r.room_id, r.capacity
  ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds, free_beds = EXCLUDED.free_beds;
END $$;

-- SELECT cron.schedule('refresh_occupancy', '55 23 * * *', $$CALL pr_refresh_occupancy()$$);
DO $do$
BEGIN
  PERFORM cron.schedule('refresh_occupancy', '55 23 * * *', $$CALL pr_refresh_occupancy()$$);
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron not available here; job not created';
END
$do$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();    -- rerun replaces values
SELECT * FROM occupancy_snapshot ORDER BY room_id;