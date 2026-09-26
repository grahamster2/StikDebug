//
//  PlacesSheet.swift
//  Wander
//

import SwiftUI

struct PlacesSheet: View {
    @ObservedObject var store: PlaceStore
    let onSelect: (Place) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Favourites") {
                    if store.favourites.isEmpty {
                        Text("Tap the star on any location to save it here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.favourites) { place in
                        row(place, icon: "star.fill", tint: .yellow)
                    }
                    .onDelete(perform: store.removeFavourites)
                }

                Section {
                    if store.recents.isEmpty {
                        Text("Places you jump or walk to show up here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.recents) { place in
                        row(place, icon: "clock", tint: .secondary)
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        if !store.recents.isEmpty {
                            Button("Clear", action: store.clearRecents)
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ place: Place, icon: String, tint: some ShapeStyle) -> some View {
        Button {
            onSelect(place)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(place.point.formatted)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
