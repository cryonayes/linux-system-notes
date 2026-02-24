-- Advanced Reminder Bot Database Schema
-- PostgreSQL

-- User-defined places
CREATE TABLE IF NOT EXISTS user_places (
    id SERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    place_key VARCHAR(100) NOT NULL,
    lat DECIMAL(10, 8) NOT NULL,
    lon DECIMAL(11, 8) NOT NULL,
    default_radius_m INTEGER DEFAULT 50,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, place_key)
);

-- Reminders
CREATE TABLE IF NOT EXISTS reminders (
    id SERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    message TEXT NOT NULL,
    trigger_type VARCHAR(20) NOT NULL CHECK (trigger_type IN ('time', 'location', 'hybrid')),
    trigger_time TIMESTAMP WITH TIME ZONE,
    lat DECIMAL(10, 8),
    lon DECIMAL(11, 8),
    radius_m INTEGER DEFAULT 50,
    status VARCHAR(20) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'triggered', 'cancelled')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- User last known location
CREATE TABLE IF NOT EXISTS user_last_location (
    user_id BIGINT PRIMARY KEY,
    lat DECIMAL(10, 8) NOT NULL,
    lon DECIMAL(11, 8) NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_user_places_user_id ON user_places(user_id);
CREATE INDEX IF NOT EXISTS idx_reminders_user_id ON reminders(user_id);
CREATE INDEX IF NOT EXISTS idx_reminders_status ON reminders(status);
CREATE INDEX IF NOT EXISTS idx_reminders_trigger_type ON reminders(trigger_type);
CREATE INDEX IF NOT EXISTS idx_reminders_trigger_time ON reminders(trigger_time);
CREATE INDEX IF NOT EXISTS idx_reminders_active_location ON reminders(status, trigger_type) WHERE status = 'active' AND trigger_type IN ('location', 'hybrid');

-- Update timestamp trigger function
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Apply triggers
DROP TRIGGER IF EXISTS update_user_places_updated_at ON user_places;
CREATE TRIGGER update_user_places_updated_at
    BEFORE UPDATE ON user_places
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_reminders_updated_at ON reminders;
CREATE TRIGGER update_reminders_updated_at
    BEFORE UPDATE ON reminders
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_user_last_location_updated_at ON user_last_location;
CREATE TRIGGER update_user_last_location_updated_at
    BEFORE UPDATE ON user_last_location
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
