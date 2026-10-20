import Fluent
import FluentSQL

/// Groups: member spaces with text channels, Discord-style. Messages carry a
/// per-channel `seq` that `group_channels.last_seq` hands out inside the
/// insert transaction, so a channel's sequence has no gaps and a client can
/// catch up with `after=<seq>`. Content cascades with its author's account,
/// as on Boards; a group outlives its owner (ownership is reassigned).
struct CreateGroupsTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("groups")
            .id()
            .field("name", .string, .required)
            .field("description", .string, .required)
            .field("icon_emoji", .string)
            .field("topic", .string, .required)
            .field("ticker", .string)
            .field("visibility", .string, .required)
            .field("owner_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("member_count", .int, .required)
            .field("last_message_at", .datetime)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .field("deleted_at", .datetime)
            .create()
        try await database.createIndex(on: "groups", columns: ["owner_id", "created_at"])

        try await database.schema("group_channels")
            .id()
            .field("group_id", .uuid, .required, .references("groups", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("kind", .string, .required)
            .field("topic", .string)
            .field("position", .int, .required)
            .field("last_seq", .int64, .required)
            .field("last_message_at", .datetime)
            .field("created_at", .datetime, .required)
            .field("deleted_at", .datetime)
            .create()
        try await database.createIndex(on: "group_channels", columns: ["group_id", "position"])

        try await database.schema("group_members")
            .id()
            .field("group_id", .uuid, .required, .references("groups", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("role", .string, .required)
            .field("push_enabled", .bool, .required)
            .field("joined_at", .datetime, .required)
            .unique(on: "group_id", "user_id")
            .create()
        try await database.createIndex(on: "group_members", columns: ["user_id"])

        try await database.schema("group_channel_reads")
            .id()
            .field("channel_id", .uuid, .required, .references("group_channels", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("last_read_seq", .int64, .required)
            .field("updated_at", .datetime, .required)
            .unique(on: "channel_id", "user_id")
            .create()

        try await database.schema("group_messages")
            .id()
            .field("channel_id", .uuid, .required, .references("group_channels", "id", onDelete: .cascade))
            .field("group_id", .uuid, .required, .references("groups", "id", onDelete: .cascade))
            .field("author_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("seq", .int64, .required)
            .field("client_message_id", .string, .required)
            .field("body", .string, .required)
            .field("created_at", .datetime, .required)
            .field("deleted_at", .datetime)
            .field("deleted_by", .uuid, .references("users", "id", onDelete: .setNull))
            .unique(on: "channel_id", "seq")
            .unique(on: "author_id", "client_message_id")
            .create()
        try await database.createIndex(on: "group_messages", columns: ["author_id", "created_at"])
        try await database.createIndex(on: "group_messages", columns: ["group_id", "created_at"])

        try await database.schema("group_invites")
            .id()
            .field("group_id", .uuid, .required, .references("groups", "id", onDelete: .cascade))
            .field("created_by", .uuid, .references("users", "id", onDelete: .setNull))
            .field("code", .string)
            .field("invitee_id", .uuid, .references("users", "id", onDelete: .cascade))
            .field("expires_at", .datetime)
            .field("max_uses", .int)
            .field("uses", .int, .required)
            .field("revoked_at", .datetime)
            .field("accepted_at", .datetime)
            .field("created_at", .datetime, .required)
            .create()
        try await database.createIndex(on: "group_invites", columns: ["group_id", "created_at"])
        try await database.createIndex(on: "group_invites", columns: ["invitee_id", "accepted_at"])

        try await database.schema("group_bans")
            .id()
            .field("group_id", .uuid, .required, .references("groups", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("banned_by", .uuid, .references("users", "id", onDelete: .setNull))
            .field("reason", .string)
            .field("created_at", .datetime, .required)
            .unique(on: "group_id", "user_id")
            .create()

        if let sql = database as? any SQLDatabase {
            // A deleted channel frees its name.
            try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS uq_group_channels_name
            ON group_channels (group_id, name) WHERE deleted_at IS NULL
            """).run()
            try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_groups_public_ticker
            ON groups (ticker) WHERE visibility = 'public' AND deleted_at IS NULL
            """).run()
            try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_groups_public_rank
            ON groups (member_count DESC, last_message_at DESC) WHERE visibility = 'public' AND deleted_at IS NULL
            """).run()
            try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS uq_group_invites_code ON group_invites (code) WHERE code IS NOT NULL
            """).run()
            // A row is either a shareable link or a direct invitation, never both.
            try await sql.raw("""
            ALTER TABLE group_invites ADD CONSTRAINT ck_group_invites_kind
            CHECK ((code IS NULL) <> (invitee_id IS NULL))
            """).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("group_bans").delete()
        try await database.schema("group_invites").delete()
        try await database.schema("group_messages").delete()
        try await database.schema("group_channel_reads").delete()
        try await database.schema("group_members").delete()
        try await database.schema("group_channels").delete()
        try await database.schema("groups").delete()
    }
}
