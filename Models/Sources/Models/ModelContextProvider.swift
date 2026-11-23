import Foundation
import Logging
import SwiftData

@MainActor
public final class ModelContextProvider {
  public static let shared = ModelContextProvider()

  private var containers: [String: ModelContainer] = [:]
  private var contexts: [String: ModelContext] = [:]
  public private(set) var activeServerID: String?

  public var context: ModelContext {
    if let activeServerID, let context = contexts[activeServerID] {
      return context
    }

    assertionFailure("No active server. Database access requires user to be logged in.")
    AppLogger.persistence.warning(
      "Accessing context without active server, using fallback database"
    )

    let serverID = "fallback"
    if let fallbackContext = contexts[serverID] {
      return fallbackContext
    }

    do {
      let fallbackContainer = try createContainer(for: serverID)
      containers[serverID] = fallbackContainer
      contexts[serverID] = fallbackContainer.mainContext
      return fallbackContainer.mainContext
    } catch {
      AppLogger.persistence.error(
        "Failed to create fallback container: \(error.localizedDescription)"
      )
      fatalError("Failed to create fallback database container")
    }
  }

  public var modelContainer: ModelContainer {
    if let activeServerID, let container = containers[activeServerID] {
      return container
    }

    _ = context
    guard let container = containers[activeServerID ?? "fallback"] else {
      fatalError("Failed to resolve active database container")
    }
    return container
  }

  private init() {}

  public func context(for serverID: String) throws -> ModelContext {
    if let context = contexts[serverID] {
      return context
    }

    let container = try createContainer(for: serverID)
    containers[serverID] = container
    contexts[serverID] = container.mainContext
    return container.mainContext
  }

  public func switchToServer(_ serverID: String) throws {
    if containers[serverID] == nil {
      let container = try createContainer(for: serverID)
      containers[serverID] = container
      contexts[serverID] = container.mainContext
    }
    activeServerID = serverID
    MediaProgress.reloadCache()
  }

  public func useInMemoryContainer(for serverID: String) throws {
    let schema = Schema(versionedSchema: AudiobookshelfSchema.self)
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: true)
    let container = try ModelContainer(for: schema, configurations: configuration)
    containers[serverID] = container
    contexts[serverID] = container.mainContext
    activeServerID = serverID
  }

  private func createContainer(for serverID: String) throws -> ModelContainer {
    let dbURL = databaseURL(for: serverID)
    let configuration = ModelConfiguration(url: dbURL, allowsSave: true)

    do {
      let schema = Schema(versionedSchema: AudiobookshelfSchema.self)
      let container = try ModelContainer(for: schema, configurations: configuration)
      AppLogger.persistence.info(
        "ModelContainer created successfully for server: \(serverID)"
      )
      return container
    } catch {
      AppLogger.persistence.error(
        "Failed to create persistent model container for server \(serverID): \(error)"
      )
      AppLogger.persistence.info("Backing up data and creating fresh container...")

      let backupID = ISO8601DateFormatter()
        .string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
      let fileExtensions = ["", "-shm", "-wal"]
      var backedUpFiles = 0
      for ext in fileExtensions {
        let fileURL = URL(fileURLWithPath: dbURL.path + ext)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
        let backupURL = URL(fileURLWithPath: "\(dbURL.path).backup-\(backupID)\(ext)")
        do {
          try FileManager.default.moveItem(at: fileURL, to: backupURL)
          backedUpFiles += 1
        } catch {
          AppLogger.persistence.error(
            "Failed to back up database file \(fileURL.lastPathComponent): \(error.localizedDescription)"
          )
          throw error
        }
      }

      AppLogger.persistence.info("Backed up \(backedUpFiles) existing database file(s)")

      do {
        let schema = Schema(versionedSchema: AudiobookshelfSchema.self)
        let container = try ModelContainer(for: schema, configurations: configuration)
        AppLogger.persistence.info("Fresh container created successfully")
        return container
      } catch {
        AppLogger.persistence.error("Failed to create fresh container: \(error)")
        throw error
      }
    }
  }

  private func databaseURL(for serverID: String) -> URL {
    let containerURL =
      FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.turnercore.audioBS"
      )
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

    return
      containerURL
      .appending(path: serverID)
      .appending(path: "AudiobookshelfData.sqlite")
  }
}
