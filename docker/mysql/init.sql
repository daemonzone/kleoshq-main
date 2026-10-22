-- Runs once on a fresh MySQL data volume (docker-entrypoint-initdb.d).
-- MYSQL_DATABASE already created the 'wordpress' db + granted the wordpress
-- user. Create the other sites' databases and grant the same user.
CREATE DATABASE IF NOT EXISTS wordpress2 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS wordpress3 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS wordpress4 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON wordpress2.* TO 'wordpress'@'%';
GRANT ALL PRIVILEGES ON wordpress3.* TO 'wordpress'@'%';
GRANT ALL PRIVILEGES ON wordpress4.* TO 'wordpress'@'%';
FLUSH PRIVILEGES;
