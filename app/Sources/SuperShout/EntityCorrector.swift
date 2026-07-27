import Foundation

/// Domain-knowledge correction for near-miss entities the recognizer almost
/// got right: "2019 Genesis G7" → "2019 Genesis G70" (Genesis makes no G7),
/// "Mazda CX 5" → "Mazda CX-5", "Ford F150" → "Ford F-150".
///
/// When a known brand appears, the next token(s) are checked against that
/// brand's valid models. A near-miss is snapped only when it matches exactly
/// one model (exact, unique prefix, or one edit away) — ambiguity never guesses.
enum EntityCorrector {

    private struct Brand {
        let canonical: String
        let aliases: [String]
        let models: [String]

        init(_ canonical: String, aliases: [String] = [], models: [String]) {
            self.canonical = canonical
            self.aliases = aliases
            self.models = models
        }
    }

    private static let brands: [Brand] = [
        Brand("Genesis", models: ["G70", "G80", "G90", "GV60", "GV70", "GV80"]),
        Brand("BMW", models: ["M2", "M3", "M4", "M5", "M8", "X1", "X2", "X3", "X4", "X5", "X6", "X7", "Z4",
                              "i3", "i4", "i5", "i7", "i8", "iX",
                              "228i", "230i", "328i", "330i", "335i", "340i", "428i", "430i", "435i", "440i",
                              "528i", "530i", "535i", "540i", "550i", "740i", "750i", "760i"]),
        Brand("Audi", models: ["A3", "A4", "A5", "A6", "A7", "A8", "Q3", "Q4", "Q5", "Q7", "Q8",
                               "S3", "S4", "S5", "S6", "S7", "S8", "RS3", "RS5", "RS6", "RS7", "SQ5", "TT", "R8", "e-tron"]),
        Brand("Mercedes-Benz", aliases: ["mercedes", "benz"],
              models: ["A-Class", "C-Class", "E-Class", "S-Class", "G-Class", "CLA", "CLS", "GLA", "GLB", "GLC",
                       "GLE", "GLS", "SL", "SLK", "SLC", "AMG GT", "C300", "C43", "C63", "E350", "E450", "E63",
                       "S500", "S580", "G550", "G63", "GL450", "ML350", "EQS", "EQE", "EQB"]),
        Brand("Lexus", models: ["IS", "ES", "GS", "LS", "NX", "RX", "GX", "LX", "RC", "LC", "UX", "CT", "RZ",
                                "IS250", "IS300", "IS350", "ES300h", "ES330", "ES350", "RX330", "RX350", "RX450h",
                                "GX460", "GX470", "GX550", "LX570", "LX600", "NX300", "UX250h", "TX350"]),
        Brand("Infiniti", models: ["Q50", "Q60", "Q70", "QX30", "QX50", "QX55", "QX60", "QX80",
                                   "G35", "G37", "FX35", "FX45", "M35", "M37"]),
        Brand("Acura", models: ["TLX", "ILX", "MDX", "RDX", "ZDX", "NSX", "TSX", "TL", "RL", "RSX", "Integra"]),
        Brand("Mazda", models: ["CX-3", "CX-30", "CX-5", "CX-50", "CX-7", "CX-9", "CX-70", "CX-90",
                                "MX-5", "MX-30", "RX-7", "RX-8", "Mazda3", "Mazda6", "Miata"]),
        Brand("Tesla", models: ["Model S", "Model 3", "Model X", "Model Y", "Cybertruck", "Roadster"]),
        Brand("Hyundai", models: ["Elantra", "Sonata", "Tucson", "Santa Fe", "Palisade", "Kona", "Venue",
                                  "Accent", "Veloster", "Ioniq 5", "Ioniq 6", "Santa Cruz"]),
        Brand("Kia", models: ["Forte", "K4", "K5", "Optima", "Stinger", "Sportage", "Sorento", "Telluride",
                              "Soul", "Seltos", "Niro", "Carnival", "EV6", "EV9", "Rio"]),
        Brand("Honda", models: ["Civic", "Accord", "CR-V", "HR-V", "Pilot", "Passport", "Odyssey", "Ridgeline",
                                "Fit", "Element", "Prologue", "S2000"]),
        Brand("Toyota", models: ["Camry", "Corolla", "RAV4", "Highlander", "4Runner", "Tacoma", "Tundra",
                                 "Sienna", "Sequoia", "Prius", "Avalon", "Venza", "Supra", "GR86", "Land Cruiser",
                                 "C-HR", "bZ4X", "Crown"]),
        Brand("Ford", models: ["F-150", "F-250", "F-350", "F-450", "Mustang", "Explorer", "Expedition", "Escape",
                               "Edge", "Bronco", "Ranger", "Maverick", "Fusion", "Focus", "Fiesta", "Taurus",
                               "Transit", "E-350", "Mach-E"]),
        Brand("Chevrolet", aliases: ["chevy"],
              models: ["Silverado", "Colorado", "Tahoe", "Suburban", "Traverse", "Equinox", "Trailblazer",
                       "Blazer", "Malibu", "Impala", "Camaro", "Corvette", "Bolt", "Trax", "Express"]),
        Brand("Nissan", models: ["Altima", "Maxima", "Sentra", "Versa", "Rogue", "Murano", "Pathfinder",
                                 "Armada", "Frontier", "Titan", "Kicks", "Leaf", "Ariya", "Z", "370Z", "350Z", "GT-R"]),
        Brand("Subaru", models: ["Outback", "Forester", "Crosstrek", "Impreza", "Legacy", "Ascent", "WRX", "BRZ", "Solterra"]),
        Brand("Volkswagen", aliases: ["vw"],
              models: ["Jetta", "Passat", "Golf", "GTI", "Tiguan", "Atlas", "Taos", "Arteon", "Beetle", "ID.4", "ID.Buzz"]),
        Brand("Volvo", models: ["S60", "S90", "V60", "V90", "XC40", "XC60", "XC90", "C40", "EX30", "EX90"]),
        Brand("Porsche", models: ["911", "718", "Cayman", "Boxster", "Cayenne", "Macan", "Panamera", "Taycan"]),
        Brand("Jaguar", models: ["XE", "XF", "XJ", "F-Type", "F-Pace", "E-Pace", "I-Pace"]),
        Brand("Land Rover", aliases: ["range rover"],
              models: ["Defender", "Discovery", "Evoque", "Velar", "Sport", "Autobiography"]),
        Brand("Jeep", models: ["Wrangler", "Grand Cherokee", "Cherokee", "Compass", "Renegade", "Gladiator", "Wagoneer"]),
        Brand("Ram", models: ["1500", "2500", "3500", "ProMaster"]),
        Brand("GMC", models: ["Sierra", "Yukon", "Acadia", "Terrain", "Canyon", "Savana", "Hummer EV"]),
        Brand("Cadillac", models: ["CT4", "CT5", "CT6", "XT4", "XT5", "XT6", "Escalade", "Lyriq", "ATS", "CTS", "XTS", "SRX"]),
        Brand("Lincoln", models: ["Navigator", "Aviator", "Corsair", "Nautilus", "Continental", "MKZ", "MKC", "MKX"]),
        Brand("Dodge", models: ["Charger", "Challenger", "Durango", "Hornet", "Journey", "Grand Caravan"]),
        Brand("Mitsubishi", models: ["Outlander", "Eclipse Cross", "Mirage", "Lancer", "Evolution"]),
        Brand("Buick", models: ["Enclave", "Encore", "Envision", "Envista", "LaCrosse", "Regal"]),
        Brand("Chrysler", models: ["300", "Pacifica", "Voyager", "Town and Country"]),
        Brand("Mini", models: ["Cooper", "Countryman", "Clubman", "Paceman"]),
        Brand("Alfa Romeo", models: ["Giulia", "Stelvio", "Tonale", "4C"]),
        Brand("Rivian", models: ["R1T", "R1S", "R2", "R3"]),
        Brand("Lucid", models: ["Air", "Gravity"]),
        Brand("Polestar", models: ["1", "2", "3", "4"]),
    ]

