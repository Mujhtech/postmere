-- Gmail stores opaque label IDs on each message; their names live in the
-- account's label catalog. Caching the names lets questions and search match a
-- label such as "Rejection" without a provider round trip.
CREATE TABLE mail_label_names (
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id UUID NOT NULL,
    label_id TEXT NOT NULL CHECK (length(label_id) BETWEEN 1 AND 4096),
    name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 4096),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, label_id),
    FOREIGN KEY (workspace_id, user_id, account_id) REFERENCES provider_accounts(workspace_id, user_id, id) ON DELETE CASCADE,
    FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id) ON DELETE CASCADE
);
ALTER TABLE mail_label_names ENABLE ROW LEVEL SECURITY;
ALTER TABLE mail_label_names FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_user_scope ON mail_label_names
    USING (workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
       AND user_id = nullif(current_setting('postmere.user_id',true),'')::uuid)
    WITH CHECK (workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
       AND user_id = nullif(current_setting('postmere.user_id',true),'')::uuid);

-- Names of the Gmail labels on a message, kept current as the catalog changes.
ALTER TABLE mail_messages ADD COLUMN label_text TEXT NOT NULL DEFAULT '';

-- English stemming matches "rejection" with "rejected" and "rejections".
-- Subjects, label names and Outlook categories (already names) outrank body text.
-- Punctuation becomes spaces so a nested label such as "Jobs/Rejection" is two words.
ALTER TABLE mail_messages ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (
    setweight(to_tsvector('english'::regconfig, coalesce(normalized->>'subject', '')), 'A')
    || setweight(to_tsvector('english'::regconfig, regexp_replace(label_text, '[^[:alnum:]]+', ' ', 'g')), 'A')
    || setweight(to_tsvector('english'::regconfig, regexp_replace(coalesce(normalized->'categories', '[]'::jsonb)::text, '[^[:alnum:]]+', ' ', 'g')), 'A')
    || setweight(to_tsvector('english'::regconfig, search_text), 'C')
) STORED;
CREATE INDEX mail_messages_search_vector ON mail_messages USING GIN (search_vector) WHERE deleted_at IS NULL;
DROP INDEX mail_messages_search;

-- Counting the messages under a label.
CREATE INDEX mail_messages_provider_labels ON mail_messages USING GIN ((normalized->'provider_labels')) WHERE deleted_at IS NULL;
