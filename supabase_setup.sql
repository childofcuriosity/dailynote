-- ========================================
-- Diary Assistant (DailyNote) Supabase table creation script
-- ========================================
-- Execute this script in the Supabase SQL Editor
-- https://supabase.com/dashboard → your project → SQL Editor
-- Tip: select "Run without RLS", then add RLS after execution

-- 1. conversations table
CREATE TABLE IF NOT EXISTS conversations (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  summary TEXT,
  user_note TEXT,
  forked_from TEXT,
  created_at BIGINT NOT NULL,
  last_active_at BIGINT NOT NULL,
  last_archived_at BIGINT,
  updated_at BIGINT NOT NULL
);

-- 2. messages table
CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
  content TEXT NOT NULL,
  reasoning TEXT,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL
);

-- 3. memories table
CREATE TABLE IF NOT EXISTS memories (
  id TEXT PRIMARY KEY,
  content TEXT NOT NULL,
  source_conv_id TEXT REFERENCES conversations(id) ON DELETE SET NULL,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL
);

-- 4. tags table
CREATE TABLE IF NOT EXISTS tags (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL
);

-- 5. conversation_tags conversation-tag association table
CREATE TABLE IF NOT EXISTS conversation_tags (
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  PRIMARY KEY (conversation_id, tag_id)
);

-- ========================================
-- Indexes
-- ========================================
CREATE INDEX idx_messages_conv ON messages(conversation_id);
CREATE INDEX idx_messages_updated ON messages(updated_at);
CREATE INDEX idx_conversations_updated ON conversations(updated_at);
CREATE INDEX idx_memories_updated ON memories(updated_at);
CREATE INDEX idx_tags_updated ON tags(updated_at);
CREATE INDEX idx_memories_content ON memories(content);

-- ========================================
-- RLS (Row Level Security) — personal project: fully open
-- ========================================
ALTER TABLE conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE memories ENABLE ROW LEVEL SECURITY;
ALTER TABLE tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversation_tags ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow all on conversations" ON conversations FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Allow all on messages" ON messages FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Allow all on memories" ON memories FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Allow all on tags" ON tags FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Allow all on conversation_tags" ON conversation_tags FOR ALL USING (true) WITH CHECK (true);
