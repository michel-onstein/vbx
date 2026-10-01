import Foundation

/// The robot envelope's `output_format`, as vbx-cli writes it.
///
/// The engine stamps `output_format: json` on every payload carrying bv's
/// provenance, because the engine returns JSON (ADR-023). vbx-cli may then
/// re-encode the payload as TOON, and the envelope has to say so — bv's does.
public enum RobotEnvelope {
    /// Returns `payload` with `output_format` set to `format`, but only where
    /// the engine stamped one: anywhere else the key would be invented rather
    /// than corrected.
    public static func stamping(format: String, on payload: Any) -> Any {
        guard var envelope = payload as? [String: Any], envelope["output_format"] != nil else {
            return payload
        }
        envelope["output_format"] = format
        return envelope
    }
}
