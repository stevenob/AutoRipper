import Foundation

/// v4.0.15: known-disc maps for the BBC slipcover Bluey Season 1–3 Blu-rays
/// (released December 2024). Title ordering on each disc is shuffled and one
/// title per disc is a French-only duplicate of a real episode. The mapping
/// below produces correct SxxExx labels and skips the French dupes.
///
/// Source: MakeMKV forum thread by Sodas (Sept 2025) — manually verified
/// against the user's own Bluey rips. The `tNN` column in the forum is
/// MakeMKV's title id (matches the `_tNN.mkv` auto-named output filename).
///
/// Total: 154 episodes across 6 discs (S01E01–S01E52, S02E01–S02E52,
/// S03E01–S03E50) plus 5 French-only duplicate skips.
enum BlueyDiscMaps {
    static let all: [KnownDiscMap] = [
        season1FirstHalf,
        season1SecondHalf,
        season2FirstHalf,
        season2SecondHalf,
        season3FirstHalf,
        season3SecondHalf
    ]

    // MARK: - Disc 1 · Season 1 · First Half (26 eps + 1 French dup)

    static let season1FirstHalf = KnownDiscMap(
        id: "bluey-s1-first-half",
        discNameAliases: ["Bluey: Season One - The First Half"],
        displayName: "Bluey · Season 1 · First Half (BBC Slipcover)",
        showName: "Bluey",
        expectedTmdbId: 82728,
        titleMappings: [
            1:  .episode(1, 25, "Taxi"),
            2:  .episode(1, 24, "Wagon Ride"),
            3:  .episode(1, 23, "Shops"),
            4:  .episode(1, 22, "The Pool"),
            5:  .episode(1, 21, "Blue Mountains"),
            6:  .episode(1, 20, "Markets"),
            7:  .episode(1, 19, "The Claw"),
            8:  .episode(1, 17, "Calypso"),
            9:  .episode(1, 16, "Yoga Ball"),
            10: .episode(1, 15, "Butterflies"),
            11: .episode(1, 14, "Takeaway"),
            12: .episode(1, 13, "Spy Game"),
            13: .episode(1, 12, "Bob Bilby"),
            14: .episode(1, 11, "Bike"),
            15: .episode(1, 10, "Hotel"),
            16: .episode(1, 9,  "Horsey Ride"),
            17: .episode(1, 8,  "Fruitbat"),
            18: .episode(1, 7,  "BBQ"),
            19: .episode(1, 18, "The Doctor"),
            20: .episode(1, 6,  "The Weekend"),
            21: .episode(1, 5,  "Shadowlands"),
            22: .episode(1, 4,  "Daddy Robot"),
            23: .episode(1, 3,  "Keepy Uppy"),
            24: .episode(1, 2,  "Hospital"),
            25: .episode(1, 1,  "Magic Xylophone"),
            26: .skip("French-only duplicate of 'Markets' (S01E20)"),
            27: .episode(1, 26, "The Beach")
        ]
    )

    // MARK: - Disc 2 · Season 1 · Second Half (26 eps + 1 French dup)

    static let season1SecondHalf = KnownDiscMap(
        id: "bluey-s1-second-half",
        discNameAliases: ["Bluey: Season One - The Second Half"],
        displayName: "Bluey · Season 1 · Second Half (BBC Slipcover)",
        showName: "Bluey",
        expectedTmdbId: 82728,
        titleMappings: [
            1:  .episode(1, 51, "Daddy Putdown"),
            2:  .episode(1, 52, "Verandah Santa"),
            3:  .episode(1, 50, "Shaun"),
            4:  .episode(1, 49, "Asparagus"),
            5:  .episode(1, 48, "Teasing"),
            6:  .episode(1, 47, "Neighbours"),
            7:  .episode(1, 46, "Chickenrat"),
            8:  .episode(1, 45, "Kids"),
            9:  .episode(1, 43, "Camping"),
            10: .episode(1, 42, "Hide and Seek"),
            11: .episode(1, 41, "Mums and Dads"),
            12: .episode(1, 40, "Early Baby"),
            13: .episode(1, 39, "The Sleepover"),
            14: .episode(1, 38, "Copycat"),
            15: .episode(1, 37, "The Adventure"),
            16: .episode(1, 36, "Backpackers"),
            17: .episode(1, 35, "Zoo"),
            18: .episode(1, 34, "The Dump"),
            19: .episode(1, 33, "Trampoline"),
            20: .episode(1, 44, "Mount Mumandad"),
            21: .episode(1, 32, "Bumpy and the Wise Old Wolfhound"),
            22: .episode(1, 31, "Work"),
            23: .episode(1, 30, "Fairies"),
            24: .episode(1, 29, "The Creek"),
            25: .episode(1, 28, "Grannies"),
            26: .episode(1, 27, "Pirates"),
            27: .skip("French-only duplicate of 'Daddy Putdown' (S01E51)")
        ]
    )