    /// alias (lowercased) → brand index. Multi-word aliases are matched on
    /// their first word, then confirmed against the following token(s).
    private static let aliasIndex: [String: Int] = {
        var idx: [String: Int] = [:]
        for (i, b) in brands.enumerated() {
            idx[b.canonical.lowercased()] = i
            // First word of multi-word canonical names ("Land Rover" → "land")
            if let first = b.canonical.split(separator: " ").first, first.lowercased() != b.canonical.lowercased() {
                idx[String(first).lowercased()] = idx[String(first).lowercased()] ?? i
            }
            for a in b.aliases { idx[a.split(separator: " ").first.map(String.init)?.lowercased() ?? a.lowercased()] = i }
        }
        return idx
    }()

    static func correct(_ text: String) -> String {
        guard text.contains(" ") else { return text }
        var words = text.components(separatedBy: " ")
        var i = 0
        while i < words.count {
            let core = strip(words[i])
            if let bIdx = aliasIndex[core.lowercased()] {
                let brand = brands[bIdx]
                let (next, matched) = correctModel(after: i, brand: brand, words: &words)
                // Canonicalize brand casing ("genesis g70" → "Genesis G70") only
                // when a model confirmed this really is the brand — "ram the
                // door" must not become "Ram the door".
                if matched, !brand.canonical.contains(" "),
                   core.lowercased() == brand.canonical.lowercased(), core != brand.canonical {
                    words[i] = rewrap(words[i], core: brand.canonical)
                }
                i = next
            } else {
                i += 1
            }
        }
        return words.joined(separator: " ")
    }

