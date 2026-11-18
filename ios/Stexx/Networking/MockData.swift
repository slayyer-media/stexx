import Foundation

/// Fictional sample content for the mock backend and SwiftUI previews.
/// All handles and text are made up; there are no photos, only placeholders.
enum MockData {
    static let myID: Profile.ID = "me"

    static let session = Session(
        userID: myID,
        accessToken: "mock-access-token",
        refreshToken: "mock-refresh-token",
        expiresAt: nil
    )

    static let me = Profile(
        id: myID,
        displayName: "you",
        age: nil,
        pronouns: nil,
        headline: "New here. Be nice.",
        about: nil,
        heightCm: nil,
        position: nil,
        lookingFor: [.chat, .dates],
        tags: ["Open source"],
        photos: [],
        distanceMeters: nil,
        isOnline: true,
        lastActiveAt: .now,
        isFavorite: false
    )

    static let profiles: [Profile] = [
        make("p01", "Eigenbro", 29, "Will explain Fourier transforms on the first date", 240, online: true,
             tags: ["Math", "Climbing", "Synths"], looking: [.dates, .chat], position: .versatile, pronouns: "he/him",
             height: 182, about: "Postdoc by day, modular synth gremlin by night. Looking for someone to get lost in a museum with."),
        make("p02", "NullPointer", 34, "Segfaulting my way into your heart", 510, online: true,
             tags: ["C++", "Coffee", "Cats"], looking: [.chat, .rightNow], position: .top, pronouns: "he/they", height: 176),
        make("p03", "ProtonPup", 24, "Particle physics & puppy energy", 820, online: false,
             tags: ["Physics", "Dogs", "Running"], looking: [.friends, .dates], position: .versBottom, pronouns: "he/him",
             height: 171, lastActive: 60 * 14),
        make("p04", "Kernel Panic", 41, "Linux wizard. Homelab bigger than my kitchen.", 1_300, online: true,
             tags: ["Linux", "Homelab", "Bears"], looking: [.chat, .relationship], position: .versTop, pronouns: nil, height: 188),
        make("p05", "Bayesian", 31, "Updating my priors about you", 1_700, online: false,
             tags: ["Stats", "Wine", "Board games"], looking: [.dates], position: .bottom, pronouns: "he/him",
             height: 179, lastActive: 60 * 60 * 3),
        make("p06", "Mitochondria", 27, "Powerhouse of the cell (and the dance floor)", 2_100, online: true,
             tags: ["Biology", "Techno", "Gym"], looking: [.rightNow, .chat], position: .versatile, pronouns: "he/him", height: 174),
        make("p07", "Astro Otter", 38, "Telescope at the cabin. Bring snacks.", 2_900, online: false,
             tags: ["Astronomy", "Hiking", "Otter"], looking: [.relationship, .friends], position: .top, pronouns: nil,
             height: 185, lastActive: 60 * 60 * 26),
        make("p08", "Lambda", 22, "Pure functions, impure thoughts", 3_400, online: true,
             tags: ["Haskell", "Anime", "Twink"], looking: [.chat, .dates], position: .bottom, pronouns: "he/they", height: 168),
        make("p09", "Rust Belt", 36, "Memory safe, emotionally unsafe", 4_100, online: true,
             tags: ["Rust", "Cycling", "Beard"], looking: [.dates, .networking], position: .versTop, pronouns: "he/him", height: 180),
        make("p10", "CRISPR Kid", 26, "Editing genes, not my personality", 4_800, online: false,
             tags: ["Genetics", "K-pop", "Swimming"], looking: [.friends, .chat], position: .versBottom, pronouns: "he/him",
             height: 173, lastActive: 60 * 45),
        make("p11", "Turing Complete", 45, "Can simulate any other daddy", 5_600, online: true,
             tags: ["CS", "Cooking", "Daddy"], looking: [.relationship, .rightNow], position: .top, pronouns: nil, height: 186),
        make("p12", "Quark Charm", 30, "Strange, but in a charming way", 6_200, online: false,
             tags: ["Physics", "Theatre", "Vinyl"], looking: [.dates], position: .side, pronouns: "they/them",
             height: 177, lastActive: 60 * 60 * 8),
        make("p13", "Pixel Shader", 28, "I make GPUs cry. Gently.", 7_000, online: true,
             tags: ["Graphics", "Gaming", "Otter"], looking: [.chat, .friends], position: .versatile, pronouns: "he/him", height: 181),
        make("p14", "Dr. Moss", 39, "Botanist. My plants are thriving, my DMs less so.", 8_300, online: false,
             tags: ["Botany", "Gardening", "Cats"], looking: [.relationship, .dates], position: .versBottom, pronouns: "he/him",
             height: 175, lastActive: 60 * 60 * 50),
        make("p15", "Big O", 33, "Constant time for the right person", 9_100, online: true,
             tags: ["Algorithms", "Lifting", "Jock"], looking: [.rightNow], position: .top, pronouns: nil, height: 190),
        make("p16", "Hyperparameter", 25, "Still tuning. Send gradients.", 11_400, online: false,
             tags: ["ML", "Climbing", "Coffee"], looking: [.dates, .chat], position: .versatile, pronouns: "he/they",
             height: 178, lastActive: 60 * 5),
        make("p17", "Tectonic", 47, "I move slowly but make an impact", 13_000, online: true,
             tags: ["Geology", "Camping", "Bear"], looking: [.chat, .relationship], position: .versTop, pronouns: "he/him", height: 184),
        make("p18", "Fermion", 23, "Can't share a state with anyone. Yet.", 15_800, online: false,
             tags: ["Physics", "Drag", "Dance"], looking: [.friends, .dates], position: .bottom, pronouns: "she/he",
             height: 170, lastActive: 60 * 60 * 2),
        make("p19", "Sudo Make Me", 35, "A sandwich. Or dinner?", 18_500, online: true,
             tags: ["DevOps", "Cooking", "Dogs"], looking: [.dates, .chat], position: .versatile, pronouns: nil, height: 183),
        make("p20", "Entropy", 29, "Increasing over time", 22_000, online: false,
             tags: ["Chemistry", "Raves", "Tattoos"], looking: [.rightNow, .chat], position: .versBottom, pronouns: "he/him",
             height: 176, lastActive: 60 * 60 * 30),
        make("p21", "Anonymous", nil, nil, nil, online: true,
             tags: ["Discreet"], looking: [.chat], position: nil, pronouns: nil, height: nil),
    ]

