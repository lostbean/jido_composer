# Compose actions and agents through configured nodes

<a id="adr-0001"></a>

- Migrated rationale from the existing Node and Interface documents; this record is part of the unapproved migration draft.
- Jido Actions lack transition outcomes and agent lifecycle configuration.
- Composer therefore uses a Node adapter with per-instance configuration while leaving the underlying Action and Agent interfaces unchanged.
- The uniform contract permits workflows and orchestrators to nest in either direction.
