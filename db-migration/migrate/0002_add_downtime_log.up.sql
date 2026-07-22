CREATE TABLE downtime_log (
  id BIGSERIAL PRIMARY KEY,
  reason TEXT NOT NULL,
  minutes INT NOT NULL,
  area TEXT
);