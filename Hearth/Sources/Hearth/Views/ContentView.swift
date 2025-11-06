//
//  ContentView.swift
//  Hearth
//
//  Main view for the Hearth app
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "house.fill")
                .imageScale(.large)
                .foregroundStyle(.tint)
                .font(.system(size: 60))

            Text("🏠 Hearth")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top)

            Text("A thoughtful companion for nurturing meaningful relationships")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
