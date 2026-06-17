/// ByteFormatting.swift - single shared byte-count formatter for the AppUI module.
///
/// Consolidates what used to be three byte-identical copies of the same decimal
/// (SI) formatter (a free function in StyleHelpers, a private static on
/// FlashProgressSnapshot, and a private static on AppViewModel). All call sites
/// now route through `formatBytes(_:)` so the format lives in one place.

import Foundation

// MARK: - Bytes formatting

/// Format a byte count as a compact human-readable string using decimal (SI)
/// prefixes (GB/MB/KB at 1e9/1e6/1e3), matching how disk manufacturers and the
/// OS report capacity.
///
/// Generic over `BinaryInteger` so both `Int` (disk sizes) and `UInt64`
/// (progress byte counts) callers share one implementation; the value is
/// converted to `Double` for the magnitude math and interpolated unchanged in
/// the sub-kilobyte "N B" branch.
func formatBytes<Integer: BinaryInteger>(_ bytes: Integer) -> String {
    let value = Double(bytes)
    if value >= 1_000_000_000 {
        return String(format: "%.1f GB", value / 1_000_000_000)
    }
    if value >= 1_000_000 {
        return String(format: "%.1f MB", value / 1_000_000)
    }
    if value >= 1_000 {
        return String(format: "%.1f KB", value / 1_000)
    }
    return "\(bytes) B"
}
