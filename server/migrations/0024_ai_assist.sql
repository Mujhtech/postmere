-- Writing style learned from the user's own sent mail, kept beside the style
-- guidance they write themselves. Empty until they ask for it.
ALTER TABLE ai_preferences
    ADD COLUMN learned_style TEXT NOT NULL DEFAULT '' CHECK (length(learned_style) <= 1000),
    ADD COLUMN learned_at TIMESTAMPTZ;
