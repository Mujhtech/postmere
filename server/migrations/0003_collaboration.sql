CREATE TABLE shared_threads (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    owner_id UUID NOT NULL,
    account_id UUID NOT NULL,
    provider_thread_id TEXT NOT NULL CHECK (length(provider_thread_id) BETWEEN 1 AND 512),
    subject TEXT NOT NULL CHECK (length(subject) <= 1000),
    messages JSONB NOT NULL CHECK (jsonb_typeof(messages) = 'array'),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (workspace_id,id,owner_id),
    FOREIGN KEY (workspace_id,owner_id,account_id) REFERENCES provider_accounts(workspace_id,user_id,id) ON DELETE CASCADE,
    FOREIGN KEY (workspace_id,owner_id) REFERENCES memberships(workspace_id,user_id) ON DELETE CASCADE
);

-- owner_id is checked by a composite FK, so a forged owner cannot create ACLs.
-- ACL reads reveal only the caller's entry or entries controlled by the owner.
-- This avoids recursive RLS policies while allowing shared_threads to check ACLs.
CREATE TABLE shared_thread_members (
    workspace_id UUID NOT NULL,
    thread_id UUID NOT NULL,
    owner_id UUID NOT NULL,
    user_id UUID NOT NULL,
    permission TEXT NOT NULL CHECK (permission IN ('view','comment')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (thread_id,user_id),
    FOREIGN KEY (workspace_id,thread_id,owner_id) REFERENCES shared_threads(workspace_id,id,owner_id) ON DELETE CASCADE,
    FOREIGN KEY (workspace_id,user_id) REFERENCES memberships(workspace_id,user_id) ON DELETE CASCADE,
    CHECK (owner_id <> user_id)
);
CREATE INDEX shared_thread_members_user ON shared_thread_members(workspace_id,user_id,thread_id);
ALTER TABLE shared_thread_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_thread_members FORCE ROW LEVEL SECURITY;
CREATE POLICY shared_thread_members_read ON shared_thread_members FOR SELECT USING (
    workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
    AND (owner_id = nullif(current_setting('postmere.user_id',true),'')::uuid OR user_id = nullif(current_setting('postmere.user_id',true),'')::uuid)
);
CREATE POLICY shared_thread_members_write ON shared_thread_members FOR ALL USING (
    workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid AND owner_id = nullif(current_setting('postmere.user_id',true),'')::uuid
) WITH CHECK (
    workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid AND owner_id = nullif(current_setting('postmere.user_id',true),'')::uuid
);

ALTER TABLE shared_threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_threads FORCE ROW LEVEL SECURITY;
CREATE POLICY shared_threads_read ON shared_threads FOR SELECT USING (
    workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid
    AND (owner_id = nullif(current_setting('postmere.user_id',true),'')::uuid OR EXISTS (
        SELECT 1 FROM shared_thread_members a WHERE a.thread_id=shared_threads.id AND a.workspace_id=shared_threads.workspace_id AND a.user_id=nullif(current_setting('postmere.user_id',true),'')::uuid
    ))
);
CREATE POLICY shared_threads_write ON shared_threads FOR ALL USING (
    workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid AND owner_id = nullif(current_setting('postmere.user_id',true),'')::uuid
) WITH CHECK (
    workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid AND owner_id = nullif(current_setting('postmere.user_id',true),'')::uuid
);

CREATE TABLE shared_comments (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    thread_id UUID NOT NULL,
    owner_id UUID NOT NULL,
    author_id UUID NOT NULL,
    body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 10000),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (workspace_id,thread_id,owner_id) REFERENCES shared_threads(workspace_id,id,owner_id) ON DELETE CASCADE,
    FOREIGN KEY (workspace_id,author_id) REFERENCES memberships(workspace_id,user_id) ON DELETE CASCADE
);
CREATE INDEX shared_comments_thread ON shared_comments(workspace_id,thread_id,created_at,id);
ALTER TABLE shared_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_comments FORCE ROW LEVEL SECURITY;
CREATE POLICY shared_comments_read ON shared_comments FOR SELECT USING (
    workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid AND (owner_id=nullif(current_setting('postmere.user_id',true),'')::uuid OR EXISTS (
        SELECT 1 FROM shared_thread_members a WHERE a.thread_id=shared_comments.thread_id AND a.workspace_id=shared_comments.workspace_id AND a.user_id=nullif(current_setting('postmere.user_id',true),'')::uuid
    ))
);
CREATE POLICY shared_comments_insert ON shared_comments FOR INSERT WITH CHECK (
    workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid AND author_id=nullif(current_setting('postmere.user_id',true),'')::uuid AND (owner_id=nullif(current_setting('postmere.user_id',true),'')::uuid OR EXISTS (
        SELECT 1 FROM shared_thread_members a WHERE a.thread_id=shared_comments.thread_id AND a.workspace_id=shared_comments.workspace_id AND a.user_id=nullif(current_setting('postmere.user_id',true),'')::uuid AND a.permission='comment'
    ))
);
CREATE POLICY shared_comments_delete ON shared_comments FOR DELETE USING (
    workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid AND (owner_id=nullif(current_setting('postmere.user_id',true),'')::uuid OR (author_id=nullif(current_setting('postmere.user_id',true),'')::uuid AND EXISTS (
        SELECT 1 FROM shared_thread_members a WHERE a.thread_id=shared_comments.thread_id AND a.workspace_id=shared_comments.workspace_id AND a.user_id=nullif(current_setting('postmere.user_id',true),'')::uuid
    )))
);

