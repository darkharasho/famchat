-- Previous refresh token hash, accepted for a short grace window after rotation
-- (lost responses); reuse after the window revokes the device.
ALTER TABLE devices ADD COLUMN prev_refresh_hash TEXT;
ALTER TABLE devices ADD COLUMN refreshed_at INTEGER;
CREATE INDEX devices_prev_refresh ON devices(prev_refresh_hash);
