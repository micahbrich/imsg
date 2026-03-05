import Commander
import Foundation
import IMsgCore

enum EditCommand {
  static let spec = CommandSpec(
    name: "edit",
    abstract: "Edit or unsend a message",
    discussion: """
      Edit the text of a previously sent message, or unsend it entirely.
      Requires the message GUID (from history or watch commands) and the
      chat handle.

      Note: Requires advanced permissions (SIP disabled) for full functionality.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(
            label: "handle", names: [.long("handle")],
            help: "Phone number, email, or chat identifier"),
          .make(label: "guid", names: [.long("guid")], help: "Message GUID to edit"),
          .make(label: "text", names: [.long("text")], help: "New message text"),
        ],
        flags: [
          .make(
            label: "unsend", names: [.long("unsend")],
            help: "Unsend (retract) the message instead of editing"),
          .make(
            label: "markdown", names: [.long("markdown")],
            help: "Parse text as markdown and send with formatting"),
        ]
      )
    ),
    usageExamples: [
      "imsg edit --handle +14155551234 --guid ABC123-456 --text \"corrected text\"",
      "imsg edit --handle +14155551234 --guid ABC123-456 --unsend",
      "imsg edit --handle +14155551234 --guid ABC123-456 --text \"**bold**\" --markdown",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let handle = values.option("handle") else {
      throw IMsgError.invalidArgument("--handle is required")
    }
    guard let guid = values.option("guid") else {
      throw IMsgError.invalidArgument("--guid is required")
    }

    let unsend = values.flag("unsend")
    let text = values.option("text") ?? ""
    let useMarkdown = values.flag("markdown")

    if unsend && !text.isEmpty {
      throw IMsgError.invalidArgument("--unsend and --text are mutually exclusive")
    }
    if !unsend && text.isEmpty {
      throw IMsgError.invalidArgument("--text or --unsend is required")
    }

    let bridge = IMCoreBridge.shared
    let availability = bridge.checkAvailability()

    if !availability.available {
      print("⚠️  \(availability.message)")
      print("\nEdit/unsend requires advanced features to be enabled.")
      return
    }

    do {
      if unsend {
        try await bridge.unsendMessage(handle: handle, messageGUID: guid)

        if runtime.jsonOutput {
          let output: [String: Any] = [
            "success": true,
            "handle": handle,
            "message_guid": guid,
            "action": "unsent",
          ]
          print(JSONSerialization.string(from: output))
        } else {
          print("Unsent message \(guid)")
        }
      } else {
        var attrData: Data? = nil
        if useMarkdown {
          attrData = MarkdownComposer.compose(text)
        }
        try await bridge.editMessage(
          handle: handle, messageGUID: guid, newText: text, attributedText: attrData)

        if runtime.jsonOutput {
          var output: [String: Any] = [
            "success": true,
            "handle": handle,
            "message_guid": guid,
            "action": "edited",
          ]
          if useMarkdown { output["markdown"] = true }
          print(JSONSerialization.string(from: output))
        } else {
          print("Edited message \(guid)")
        }
      }
    } catch let error as IMCoreBridgeError {
      if runtime.jsonOutput {
        let output: [String: Any] = [
          "success": false,
          "error": error.description,
          "handle": handle,
          "message_guid": guid,
        ]
        print(JSONSerialization.string(from: output))
      } else {
        print("❌ \(error)")
      }
      throw error
    }
  }
}
