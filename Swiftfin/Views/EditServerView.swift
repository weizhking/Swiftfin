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
                HStack(spacing: 12) {
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

                    Button {
                        Task {
                            await viewModel.testAllURLs()
                        }
                    } label: {
                        Group {
                            if viewModel.isTestingAllURLs {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath.circle")
                            }
                        }
                        .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isTestingAllURLs || viewModel.isResolvingBestURL)

                    Button {
                        Task {
                            await viewModel.sortURLsByBitrate()
                        }
                    } label: {
                        Image(systemName: "chart.bar")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isTestingAllURLs || viewModel.isResolvingBestURL)
                }

                if isURLSectionExpanded {
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
            Button {
                guard viewModel.server.currentURL != url else { return }
                viewModel.setCurrentURL(to: url)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(viewModel.server.currentURL == url ? Color.yellow : Color.clear)
                        .overlay {
                            Circle()
                                .stroke(
                                    viewModel.server.currentURL == url ? Color.yellow : Color.secondary.opacity(0.4),
                                    lineWidth: 1
                                )
                        }
                        .frame(width: 10, height: 10)
                        .padding(.top, 6)

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
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Button {
                    viewModel.moveURL(url, direction: .higherPriority)
                } label: {
                    Image(systemName: "arrow.up.circle")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(!viewModel.canMove(url, direction: .higherPriority))

                Button {
                    viewModel.moveURL(url, direction: .lowerPriority)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(!viewModel.canMove(url, direction: .lowerPriority))
            }
            .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                Task {
                    await viewModel.testURL(url)
                }
            } label: {
                Label("Test", systemImage: "arrow.triangle.2.circlepath.circle")
            }
            .tint(.blue)

            Button(role: .destructive) {
                viewModel.deleteURL(url)
            } label: {
                Label(L10n.delete, systemImage: "trash")
            }
            .disabled(!viewModel.canDeleteURL(url))
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
