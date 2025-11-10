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
        // Try a simple listBuckets call using a temporary S3Service instance.
        let service = S3Service()
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
