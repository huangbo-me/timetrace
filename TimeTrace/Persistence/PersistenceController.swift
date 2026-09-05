import Foundation
import SwiftData

@MainActor
final class PersistenceController {
    static let cloudKitContainerIdentifier = "iCloud.com.chronora.time.trace"
    let container: ModelContainer
    let context: ModelContext
    /// Whether this particular store was opened with CloudKit enabled. This is
    /// intentionally kept with the store configuration so the UI never claims
    /// to be syncing when the app had to fall back to a local-only store.
    let isCloudKitEnabled: Bool

    init(inMemory: Bool = false) throws {
        let schema = Schema([
            ActivityDefinition.self,
            ActivityTrigger.self,
            ActivityEvent.self,
            ActivitySession.self,
            ActivityEvidence.self,
            ReminderDefinition.self,
            ReminderInstance.self
        ])
        let configuration: ModelConfiguration
        // iCloud is optional: a person can use the app without being signed in and
        // must still be able to open and use their locally stored records.
        let canUseICloud = !inMemory && FileManager.default.ubiquityIdentityToken != nil
        isCloudKitEnabled = canUseICloud
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                               cloudKitDatabase: .none)
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configuration = ModelConfiguration("TimeTrace", schema: schema,
                                               url: directory.appending(path: "TimeTrace.store"),
                                               cloudKitDatabase: canUseICloud
                                                   ? .private(Self.cloudKitContainerIdentifier)
                                                   : .none)
        }
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
    }
}