    // MARK: - Disc 3 · Season 2 · First Half (25 eps, no French dup)

    static let season2FirstHalf = KnownDiscMap(
        id: "bluey-s2-first-half",
        discNameAliases: ["Bluey: Season Two - The First Half"],
        displayName: "Bluey · Season 2 · First Half (BBC Slipcover)",
        showName: "Bluey",
        expectedTmdbId: 82728,
        titleMappings: [
            1:  .episode(2, 25, "Helicopter"),
            2:  .episode(2, 24, "Flat Pack"),
            3:  .episode(2, 23, "Queens"),
            4:  .episode(2, 22, "Bus"),
            5:  .episode(2, 21, "Escape"),
            6:  .episode(2, 20, "Tickle Crabs"),
            7:  .episode(2, 19, "The Show"),
            8:  .episode(2, 17, "Fancy Restaurant"),
            9:  .episode(2, 16, "Army"),
            10: .episode(2, 15, "Trains"),
            11: .episode(2, 14, "Mum School"),
            12: .episode(2, 13, "Dad Baby"),
            13: .episode(2, 12, "Sticky Gecko"),
            14: .episode(2, 11, "Charades"),
            15: .episode(2, 10, "Rug Island"),
            16: .episode(2, 9,  "Bingo"),
            17: .episode(2, 8,  "Daddy Dropoff"),
            18: .episode(2, 7,  "Favourite Thing"),
            19: .episode(2, 18, "Piggyback"),
            20: .episode(2, 6,  "Stumpfest"),
            21: .episode(2, 5,  "Hairdressers"),
            22: .episode(2, 4,  "Squash"),
            23: .episode(2, 3,  "Featherwand"),
            24: .episode(2, 2,  "Hammerbarn"),
            25: .episode(2, 1,  "Dance Mode")
        ]
    )

    // MARK: - Disc 4 · Season 2 · Second Half (27 eps, no French dup listed in source)

    static let season2SecondHalf = KnownDiscMap(
        id: "bluey-s2-second-half",
        discNameAliases: ["Bluey: Season Two - The Second Half"],
        displayName: "Bluey · Season 2 · Second Half (BBC Slipcover)",
        showName: "Bluey",
        expectedTmdbId: 82728,
        titleMappings: [
            // No t01 entry on this disc — title ids run 2..28
            2:  .episode(2, 27, "Grandad"),
            3:  .episode(2, 50, "Baby Race"),
            4:  .episode(2, 49, "Typewriter"),
            5:  .episode(2, 48, "Dunny"),
            6:  .episode(2, 47, "Ice Cream"),
            7:  .episode(2, 46, "Road Trip"),
            8:  .episode(2, 45, "Handstand"),
            9:  .episode(2, 43, "Muffin Cone"),
            10: .episode(2, 42, "Bin Night"),
            11: .episode(2, 41, "Octopus"),
            12: .episode(2, 40, "Bad Mood"),
            13: .episode(2, 39, "Double Babysitter"),
            14: .episode(2, 38, "Mr Monkeyjocks"),
            15: .episode(2, 37, "The Quiet Game"),
            16: .episode(2, 36, "Postman"),
            17: .episode(2, 35, "Café"),
            18: .episode(2, 34, "Swim School"),
            19: .episode(2, 33, "Circus"),
            20: .episode(2, 44, "Duck Cake"),
            21: .episode(2, 32, "Burger Shop"),
            22: .episode(2, 31, "Barky Boats"),
            23: .episode(2, 30, "Library"),
            24: .episode(2, 29, "Movies"),
            25: .episode(2, 28, "Seesaw"),
            26: .episode(2, 51, "Christmas Swim"),
            27: .episode(2, 26, "Sleepytime"),
            28: .episode(2, 52, "Easter")
        ]
    )