    /// Seed conversations: (participant, messages as (fromMe, text, minutesAgo)).
    static let seedThreads: [(Profile.ID, [(Bool, String, Double)])] = [
        ("p01", [
            (false, "Hey! Love the tags. What kind of synths?", 92),
            (true, "Mostly Eurorack. My wallet hates me.", 88),
            (false, "Haha same. Museum this weekend? The new physics exhibit looks fun.", 12),
            (false, "No pressure, I just want an excuse to explain interferometry", 11),
        ]),
        ("p04", [
            (true, "Ok your homelab photo is incredible", 60 * 5),
            (false, "Thank you, it's mostly Raspberry Pis held together with hope", 60 * 4.8),
        ]),
        ("p08", [
            (false, "hi :)", 60 * 26),
        ]),
        ("p13", [
            (true, "Which GPU though", 60 * 72),
            (false, "The one that's currently on fire", 60 * 71),
            (true, "Respect", 60 * 70),
        ]),
    ]

    private static func make(
        _ id: Profile.ID,
        _ name: String,
        _ age: Int?,
        _ headline: String?,
        _ distance: Double?,
        online: Bool,
        tags: [String],
        looking: [LookingFor],
        position: Position?,
        pronouns: String?,
        height: Int?,
        about: String? = nil,
        lastActive: TimeInterval = 0
    ) -> Profile {
        Profile(
            id: id,
            displayName: name,
            age: age,
            pronouns: pronouns,
            headline: headline,
            about: about ?? headline.map { "\($0). Ask me anything except my thesis timeline." },
            heightCm: height,
            position: position,
            lookingFor: looking,
            tags: tags,
            photos: [Photo(id: "\(id)-1", url: nil), Photo(id: "\(id)-2", url: nil)],
            distanceMeters: distance,
            isOnline: online,
            lastActiveAt: Date.now.addingTimeInterval(-lastActive),
            isFavorite: id == "p04" || id == "p09"
        )
    }
}
