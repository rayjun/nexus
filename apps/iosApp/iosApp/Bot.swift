import Foundation

enum BotStatus: String, Codable {
    case online
    case offline
    case tombstoned
}

/// A bot = a Hermes profile on a paired server. Identity is the composite
/// `serverID:profileName` — stable because profile slugs are immutable
/// (lowercase alnum + `-_`, 1-64 chars, enforced server-side and client-side).
struct Bot: Identifiable, Codable, Equatable, Hashable {
    var id: String          // "<serverID>:<profileName>" — stable identity
    var serverID: String    // FK → ServerProfile.id
    var name: String        // profile slug (immutable, server truth)
    var displayName: String // profiles.list display_name (editable)
    var descriptor: String  // description from profiles.list
    var model: String
    var provider: String
    var status: BotStatus
    var lastPreview: String?   // last_session.preview
    var lastActiveAt: Date?    // last_session.last_active
    var lastSessionID: String? // last_session.id (resume target)
    /// Preferred session (live sid) pinned after create/resume — local
    /// `nexus_preferred_v2` map is authoritative. Tombstoned bots keep this
    /// until removed.
    var preferredSessionID: String?
    var isTombstoned: Bool = false
    var updatedAt: Date

    init(
        serverID: String,
        name: String,
        displayName: String = "",
        descriptor: String = "",
        model: String = "",
        provider: String = "",
        status: BotStatus = .online,
        lastPreview: String? = nil,
        lastActiveAt: Date? = nil,
        lastSessionID: String? = nil,
        preferredSessionID: String? = nil,
        isTombstoned: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = "\(serverID):\(name)"
        self.serverID = serverID
        self.name = name
        self.displayName = displayName
        self.descriptor = descriptor
        self.model = model
        self.provider = provider
        self.status = status
        self.lastPreview = lastPreview
        self.lastActiveAt = lastActiveAt
        self.lastSessionID = lastSessionID
        self.preferredSessionID = preferredSessionID
        self.isTombstoned = isTombstoned
        self.updatedAt = updatedAt
    }

    /// Validation used by CreateBotSheet (matches Hermes web UI slug regex
    /// `^[a-z0-9][a-z0-9_-]{0,63}$`).
    static func isValidSlug(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64 else { return false }
        let pattern = "^[a-z0-9][a-z0-9_-]{0,63}$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.firstMatch(in: s, range: range) != nil
    }

    var displayTitle: String { displayName.isEmpty ? name : displayName }
}