    // MARK: - Disc 5 · Season 3 · First Half (26 eps + 1 French dup)

    static let season3FirstHalf = KnownDiscMap(
        id: "bluey-s3-first-half",
        discNameAliases: ["Bluey: Season Three - The First Half"],
        displayName: "Bluey · Season 3 · First Half (BBC Slipcover)",
        showName: "Bluey",
        expectedTmdbId: 82728,
        titleMappings: [
            1:  .episode(3, 25, "Ragdoll"),
            2:  .episode(3, 24, "Faceytalk"),
            3:  .episode(3, 23, "Family Meeting"),
            4:  .episode(3, 22, "Whale Watching"),
            5:  .episode(3, 21, "Tina"),
            6:  .episode(3, 20, "Driving"),
            7:  .episode(3, 19, "Pizza Girls"),
            8:  .episode(3, 17, "Pavlova"),
            9:  .episode(3, 16, "Phones"),
            10: .episode(3, 15, "Explorers"),
            11: .episode(3, 1,  "Perfect"),
            12: .episode(3, 14, "Pass the Parcel"),
            13: .episode(3, 13, "Housework"),
            14: .episode(3, 12, "Sheepdog"),
            15: .episode(3, 11, "Chest"),
            16: .episode(3, 10, "Magic"),
            17: .episode(3, 9,  "Curry Quest"),
            18: .episode(3, 8,  "Unicorse"),
            19: .episode(3, 18, "Rain"),
            20: .episode(3, 7,  "Mini Bluey"),
            21: .episode(3, 6,  "Born Yesterday"),
            22: .episode(3, 5,  "Omelette"),
            23: .episode(3, 4,  "Promises"),
            24: .episode(3, 3,  "Obstacle Course"),
            25: .episode(3, 2,  "Bedroom"),
            26: .skip("French-only duplicate of 'Mini Bluey' (S03E07)"),
            27: .episode(3, 26, "Fairytale")
        ]
    )

    // MARK: - Disc 6 · Season 3 · Second Half (24 eps + 1 French dup)

    static let season3SecondHalf = KnownDiscMap(
        id: "bluey-s3-second-half",
        discNameAliases: ["Bluey: Season Three - The Second Half"],
        displayName: "Bluey · Season 3 · Second Half (BBC Slipcover)",
        showName: "Bluey",
        expectedTmdbId: 82728,
        titleMappings: [
            3:  .episode(3, 49, "The Sign"),
            4:  .episode(3, 50, "Surprise"),
            5:  .episode(3, 48, "Ghostbasket"),
            6:  .episode(3, 47, "Cricket"),
            7:  .episode(3, 46, "Slide"),
            8:  .episode(3, 45, "TV Shop"),
            9:  .episode(3, 43, "Dragon"),
            10: .episode(3, 42, "Show and Tell"),
            11: .episode(3, 41, "Stickbird"),
            12: .episode(3, 40, "Relax"),
            13: .episode(3, 39, "Exercise"),
            14: .episode(3, 38, "Cubby"),
            15: .episode(3, 37, "The Decider"),
            16: .episode(3, 36, "Dirt"),
            17: .episode(3, 35, "Smoochy Kiss"),
            18: .episode(3, 34, "Space"),
            19: .episode(3, 33, "Granny Mobile"),
            20: .episode(3, 44, "Wild Girls"),
            21: .episode(3, 32, "Tradies"),
            22: .episode(3, 31, "Onesies"),
            23: .episode(3, 30, "Turtleboy"),
            24: .episode(3, 29, "Puppets"),
            25: .episode(3, 28, "Stories"),
            26: .episode(3, 27, "Musical Statues"),
            27: .skip("French-only duplicate of 'Exercise' (S03E39)")
        ]
    )
}
