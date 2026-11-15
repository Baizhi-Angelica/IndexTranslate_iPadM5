//
//  ITXApp.swift
//  ITXTranslate
//
//  App 入口。界面固定浅色（白底大字），不做深色模式适配。
//

import SwiftUI

@main
struct ITXTranslateApp: App {

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.light)
        }
    }
}
