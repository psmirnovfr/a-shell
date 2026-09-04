//
//  AgentView.swift
//  a-Shell — Agentic layer
//
//  The root 3-panel workspace used when agent mode is enabled:
//
//    ┌────────────┬──────────────────────────┐
//    │            │        Terminal          │
//    │   Chat     ├──────────────────────────┤
//    │            │    Browser / Preview     │
//    └────────────┴──────────────────────────┘
//
//  The terminal pane reuses the existing `Webview` (hterm) so all of
//  SceneDelegate's message-handler / output wiring keeps working unchanged.
//

import SwiftUI

struct AgentView: View {
    /// The existing hterm terminal webview (created by SceneDelegate).
    let terminal: Webview
    /// SceneDelegate, used for command execution. Unowned to avoid a retain cycle.
    unowned let host: AgentHost

    @StateObject private var vm = AgentViewModel()
    @StateObject private var browser = BrowserModel()

    /// Fraction of total width given to the chat pane.
    @State private var chatFraction: CGFloat = 0.34
    /// Fraction of the right column's height given to the terminal.
    @State private var terminalFraction: CGFloat = 0.55

    private let handleThickness: CGFloat = 8
    private let minChatFraction: CGFloat = 0.2
    private let maxChatFraction: CGFloat = 0.55

    var body: some View {
        GeometryReader { geo in
            let chatWidth = geo.size.width * chatFraction
            HStack(spacing: 0) {
                ChatPanel(vm: vm)
                    .frame(width: chatWidth)

                verticalHandle(totalWidth: geo.size.width)

                rightColumn(height: geo.size.height)
            }
        }
        .onAppear {
            vm.host = host
            vm.previewHandler = { url in browser.loadLocal(url) }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    // Right column: terminal over browser, with a horizontal drag handle.
    private func rightColumn(height: CGFloat) -> some View {
        let terminalHeight = height * terminalFraction
        return VStack(spacing: 0) {
            terminal
                .frame(height: terminalHeight)
            horizontalHandle(totalHeight: height)
            BrowserPanel(model: browser)
        }
    }

    private func verticalHandle(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.gray.opacity(0.001))
            .overlay(Divider())
            .frame(width: handleThickness)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let delta = value.translation.width / totalWidth
                        chatFraction = min(maxChatFraction,
                                           max(minChatFraction, chatFraction + delta / 40))
                    }
            )
    }

    private func horizontalHandle(totalHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color.gray.opacity(0.001))
            .overlay(Divider())
            .frame(height: handleThickness)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let delta = value.translation.height / totalHeight
                        terminalFraction = min(0.85, max(0.15, terminalFraction + delta / 40))
                    }
            )
    }
}
