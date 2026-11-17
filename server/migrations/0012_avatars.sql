-- Profile photos: the R2 object avatars/<user id>/<avatar_key> (a JPEG). A new key per photo, so
-- clients cache each one for good.
ALTER TABLE users ADD COLUMN avatar_key TEXT;
