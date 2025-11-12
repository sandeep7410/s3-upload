import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AWSSettings.shared
    @State private var validationMessage: String = ""

    var body: some View {
        Form {
            Section(header: Text("AWS Credentials")) {
                Toggle("Use custom credentials", isOn: $settings.useCustomCredentials)
                    .help("Enable to use the credentials you enter here. When disabled, the app will not attempt to use custom keys.")

                TextField("Access Key ID", text: $settings.accessKeyId)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.useCustomCredentials)

                SecureField("Secret Access Key", text: $settings.secretAccessKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.useCustomCredentials)

                TextField("Region (e.g., us-east-1)", text: $settings.region)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.useCustomCredentials)
            }

            Section(header: Text("S3 Defaults")) {
                TextField("Default bucket name", text: $settings.bucketName)
                    .textFieldStyle(.roundedBorder)
                    .help("Bucket S3Browser will use for browsing and selection.")
            }

            if !validationMessage.isEmpty {
                Text(validationMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Test Connection") {
                    Task {
                        await testConnection()
                    }
                }
                .disabled(!settings.useCustomCredentials)
            }
        }
        .padding()
        .frame(minWidth: 420)
    }

    @MainActor
    private func testConnection() async {
        validationMessage = ""
        guard settings.hasRequiredFields else {
            validationMessage = "Please fill Access Key ID, Secret Access Key, and Region, and enable the toggle."
            return
        }
        // Use a temporary S3Service and explicitly invalidate before testing.
        let service = S3Service()
        service.invalidateClient() // force rebuild using current settings
        do {
            _ = try await service.listBuckets()
            validationMessage = "Success: Able to list buckets."
        } catch {
            validationMessage = "Failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    SettingsView()
}
