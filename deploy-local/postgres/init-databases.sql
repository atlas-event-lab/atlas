-- Atlas local stack — create one database per service (database-per-service).
-- The `atlas` role is created by POSTGRES_USER; booking_db is POSTGRES_DB.
-- Schemas/tables are created by each service's Flyway migrations on startup.
CREATE DATABASE flight_db;
CREATE DATABASE hotel_db;
CREATE DATABASE inventory_db;
CREATE DATABASE search_db;
CREATE DATABASE payment_db;
CREATE DATABASE user_db;
CREATE DATABASE travel_cart_db;
