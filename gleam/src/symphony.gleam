import gleam/erlang/process
import gleam/io
import symphony/config
import symphony/orchestrator

/// Main entry point for the Symphony orchestrator
pub fn main() {
  io.println("Symphony Orchestrator starting...")

  // Get config path from environment
  case get_config_path() {
    Ok(config_path) -> {
      io.println("Loading configuration from: " <> config_path)

      // Load configuration
      case config.load(config_path) {
        Ok(config) -> {
          io.println("Configuration loaded successfully")

          // Start the orchestrator
          case orchestrator.start(config) {
            Ok(_subject) -> {
              io.println("Orchestrator started successfully")
              // Sleep forever to keep the process alive
              process.sleep_forever()
            }
            Error(e) -> {
              io.println("Failed to start orchestrator: " <> e)
              process.sleep(1000)
            }
          }
        }
        Error(e) -> {
          io.println("Failed to load configuration: " <> e)
          process.sleep(1000)
        }
      }
    }
    Error(e) -> {
      io.println("Configuration error: " <> e)
      process.sleep(1000)
    }
  }
}

/// Get configuration path from environment
fn get_config_path() -> Result(String, String) {
  case get_env("WORKFLOW_PATH") {
    Ok(path) -> Ok(path)
    Error(_) -> Error("WORKFLOW_PATH environment variable not set")
  }
}

/// Get environment variable
fn get_env(name: String) -> Result(String, Nil) {
  do_get_env(name)
}

@external(erlang, "os", "getenv")
fn do_get_env(name: String) -> Result(String, Nil)
