import Foundation

struct IdentifiableURL: Identifiable {
    var id: String { url.absoluteString }
    let url: URL
}