    /// Examines up to 3 tokens after the brand (skipping 4-digit years and the
    /// tail of multi-word brand names) and snaps the first model-like token.
    /// Returns the index to resume brand scanning from and whether a model
    /// was confirmed or corrected.
    private static func correctModel(after brandIdx: Int, brand: Brand, words: inout [String]) -> (Int, Bool) {
        let normalizedModels: [(norm: String, canonical: String)] = brand.models.map { (norm($0), $0) }
        var j = brandIdx + 1
        var examined = 0

        while j < words.count && examined < 3 {
            let core = strip(words[j])
            if core.isEmpty { j += 1; continue }
            // Skip years ("2019 Genesis G7" / "Genesis 2019 G7") and brand-name tails ("Land Rover", "Mercedes Benz").
            if core.range(of: #"^\d{4}$"#, options: .regularExpression) != nil
                || brand.canonical.lowercased().contains(core.lowercased())
                || brand.aliases.contains(where: { $0.contains(core.lowercased()) }) {
                j += 1; examined += 1; continue
            }

            // Try joining with the next token first: "CX 5" → CX-5, "Model 3" → Model 3, "G 70" → G70.
            if j + 1 < words.count {
                let nextCore = strip(words[j + 1])
                let joined = norm(core + nextCore)
                if !nextCore.isEmpty, let match = uniqueMatch(joined, in: normalizedModels, exactOnly: true) {
                    words[j] = rewrap(words[j], core: match, trailingFrom: words[j + 1])
                    words.remove(at: j + 1)
                    return (j + 1, true)
                }
            }

            let coreNorm = norm(core)
            if let exact = normalizedModels.first(where: { $0.norm == coreNorm }) {
                if core != exact.canonical { words[j] = rewrap(words[j], core: exact.canonical) }
                return (j + 1, true)
            }
            if isModelLike(core), let match = uniqueMatch(coreNorm, in: normalizedModels, exactOnly: false) {
                words[j] = rewrap(words[j], core: match)
                return (j + 1, true)
            }
            // First non-year token wasn't a model — stop looking for this brand.
            return (j + 1, false)
        }
        return (brandIdx + 1, false)
    }

    /// Exact match, else (when allowed) unique prefix-completion or unique
    /// single-edit match. Returns the canonical model or nil.
    private static func uniqueMatch(_ candidate: String, in models: [(norm: String, canonical: String)], exactOnly: Bool) -> String? {
        if let exact = models.first(where: { $0.norm == candidate }) { return exact.canonical }
        guard !exactOnly, candidate.count >= 2 else { return nil }

        let prefixMatches = models.filter { $0.norm.hasPrefix(candidate) }
        if prefixMatches.count == 1 { return prefixMatches[0].canonical }
        if prefixMatches.count > 1 { return nil }

        let editMatches = models.filter { levenshtein(candidate, $0.norm) == 1 }
        return editMatches.count == 1 ? editMatches[0].canonical : nil
    }

    /// Model designations look like G70, CX5, F150, RS7 — not ordinary words.
    private static func isModelLike(_ s: String) -> Bool {
        if s.contains(where: \.isNumber) { return true }
        if s.count >= 2 && s.count <= 4 && s == s.uppercased() && s.contains(where: \.isLetter) { return true }
        return false
    }

    private static func norm(_ s: String) -> String {
        s.uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
    }

    /// Alphanumeric core of a token, without surrounding punctuation.
    private static func strip(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// Replaces a token's core while keeping its surrounding punctuation
    /// ("G7," → "G70,"). `trailingFrom` borrows trailing punctuation from a
    /// second token that is being merged away.
    private static func rewrap(_ token: String, core: String, trailingFrom: String? = nil) -> String {
        let scalars = CharacterSet.alphanumerics
        let leading = String(token.prefix(while: { !$0.unicodeScalars.allSatisfy(scalars.contains) }))
        let source = trailingFrom ?? token
        let trailing = String(source.reversed().prefix(while: { !$0.unicodeScalars.allSatisfy(scalars.contains) }).reversed())
        return leading + core + trailing
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        if abs(a.count - b.count) > 1 { return 2 }  // early out; we only care about distance ≤ 1
        let aa = Array(a), bb = Array(b)
        var prev = Array(0...bb.count)
        for i in 1...max(aa.count, 1) where !aa.isEmpty {
            var cur = [i] + Array(repeating: 0, count: bb.count)
            for j in 1...max(bb.count, 1) where !bb.isEmpty {
                cur[j] = aa[i - 1] == bb[j - 1]
                    ? prev[j - 1]
                    : min(prev[j - 1], prev[j], cur[j - 1]) + 1
            }
            prev = cur
        }
        return prev[bb.count]
    }
}
