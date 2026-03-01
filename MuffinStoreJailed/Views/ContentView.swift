//
//  ContentView.swift
//  MuffinStoreJailed
//
//  Created by Mineek on 26/12/2024.
//

import SwiftUI
import PartyUI
import DeviceKit

struct ContentView: View {
    @State private var hasShownWelcome: Bool = false
    @State private var showLogs: Bool = true
    @State private var showSettingsView: Bool = false
    
    @EnvironmentObject var appData: AppData
    
    var body: some View {
        VStack {
            if UIDevice.current.userInterfaceIdiom == .pad {
                NavigationSplitView(sidebar: {
                    List {
                        if showLogs {
                            Section(header: HeaderLabel(text: "Terminal", icon: "terminal")) {
                                VStack(alignment: .leading) {
                                    TerminalView()
                                }
                                .padding()
                                .modifier(DynamicGlassEffect(shape: AnyShape(.rect(cornerRadius: platterCornerRadius())), useBackground: false))
                            }
                            .listRowSeparator(.hidden)
                            .listRowInsets(.dropdownRowInsets)
                        }
                        Section {
                            BottomBar()
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(.dropdownRowInsets)
                    }
                    .listStyle(.plain)
                    .navigationTitle("PancakeStore")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: {
                                Haptic.shared.play(.soft)
                                showLogs.toggle()
                            }) {
                                Image(systemName: "terminal")
                            }
                        }
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: {
                                showSettingsView.toggle()
                            }) {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
                    .modifier(SidebarToggleModifier())
                    .navigationSplitViewColumnWidth(385)
                }) {
                    List {
                        if !appData.isAuthenticated {
                            LoginView()
                        } else {
                            if appData.isDowngrading {
                                DowngradingView()
                            } else {
                                DowngradeAppView()
                            }
                        }
                    }
                }
            } else {
                NavigationStack {
                    List {
                        if showLogs {
                            VStack(alignment: .leading) {
                                TerminalView()
                            }
                        }
                        if !appData.isAuthenticated {
                            LoginView()
                        } else {
                            if appData.isDowngrading {
                                DowngradingView()
                            } else {
                                DowngradeAppView()
                            }
                        }
                    }
                    .navigationTitle("PancakeStore")
                    .safeAreaInset(edge: .bottom) {
                        BottomBar()
                            .modifier(OverlayBackground())
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: {
                                Haptic.shared.play(.soft)
                                showLogs.toggle()
                            }) {
                                Image(systemName: "terminal")
                            }
                        }
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: {
                                showSettingsView.toggle()
                            }) {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showSettingsView) {
            SettingsView()
        }
        .onAppear {
            if let authInfo = EncryptedKeychainWrapper.getAuthInfo() {
                appData.isAuthenticated = true
                print("Found auth info in keychain")
                appData.applicationStatus = "Ready to Downgrade!"
                appData.applicationIcon = "checkmark.circle.fill"
                appData.applicationIconColor = .primary

                guard let appleId = authInfo["appleId"] as? String,
                      let password = authInfo["password"] as? String else {
                    print("Auth info is invalid, logging out")
                    appData.isAuthenticated = false
                    EncryptedKeychainWrapper.nuke()
                    return
                }

                appData.appleId = appleId
                appData.password = password
                let ipaTool = IPATool(appleId: appData.appleId, password: appData.password)
                if ipaTool.ensureAuthState() {
                    appData.ipaTool = ipaTool
                } else {
                    appData.isAuthenticated = false
                    appData.applicationStatus = "Session expired. Please log in again."
                    appData.applicationIcon = "xmark.circle.fill"
                    appData.applicationIconColor = .red
                    appData.ipaTool = nil
                }
            } else {
                appData.isAuthenticated = false
                print("No auth info found in keychain")
            }
        }
    }
}

struct SidebarToggleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppData())
}
