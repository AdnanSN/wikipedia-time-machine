-- experiments/harness.sql: the stopwatch every experiment uses.
--
-- Each experiment's run.sql chooses its own database and then sources this file, which
-- creates there:
--   timing    one row per timed run: which experiment topic, which statement, how long
--   measure   a procedure that times one statement
--   report    a procedure that prints the timings of one topic
--   finding   what an experiment observed, as text, for behaviour we record but do not
--             insist on (it differs between MariaDB versions)
--   check_result   what an experiment insists on; a failed row stops the script
--
-- How a statement is timed: it is prepared once, run once without the clock (so that
-- the pages it needs are in memory and the plan is made), and then run @runs times.
-- Each run is timed with SYSDATE(6), which, unlike NOW(), returns the time at the
-- moment it is evaluated, so it can be used inside a procedure. Statements end in
-- INTO @variable, so nothing is sent to the client and only the server's work is timed.
--
-- @runs is 7 unless it was set before (CI sets it to 1: timings on a shared CI machine
-- mean little, but the statements still have to run and the checks still have to hold).

SET @runs = COALESCE(@runs, 7);

CREATE OR REPLACE TABLE timing (
  id    INT AUTO_INCREMENT PRIMARY KEY,
  topic VARCHAR(40) NOT NULL,
  label VARCHAR(120) NOT NULL,
  run   INT NOT NULL,
  ms    DOUBLE NOT NULL
);

CREATE OR REPLACE TABLE finding (
  id       INT AUTO_INCREMENT PRIMARY KEY,
  topic    VARCHAR(40) NOT NULL,
  what     VARCHAR(160) NOT NULL,
  observed VARCHAR(400) NULL
);

CREATE OR REPLACE TABLE check_result (
  id   INT AUTO_INCREMENT PRIMARY KEY,
  test VARCHAR(200) NOT NULL,
  pass BOOLEAN NOT NULL
);

DELIMITER //

CREATE OR REPLACE PROCEDURE measure(IN p_topic VARCHAR(40), IN p_label VARCHAR(120), IN p_sql TEXT)
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE started DATETIME(6);
  SET @measure_sql = p_sql;
  PREPARE measured FROM @measure_sql;
  EXECUTE measured;                                   -- warm-up, not timed
  WHILE i <= @runs DO
    SET started = SYSDATE(6);
    EXECUTE measured;
    INSERT INTO timing (topic, label, run, ms)
    VALUES (p_topic, p_label, i, TIMESTAMPDIFF(MICROSECOND, started, SYSDATE(6)) / 1000);
    SET i = i + 1;
  END WHILE;
  DEALLOCATE PREPARE measured;
END //

-- The fastest, the middle and the slowest run of each statement, in the order the
-- statements were measured. The spread between fastest and slowest is the noise.
CREATE OR REPLACE PROCEDURE report(IN p_topic VARCHAR(40))
BEGIN
  SELECT label, COUNT(*) AS runs,
         ROUND(MIN(ms), 3) AS fastest_ms, ROUND(middle, 3) AS median_ms, ROUND(MAX(ms), 3) AS slowest_ms
  FROM (SELECT id, label, ms, MEDIAN(ms) OVER (PARTITION BY label) AS middle
        FROM timing WHERE topic = p_topic) AS run
  GROUP BY label, middle
  ORDER BY MIN(id);
END //

-- Run a statement that may be refused, without stopping the script. Afterwards
-- @attempt_error holds MariaDB's error number (0 if the statement ran) and
-- @attempt_message the server's message. For showing what the server refuses.
CREATE OR REPLACE PROCEDURE attempt(IN p_sql TEXT)
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1 @attempt_error = MYSQL_ERRNO, @attempt_message = MESSAGE_TEXT;
  END;
  SET @attempt_error = 0, @attempt_message = 'accepted';
  SET @attempt_sql = p_sql;
  PREPARE attempted FROM @attempt_sql;
  EXECUTE attempted;
  DEALLOCATE PREPARE attempted;
END //

-- Print the checks of an experiment and stop with an error if one failed.
CREATE OR REPLACE PROCEDURE finish_checks(IN p_name VARCHAR(40))
BEGIN
  SELECT test, pass FROM check_result ORDER BY id;
  SELECT CONCAT(SUM(pass), ' / ', COUNT(*), ' ', p_name, ' checks passed') AS summary FROM check_result;
  IF EXISTS (SELECT 1 FROM check_result WHERE NOT pass) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'An experiment check failed: see the rows with pass = 0';
  END IF;
END //

DELIMITER ;
