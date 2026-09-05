//
//  RootView.swift
//  xDrip Watch App
//
//  Created by Paul Plant on 21/7/24.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject var watchState: WatchStateModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var libreDirectCollector: LibreWatchDirectCollector

    // save the last selected tab on the Watch so re-opening the app returns to the same page
    @AppStorage("watchAppSelectedPage") private var selectedPage = WatchAppPage.main.rawValue

    // keep both main pages on the same chart range so swiping between them only changes whether
    // the AGP background is visible. The chart content should not jump between pages.
    @State private var hoursToShowIndex = ConstantsAppleWatch.hoursToShowDefaultIndex
    
    var body: some View {
        TabView(selection: $selectedPage) {
            // normal main page
            MainView(hoursToShowIndex: $hoursToShowIndex)
                .tag(WatchAppPage.main.rawValue)

            // same main page layout, but with the AGP background enabled in the chart
            MainView(showsAGPBackground: true, hoursToShowIndex: $hoursToShowIndex)
                .tag(WatchAppPage.agp.rawValue)

            // large number page
            BigNumberView(libreDirectCollector: libreDirectCollector)
                .tag(WatchAppPage.bigNumber.rawValue)

            // Explicit persistent hand-off between iPhone and direct Watch reception.
            LibreDirectView(collector: libreDirectCollector)
                .tag(WatchAppPage.libreDirect.rawValue)
        }
        .modifier(RootViewTabViewStyleModifier())
        .environmentObject(watchState)
        .onAppear {
            if watchState.libreWatchOwnership == .watch {
                selectedPage = WatchAppPage.bigNumber.rawValue
            } else if WatchAppPage(rawValue: selectedPage) == nil {
                // if a saved tab value from an older build is invalid, fall back to the normal main page
                selectedPage = WatchAppPage.main.rawValue
            }
            libreDirectCollector.applicationActivityDidChange(scenePhase.libreWatchApplicationState)
        }
        .onChange(of: scenePhase) { newPhase in
            libreDirectCollector.applicationActivityDidChange(newPhase.libreWatchApplicationState)
            if newPhase == .active { watchState.refreshLocalAlarmPermission() }
            if newPhase == .active, watchState.libreWatchOwnership == .watch {
                selectedPage = WatchAppPage.bigNumber.rawValue
            }
        }
        .onChange(of: watchState.libreWatchOwnership) { ownership in
            if ownership == .watch {
                selectedPage = WatchAppPage.bigNumber.rawValue
            }
        }
    }
}

private extension ScenePhase {
    var libreWatchApplicationState: LibreWatchApplicationState {
        switch self {
        case .active: return .active
        case .inactive: return .inactive
        case .background: return .background
        @unknown default: return .background
        }
    }
}

private enum WatchAppPage: Int {
    case main = 0
    case agp = 1
    case bigNumber = 2
    case libreDirect = 3
}

#if os(watchOS)
struct RootViewTabViewStyleModifier: ViewModifier {
    
    func body(content: Content) -> some View {
        content.tabViewStyle(.carousel)
    }
}
#else
struct RootViewTabViewStyleModifier: ViewModifier {
    
    func body(content: Content) -> some View {
        content.tabViewStyle(.page)
    }
}
#endif

#Preview {
    RootView(libreDirectCollector: LibreWatchDirectCollector())
        .environmentObject(WatchStateModel())
}
