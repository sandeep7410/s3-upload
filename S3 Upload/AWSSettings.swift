import Foundation
import Combine

final class AWSSettings: ObservableObject {
    static let shared = AWSSettings()

    private enum Keys {
        static let useCustomCredentials = "AWSSettings.useCustomCredentials"
        static let accessKeyId = "AWSSettings.accessKeyId"
        static let secretAccessKey = "AWSSettings.secretAccessKey"
        static let region = "AWSSettings.region"
    }

    @Published var useCustomCredentials: Bool {
        didSet { UserDefaults.standard.set(useCustomCredentials, forKey: Keys.useCustomCredentials) }
    }

    @Published var accessKeyId: String {
        didSet { UserDefaults.standard.set(accessKeyId, forKey: Keys.accessKeyId) }
    }

    @Published var secretAccessKey: String {
        didSet { UserDefaults.standard.set(secretAccessKey, forKey: Keys.secretAccessKey) }
    }

    @Published var region: String {
        didSet { UserDefaults.standard.set(region, forKey: Keys.region) }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.useCustomCredentials = defaults.object(forKey: Keys.useCustomCredentials) as? Bool ?? false
        self.accessKeyId = defaults.string(forKey: Keys.accessKeyId) ?? ""
        self.secretAccessKey = defaults.string(forKey: Keys.secretAccessKey) ?? ""
        self.region = defaults.string(forKey: Keys.region) ?? "us-east-1"
    }

    var hasRequiredFields: Bool {
        useCustomCredentials && !accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
