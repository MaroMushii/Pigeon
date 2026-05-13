import SwiftData

/// Current schema version. Every time a model property is added, removed,
/// or renamed, bump to a new VersionedSchema and add a MigrationStage here.
/// Without this, SwiftData silently destroys the store on hash mismatch.
enum PigeonSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Channel.self, Post.self, Media.self, Reaction.self]
    }
}

enum PigeonMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [PigeonSchemaV1.self] }
    // No migration stages yet — V1 is the first versioned baseline.
    static var stages: [MigrationStage] { [] }
}
