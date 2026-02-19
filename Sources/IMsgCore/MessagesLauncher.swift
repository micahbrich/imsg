import Foundation

/// Manages Messages.app lifecycle for DYLD injection
public final class MessagesLauncher: @unchecked Sendable {
  public static let shared = MessagesLauncher()

  // File-based IPC paths (must match the paths in IMsgInjected.m)
  // The dylib uses NSHomeDirectory() which resolves to the container path
  // But from outside we need to use the real home + container path
  private var commandFile: String {
    let containerPath =
      NSHomeDirectory() + "/Library/Containers/com.apple.MobileSMS/Data"
    return containerPath + "/.imsg-plus-command.json"
  }

  private var responseFile: String {
    let containerPath =
      NSHomeDirectory() + "/Library/Containers/com.apple.MobileSMS/Data"
    return containerPath + "/.imsg-plus-response.json"
  }

  private var lockFile: String {
    let containerPath =
      NSHomeDirectory() + "/Library/Containers/com.apple.MobileSMS/Data"
    return containerPath + "/.imsg-plus-ready"
  }

  private let messagesAppPath = "/System/Applications/Messages.app/Contents/MacOS/Messages"
  private let queue = DispatchQueue(label: "imsg.messages.launcher")
  private let lock = NSLock()

  /// Path to the dylib to inject
  public var dylibPath: String = ".build/release/imsg-plus-helper.dylib"

  private init() {
    // Look for dylib in multiple locations
    let possiblePaths = [
      ".build/release/imsg-plus-helper.dylib",
      ".build/debug/imsg-plus-helper.dylib",
      "/usr/local/lib/imsg-plus-helper.dylib",
      Bundle.main.bundlePath + "/../imsg-plus-helper.dylib",
    ]

    for path in possiblePaths {
      if FileManager.default.fileExists(atPath: path) {
        self.dylibPath = path
        break
      }
    }
  }

  /// Check if Messages.app is running with our dylib (lock file exists)
  public func isInjectedAndReady() -> Bool {
    // Check if lock file exists
    guard FileManager.default.fileExists(atPath: lockFile) else {
      return false
    }

    // Try to ping
    do {
      let response = try sendCommandSync(action: "ping", params: [:])
      return response["success"] as? Bool == true
    } catch {
      return false
    }
  }

  /// Ensure Messages.app is running with our dylib injected
  public func ensureRunning() throws {
    if isInjectedAndReady() {
      return
    }

    // Check if dylib exists
    guard FileManager.default.fileExists(atPath: dylibPath) else {
      throw MessagesLauncherError.dylibNotFound(dylibPath)
    }

    // Kill existing Messages.app if running
    killMessages()

    // Wait for Messages to fully terminate and clean up files
    Thread.sleep(forTimeInterval: 1.0)

    // Clean up old IPC files
    try? FileManager.default.removeItem(atPath: commandFile)
    try? FileManager.default.removeItem(atPath: responseFile)
    try? FileManager.default.removeItem(atPath: lockFile)

    // Launch Messages.app with dylib injection
    try launchWithInjection()

    // Wait for server to become available
    try waitForReady(timeout: 15.0)

    // Require a successful ping so status/availability doesn't report a false positive.
    guard isInjectedAndReady() else {
      throw MessagesLauncherError.socketError(
        "Messages helper launched but IPC ping failed. Check container file permissions and helper logs."
      )
    }
  }

  /// Kill Messages.app if running
  public func killMessages() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    task.arguments = ["Messages"]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice

    try? task.run()
    task.waitUntilExit()
  }

  /// Launch Messages.app with DYLD_INSERT_LIBRARIES
  private func launchWithInjection() throws {
    let absoluteDylibPath =
      dylibPath.hasPrefix("/")
      ? dylibPath
      : FileManager.default.currentDirectoryPath + "/" + dylibPath

    // Verify dylib exists at absolute path
    guard FileManager.default.fileExists(atPath: absoluteDylibPath) else {
      throw MessagesLauncherError.dylibNotFound(absoluteDylibPath)
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: messagesAppPath)

    // Set environment for dylib injection
    var environment = ProcessInfo.processInfo.environment
    environment["DYLD_INSERT_LIBRARIES"] = absoluteDylibPath
    task.environment = environment

    // Don't wait for the process (it runs in background)
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice

    do {
      try task.run()
    } catch {
      throw MessagesLauncherError.launchFailed(error.localizedDescription)
    }
  }

  /// Wait for lock file to appear
  private func waitForReady(timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if FileManager.default.fileExists(atPath: lockFile) {
        // Give it a moment to fully initialize
        Thread.sleep(forTimeInterval: 0.5)
        return
      }
      Thread.sleep(forTimeInterval: 0.5)
    }

    throw MessagesLauncherError.socketTimeout
  }

  /// Send a command synchronously using file-based IPC
  private func sendCommandSync(action: String, params: [String: Any]) throws -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }

    // Build command
    let command: [String: Any] = [
      "id": Int(Date().timeIntervalSince1970 * 1000),
      "action": action,
      "params": params,
    ]

    // Write command to file
    let jsonData = try JSONSerialization.data(withJSONObject: command, options: [])
    try jsonData.write(to: URL(fileURLWithPath: commandFile))

    // Wait for response (poll response file)
    let deadline = Date().addingTimeInterval(10.0)
    while Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)

      // Check if response file has content
      guard let responseData = try? Data(contentsOf: URL(fileURLWithPath: responseFile)),
        responseData.count > 2
      else {
        continue
      }

      // Check if command file was cleared (indicating processing completed)
      if let cmdData = try? Data(contentsOf: URL(fileURLWithPath: commandFile)),
        cmdData.count <= 2
      {

        // Parse response
        guard
          let response = try? JSONSerialization.jsonObject(with: responseData, options: [])
            as? [String: Any]
        else {
          throw MessagesLauncherError.invalidResponse
        }

        // Clear response file
        try? "".write(toFile: responseFile, atomically: true, encoding: .utf8)

        return response
      }
    }

    throw MessagesLauncherError.socketError("Timeout waiting for response")
  }

  /// Send a command asynchronously
  public func sendCommand(action: String, params: [String: Any]) async throws -> [String: Any] {
    // Ensure Messages.app is running with injection
    try ensureRunning()

    // Capture params as a sendable copy
    let paramsCopy = params

    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          let response = try self.sendCommandSync(action: action, params: paramsCopy)
          continuation.resume(returning: response)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

public enum MessagesLauncherError: Error, CustomStringConvertible {
  case dylibNotFound(String)
  case launchFailed(String)
  case socketTimeout
  case socketError(String)
  case invalidResponse

  public var description: String {
    switch self {
    case .dylibNotFound(let path):
      return
        "imsg-plus-helper.dylib not found at \(path). Build with: make build-dylib"
    case .launchFailed(let reason):
      return "Failed to launch Messages.app: \(reason)"
    case .socketTimeout:
      return
        "Timeout waiting for Messages.app to initialize. Ensure SIP is disabled and Messages.app has necessary permissions."
    case .socketError(let reason):
      return "IPC error: \(reason)"
    case .invalidResponse:
      return "Invalid response from Messages.app helper"
    }
  }
}
