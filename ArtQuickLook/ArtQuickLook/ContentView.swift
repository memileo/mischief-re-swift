//
//  ContentView.swift
//  ArtQuickLook
//
//  Created by memileo on 2025-10-24.
//

import SwiftUI

// Mockup
// Settings should write to a plist file that is read by the quicklook plugin and thumbnail generator

struct ContentView: View {
    @State private var scale = 1.0
    @State private var isEditing = false
    @State private var cacheToggle = false
    @State private var forceCPUToggle = false
    @State private var thumbnailToggle = false
    @State private var cacheSize = 100
    
    func openSystemSettings() {
        return
    }
    
    let paddingA = 8.0
    
    var body: some View {
        // set minimum window/view width, default width
        VStack(alignment: .leading) {
            Text("Settings mockup:")
            
            HStack {
                Text("Preview image scale:")
                // CGFloat slider, 2 decimal increments.
                Slider(
                    value: $scale,
                    in: 0...4,
                    onEditingChanged: { editing in
                        isEditing = editing
                    }
                )
                Text("1.0")
            }
            HStack {
                Toggle(isOn: $forceCPUToggle) {
                    Text("Render on CPU (slow)")
                }
            }
            .padding(paddingA)
            HStack {
                Toggle(isOn: $cacheToggle) {
                    Text("Use cache")
                }
                Text("    ")
                Text("Cache size: 100MB ↕︎") // Numerical only text field + stepper. Size in MB. Greyed out if Use cache is false.
            }
            .padding(paddingA)
            HStack {
                Toggle(isOn: $thumbnailToggle) {
                    Text("Generate thumbnails")
                }
            }
            .padding(paddingA)
            HStack {
                Button(action: openSystemSettings) {
                    Label("Extension System Settings  ", systemImage: "gear")
                } // Open Extension System Settings with Quick Look tab selected.
                
            }
            .padding(paddingA)
        }
        .padding()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
