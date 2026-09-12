// DTOs, ExtraDockDocksAPI and ExtraDockDocksClient are generated from Contract.talk.json.
// There is deliberately no dependency on the ExtraDock apps or their implementation.
public enum ExtraDockRouting {
    /// Public routing hints only. Pairing does not verify the app's publisher.
    /// Both ExtraDock generations publish the same contract; a saved grant's
    /// `providerBundleID` says which one approved it.
    public static let extraDock5BundleID = "com.appitstudio.ExtraDock"
    public static let extraDock4BundleID = "dignicy.extraDock"
    public static let providerBundleIDs: [String] = [extraDock5BundleID, extraDock4BundleID]

    /// Snapshot bounds the providers enforce so a frame stays under 64 KiB.
    /// `ExtraDockSummary.itemCount` always carries the real item total.
    public static let maximumDocksPerSnapshot = 24
    public static let maximumItemsPerDock = 8
    /// One request may carry at most this many `DockVisibilityChange` entries.
    public static let maximumChangesPerRequest = 64
}