CREATE TABLE shared_reply_presence (
    workspace_id UUID NOT NULL,
    thread_id UUID NOT NULL,
    owner_id UUID NOT NULL,
    user_id UUID NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (thread_id,user_id),
    FOREIGN KEY (workspace_id,thread_id,owner_id) REFERENCES shared_threads(workspace_id,id,owner_id) ON DELETE CASCADE,
    FOREIGN KEY (workspace_id,user_id) REFERENCES memberships(workspace_id,user_id) ON DELETE CASCADE
);
ALTER TABLE shared_reply_presence ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_reply_presence FORCE ROW LEVEL SECURITY;
CREATE POLICY shared_presence_read ON shared_reply_presence FOR SELECT USING (
    workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid AND (owner_id=nullif(current_setting('postmere.user_id',true),'')::uuid OR EXISTS (
        SELECT 1 FROM shared_thread_members a WHERE a.thread_id=shared_reply_presence.thread_id AND a.workspace_id=shared_reply_presence.workspace_id AND a.user_id=nullif(current_setting('postmere.user_id',true),'')::uuid
    ))
);
CREATE POLICY shared_presence_write ON shared_reply_presence FOR ALL USING (
    workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid AND user_id=nullif(current_setting('postmere.user_id',true),'')::uuid AND (owner_id=user_id OR EXISTS (
        SELECT 1 FROM shared_thread_members a WHERE a.thread_id=shared_reply_presence.thread_id AND a.workspace_id=shared_reply_presence.workspace_id AND a.user_id=nullif(current_setting('postmere.user_id',true),'')::uuid AND a.permission='comment'
    ))
) WITH CHECK (
    workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid AND user_id=nullif(current_setting('postmere.user_id',true),'')::uuid AND (owner_id=user_id OR EXISTS (
        SELECT 1 FROM shared_thread_members a WHERE a.thread_id=shared_reply_presence.thread_id AND a.workspace_id=shared_reply_presence.workspace_id AND a.user_id=nullif(current_setting('postmere.user_id',true),'')::uuid AND a.permission='comment'
    ))
);
CREATE POLICY shared_presence_owner_delete ON shared_reply_presence FOR DELETE USING (
    workspace_id = nullif(current_setting('postmere.workspace_id',true),'')::uuid AND owner_id=nullif(current_setting('postmere.user_id',true),'')::uuid
);

CREATE TABLE shared_snippets (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    owner_id UUID NOT NULL,
    template JSONB NOT NULL CHECK (jsonb_typeof(template)='object'),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version>0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (workspace_id,owner_id) REFERENCES memberships(workspace_id,user_id) ON DELETE CASCADE
);
CREATE INDEX shared_snippets_workspace ON shared_snippets(workspace_id,updated_at DESC,id);
ALTER TABLE shared_snippets ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_snippets FORCE ROW LEVEL SECURITY;
CREATE POLICY shared_snippets_read ON shared_snippets FOR SELECT USING (workspace_id=nullif(current_setting('postmere.workspace_id',true),'')::uuid);
CREATE POLICY shared_snippets_write ON shared_snippets FOR ALL USING (
    workspace_id=nullif(current_setting('postmere.workspace_id',true),'')::uuid AND owner_id=nullif(current_setting('postmere.user_id',true),'')::uuid
) WITH CHECK (
    workspace_id=nullif(current_setting('postmere.workspace_id',true),'')::uuid AND owner_id=nullif(current_setting('postmere.user_id',true),'')::uuid
);
