//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Factory
import JellyfinAPI
import SwiftUI

/// - Note: Set the environment `isEditing` to `true` to
///         allow server deletion
struct EditServerView: View {

    @Router
    private var router

    @Environment(\.isEditing)
    private var isEditing

    @State
    private var isPresentingConfirmDeletion: Bool = false
    @State
    private var isURLSectionExpanded: Bool = false

    @StateObject
    private var viewModel: ServerConnectionViewModel

    init(server: ServerState) {
        self._viewModel = StateObject(wrappedValue: ServerConnectionViewModel(server: server))
    }

    var body: some View {
        List {
            Section {

                LabeledContent(
                    L10n.name,
                    value: viewModel.server.name
                )

                if let serverVersion = StoredValues[.Server.publicInfo(id: viewModel.server.id)].version {
                    LabeledContent(
                        L10n.version,
                        value: serverVersion
                    )
                }
            }

            Section {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isURLSectionExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(viewModel.server.currentURL.absoluteString)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)

                            Text("\(viewModel.prioritizedURLs.count) saved URLs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: isURLSectionExpanded ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if isURLSectionExpanded {
                    Button {
                        Task {
                            await viewModel.testAllURLs()
                        }
                    } label: {
                        HStack {
                            Label("Test All URLs", systemImage: "arrow.triangle.2.circlepath.circle")
                            Spacer()
                            if viewModel.isTestingAllURLs {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isTestingAllURLs || viewModel.isResolvingBestURL)

                    Button {
                        Task {
                            await viewModel.selectBestURL()
                        }
                    } label: {
                        HStack {
                            Label("Select Best Available URL", systemImage: "checkmark.circle")
                            Spacer()
                            if viewModel.isResolvingBestURL {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isTestingAllURLs || viewModel.isResolvingBestURL)

                    ForEach(viewModel.prioritizedURLs, id: \.self) { url in
                        serverURLRow(url)
                    }
                }
            } header: {
                Text(L10n.url)
            } footer: {
                if !viewModel.server.isVersionCompatible {
                    Label(
                        L10n.serverVersionWarning(JellyfinClient.sdkVersion.majorMinor.description),
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .labelStyle(.sectionFooterWithImage(imageStyle: .orange))
                }
            }

            if isEditing {
                ListRowButton(L10n.delete) {
                    isPresentingConfirmDeletion = true
                }
                .foregroundStyle(.red, .red.opacity(0.2))
            }
        }
        .navigationTitle(L10n.server)
        .navigationBarTitleDisplayMode(.inline)
        .alert(L10n.errorDetails, isPresented: Binding(
            get: { viewModel.testError != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.testError = nil
                }
            }
        )) {
            Button(L10n.ok) {
                viewModel.testError = nil
            }
        } message: {
            Text(viewModel.testError?.localizedDescription ?? L10n.unknownError)
        }
        .alert(L10n.deleteServer, isPresented: $isPresentingConfirmDeletion) {
            Button(L10n.delete, role: .destructive) {
                viewModel.delete()
                router.dismiss()
            }
        } message: {
            Text(L10n.confirmDeleteServerAndUsers(viewModel.server.name))
        }
    }

    @ViewBuilder
    private func serverURLRow(_ url: URL) -> some View {
        let state = viewModel.checkState(for: url)

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(url.absoluteString)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                Text(viewModel.statusText(for: url))
                    .font(.caption)
                    .foregroundStyle(statusColor(for: state))

                if let detail = state.detail, state.kind != .idle {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Button {
                    Task {
                        await viewModel.testURL(url)
                    }
                } label: {
                    Group {
                        if state.kind == .testing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath.circle")
                        }
                    }
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(state.kind == .testing || viewModel.isTestingAllURLs || viewModel.isResolvingBestURL)

                Button {
                    guard viewModel.server.currentURL != url else { return }
                    viewModel.setCurrentURL(to: url)
                } label: {
                    Image(systemName: viewModel.server.currentURL == url ? "checkmark.circle.fill" : "checkmark.circle")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func statusColor(for state: ServerConnectionViewModel.URLCheckState) -> Color {
        switch state.kind {
        case .idle:
            .secondary
        case .testing:
            .blue
        case .reachable:
            .green
        case .failed:
            .orange
        }
    }
}
