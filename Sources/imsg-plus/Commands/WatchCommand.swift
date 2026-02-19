import Commander
import Foundation
import IMsgCore

enum WatchCommand {
  static let spec = CommandSpec(
    name: "watch",
    abstract: "Stream incoming messages",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chatID", names: [.long("chat-id")], help: "limit to chat rowid"),
          .make(
            label: "debounce", names: [.long("debounce")],
            help: "debounce interval for filesystem events (e.g. 250ms)"),
          .make(
            label: "sinceRowID", names: [.long("since-rowid")],
            help: "start watching after this rowid"),
          .make(
            label: "participants", names: [.long("participants")],
            help: "filter by participant handles", parsing: .upToNextOption),
          .make(label: "start", names: [.long("start")], help: "ISO8601 start (inclusive)"),
          .make(label: "end", names: [.long("end")], help: "ISO8601 end (exclusive)"),
        ],
        flags: [
          .make(
            label: "attachments", names: [.long("attachments")], help: "include attachment metadata"
          ),
          .make(
            label: "typing", names: [.long("typing")],
            help: "include peer typing events (requires IMCore helper)"
          )
        ]
      )
    ),
    usageExamples: [
      "imsg watch --chat-id 1 --attachments --debounce 250ms",
      "imsg watch --chat-id 1 --participants +15551234567",
      "imsg watch --typing --json",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) },
    streamProvider:
      @escaping (
        MessageWatcher,
        Int64?,
        Int64?,
        MessageWatcherConfiguration
      ) -> AsyncThrowingStream<Message, Error> = { watcher, chatID, sinceRowID, config in
        watcher.stream(chatID: chatID, sinceRowID: sinceRowID, configuration: config)
      },
    typingStreamProvider:
      @escaping (String?) -> AsyncThrowingStream<TypingChangeEvent, Error> = { handle in
        typingStream(handle: handle)
      }
  ) async throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let chatID = values.optionInt64("chatID")
    let debounceString = values.option("debounce") ?? "250ms"
    guard let debounceInterval = DurationParser.parse(debounceString) else {
      throw ParsedValuesError.invalidOption("debounce")
    }
    let sinceRowID = values.optionInt64("sinceRowID")
    let showAttachments = values.flag("attachments")
    let includeTyping = values.flag("typing")
    let participants = values.optionValues("participants")
      .flatMap { $0.split(separator: ",").map { String($0) } }
      .filter { !$0.isEmpty }
    let filter = try MessageFilter.fromISO(
      participants: participants,
      startISO: values.option("start"),
      endISO: values.option("end")
    )

    let store = try storeFactory(dbPath)
    let watcher = MessageWatcher(store: store)
    let config = MessageWatcherConfiguration(
      debounceInterval: debounceInterval,
      batchLimit: 100
    )

    let stream = streamProvider(watcher, chatID, sinceRowID, config)
    if !includeTyping {
      for try await message in stream {
        try emitMessage(
          message,
          filter: filter,
          store: store,
          runtime: runtime,
          showAttachments: showAttachments
        )
      }
      return
    }

    let availability = IMCoreBridge.shared.checkAvailability()
    guard availability.available else {
      throw IMsgError.invalidArgument(
        "--typing requested but IMCore helper is unavailable: \(availability.message)"
      )
    }

    let typingHandle = try typingSubscriptionHandle(chatID: chatID, store: store)
    let typingStream = typingStreamProvider(typingHandle)
    let participantFilter = Set(participants)

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for try await message in stream {
          try emitMessage(
            message,
            filter: filter,
            store: store,
            runtime: runtime,
            showAttachments: showAttachments
          )
        }
      }

      group.addTask {
        for try await event in typingStream {
          if !participantFilter.isEmpty && !participantFilter.contains(event.handle) {
            continue
          }
          try emitTyping(event, runtime: runtime)
        }
      }

      try await group.waitForAll()
    }
  }

  private static func emitMessage(
    _ message: Message,
    filter: MessageFilter,
    store: MessageStore,
    runtime: RuntimeOptions,
    showAttachments: Bool
  ) throws {
    if !filter.allows(message) {
      return
    }
    if runtime.jsonOutput {
      let attachments = try store.attachments(for: message.rowID)
      let reactions = try store.reactions(for: message.rowID)
      let payload = MessagePayload(
        message: message,
        attachments: attachments,
        reactions: reactions
      )
      try JSONLines.print(payload)
      return
    }
    let direction = message.isFromMe ? "sent" : "recv"
    let timestamp = CLIISO8601.format(message.date)
    Swift.print("\(timestamp) [\(direction)] \(message.sender): \(message.text)")
    if message.attachmentsCount > 0 {
      if showAttachments {
        let metas = try store.attachments(for: message.rowID)
        for meta in metas {
          let name = displayName(for: meta)
          Swift.print(
            "  attachment: name=\(name) mime=\(meta.mimeType) missing=\(meta.missing) path=\(meta.originalPath)"
          )
        }
      } else {
        Swift.print(
          "  (\(message.attachmentsCount) attachment\(pluralSuffix(for: message.attachmentsCount)))"
        )
      }
    }
  }

  private static func emitTyping(_ event: TypingChangeEvent, runtime: RuntimeOptions) throws {
    if runtime.jsonOutput {
      let payload: [String: Any] = [
        "type": "typing",
        "chat_guid": event.chatGUID,
        "chat_id": event.chatID,
        "handle": event.handle,
        "is_typing": event.isTyping,
        "timestamp": event.timestamp,
      ]
      Swift.print(JSONSerialization.string(from: payload))
      return
    }

    let chatReference = event.chatGUID.isEmpty ? event.chatID : event.chatGUID
    let state = event.isTyping ? "started typing" : "stopped typing"
    Swift.print("\(event.timestamp) [typing] \(event.handle) \(state) (\(chatReference))")
  }

  private static func typingSubscriptionHandle(chatID: Int64?, store: MessageStore) throws -> String? {
    guard let chatID else { return nil }
    guard let info = try store.chatInfo(chatID: chatID) else {
      throw IMsgError.invalidArgument("Unknown chat-id \(chatID)")
    }
    if !info.guid.isEmpty {
      return info.guid
    }
    if !info.identifier.isEmpty {
      return info.identifier
    }
    return nil
  }

  private static func typingStream(handle: String?) -> AsyncThrowingStream<TypingChangeEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let subscription = try await IMCoreBridge.shared.subscribeToTyping(handle: handle)
          defer {
            Task {
              try? await IMCoreBridge.shared.unsubscribeFromTyping(subscription: subscription)
            }
          }

          while !Task.isCancelled {
            let events = try await IMCoreBridge.shared.pollTyping(subscription: subscription)
            for event in events {
              continuation.yield(event)
            }
            try await Task.sleep(nanoseconds: 350_000_000)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }
}
