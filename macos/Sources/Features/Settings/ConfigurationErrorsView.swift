import SwiftUI

protocol ConfigurationErrorsViewModel: ObservableObject {
    var errors: [String] { get set }
    var notice: ConfigurationErrorsController.Notice { get }
}

struct ConfigurationErrorsView<ViewModel: ConfigurationErrorsViewModel>: View {
    @ObservedObject var model: ViewModel

    var body: some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 52))
                    .padding()
                    .frame(alignment: .center)

                Text(summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(model.errors, id: \.self) { error in
                            Text(error)
                                .lineLimit(nil)
                                .font(.system(size: 12).monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }

                        Spacer()
                    }
                    .padding(.all)
                    .frame(minHeight: geo.size.height)
                    .background(Color(.controlBackgroundColor))
                }
            }

            HStack {
                Spacer()
                Button("Ignore") { model.errors = [] }
                    .keyboardShortcut(.cancelAction)
                Button("Reload Configuration") { reloadConfig() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding([.bottom, .trailing])
        }
        .frame(minWidth: 480, maxWidth: 960, minHeight: 270)
    }

    /// Diagnostics describe a configuration that loaded while skipping the
    /// broken lines. A rejection describes one that was not loaded at all,
    /// leaving the running configuration exactly as it was.
    ///
    /// The type must stay `LocalizedStringKey`: only the localized-string
    /// initializer parses the markdown and applies the `inflect` agreement,
    /// while a `String` renders the marker text itself.
    ///
    /// Within an inflected span only the word that ends it is pluralized, so
    /// the rejection names its noun last. The diagnostics wording keeps the
    /// original `error(s)` shorthand, which never pluralizes.
    private var summary: LocalizedStringKey {
        switch model.notice {
        case .diagnostics:
            return """
                ^[\(model.errors.count) error(s) were](inflect: true) found while loading the configuration. \
                Please review the errors below and reload your configuration or ignore the erroneous lines.
                """
        case .rejected:
            return """
                ^[\(model.errors.count) errors](inflect: true) kept this configuration from loading. \
                Nothing was changed. Fix the errors below and the configuration will reload on its own.
                """
        }
    }

    private func reloadConfig() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
        delegate.reloadConfig(nil)
    }
}
