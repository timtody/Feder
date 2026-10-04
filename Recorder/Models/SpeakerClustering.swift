import Foundation

/// The detail menu's "Speakers: n" for Nemotron, which has no speaker-count setting: its turns are regrouped by voice,
/// only as far as the count asks. Each turn is cut into equal pieces of at most 10 s (one embedding-model input,
/// embedded inside its real surrounding audio by VoiceEmbedder.embeddings); each found speaker starts as one cluster of
/// its pieces of at least 1 s (all its pieces when it has none):
/// - n == the speakers Nemotron found: the turns stay as they are;
/// - n below: whole speakers are merged by duration-weighted average-linkage AHC on cosine similarity;
/// - n above: the speaker whose 2-means split gains the most is split in two, until n (two voices under one label).
/// The remaining pieces join the nearest cluster that came from their own speaker, and each turn takes the cluster
/// holding most of its duration. Measured on DiarBench with the true n: 1.68 % wrong words and the right count in 72/72
/// (36 meetings of 2-4 people, clean + room) and 1.51 % / 8/8 on 9-10 minute meetings of 7-8 people. Clustering all
/// pieces from scratch instead (the diarization study's design) gave 1.76 % but scrambled 4 of the 8 long recordings
/// (10.6 %). With the two most alike speakers merged and n asking for one more: 2.2 % (long 2.2 %; from scratch 1.9 % /
/// 8.9 %; merged 28 % / 16 %). Pure.
nonisolated enum SpeakerClustering {
    static let pieceSeconds: TimeInterval = 10      // the embedding model's input
    static let minClusterSeconds: TimeInterval = 1  // shorter pieces don't shape the clusters, they only join one

    nonisolated struct Piece: Hashable, Sendable {
        var turn: Int                               // index into the turns it was cut from
        var span: VoiceWindows.Span
        var duration: TimeInterval { span.end - span.start }
    }

    /// Every turn cut into equal pieces of at most `pieceSeconds`, in turn order.
    static func pieces(of turns: [SpeakerTurn]) -> [Piece] {
        turns.enumerated().flatMap { index, turn in
            let count = Int((turn.end - turn.start) / pieceSeconds) + 1
            let length = (turn.end - turn.start) / Double(count)
            return (0..<count).map { i in
                Piece(turn: index, span: VoiceWindows.Span(start: turn.start + length * Double(i),
                                                           end: turn.start + length * Double(i + 1)))
            }
        }
    }

    /// `turns` regrouped into `clusters` speakers (see the type comment), numbered by first appearance.
    /// `embeddings[i]` is the unit embedding of `pieces[i]`.
    static func regroup(_ turns: [SpeakerTurn], pieces: [Piece], embeddings: [[Float]], clusters k: Int) -> [SpeakerTurn] {
        precondition(pieces.count == embeddings.count)
        let found = Set(turns.map(\.speakerIndex)).count
        guard k >= 1, !pieces.isEmpty, k != found else { return turns }
        // Every speaker takes part with its pieces of at least minClusterSeconds, or with all its pieces when it has none.
        let speaker = pieces.map { turns[$0.turn].speakerIndex }
        let long = pieces.indices.filter { pieces[$0].duration >= minClusterSeconds }
        let covered = Set(long.map { speaker[$0] })
        let members = long + pieces.indices.filter { !covered.contains(speaker[$0]) }
        let vectors = members.map { embeddings[$0] }, weights = members.map { pieces[$0].duration }
        let label = k < found
            ? averageLinkage(vectors, weights: weights, clusters: k, initial: members.map { speaker[$0] })
            : split(vectors, weights: weights, initial: members.map { speaker[$0] }, clusters: k)
        // The other pieces join the nearest cluster that came from their own speaker; each turn takes the cluster
        // holding most of its duration.
        var cluster = [Int](repeating: 0, count: pieces.count)
        var origins: [Int: Set<Int>] = [:]              // speaker -> its clusters
        for (j, i) in members.enumerated() {
            cluster[i] = label[j]
            origins[speaker[i], default: []].insert(label[j])
        }
        let centroids = centroids(vectors, weights: weights, labels: label)
        let memberSet = Set(members)
        for i in pieces.indices where !memberSet.contains(i) {
            let own = (origins[speaker[i]] ?? []).sorted()
            cluster[i] = own.count == 1 ? own[0] : own.max { VoiceMatch.similarity(embeddings[i], centroids[$0])
                                                             < VoiceMatch.similarity(embeddings[i], centroids[$1]) } ?? 0
        }
        var votes = [[Int: Double]](repeating: [:], count: turns.count)
        for (i, piece) in pieces.enumerated() { votes[piece.turn][cluster[i], default: 0] += piece.duration }
        var number: [Int: Int] = [:]
        return zip(turns, votes).map { turn, vote in
            let c = vote.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? 0
            let index = number[c] ?? { let n = number.count; number[c] = n; return n }()
            return SpeakerTurn(speakerIndex: index, start: turn.start, end: turn.end)
        }
    }

    /// Divisive: starting from the groups of `initial`, the cluster whose 2-means split gains the most is split in two,
    /// until `k` clusters (or nothing can be split). The gain is how much more the members agree with their own half's
    /// mean than with the whole cluster's: ‖S_A‖ + ‖S_B‖ - ‖S_A + S_B‖ for the weighted sums S of the halves, large for
    /// two voices under one label, small for the spread of one voice. Labels are numbered by each cluster's first member.
    static func split(_ v: [[Float]], weights w: [Double], initial: [Int], clusters k: Int) -> [Int] {
        var label = initial
        var count = Set(initial).count
        while count < k {
            var best: (gain: Float, groups: [Int], members: [Int])?
            for c in Set(label).sorted() {
                let members = label.indices.filter { label[$0] == c }
                guard members.count >= 2 else { continue }
                let (groups, _) = twoMeans(members.map { v[$0] }, members.map { Float(w[$0]) })
                guard groups.contains(0), groups.contains(1) else { continue }
                var halves = [[Float]](repeating: [Float](repeating: 0, count: v[members[0]].count), count: 2)
                for (j, i) in members.enumerated() { for d in v[i].indices { halves[groups[j]][d] += Float(w[i]) * v[i][d] } }
                let whole = zip(halves[0], halves[1]).map { $0 + $1 }
                let gain = norm(halves[0]) + norm(halves[1]) - norm(whole)
                if best == nil || gain > best!.gain { best = (gain, groups, members) }
            }
            guard let best else { break }
            let fresh = (label.max() ?? 0) + 1
            for (j, i) in best.members.enumerated() where best.groups[j] == 1 { label[i] = fresh }
            count += 1
        }
        var number: [Int: Int] = [:]
        return label.map { l in number[l] ?? { let n = number.count; number[l] = n; return n }() }
    }

    /// 2-means on cosine similarity (unit vectors, weighted means), seeded with the two least similar vectors, 10
    /// rounds: the group of each vector (0/1) and the similarity of the two group means.
    static func twoMeans(_ e: [[Float]], _ w: [Float]) -> (groups: [Int], similarity: Float) {
        let n = e.count
        guard n >= 2 else { return (Array(repeating: 0, count: n), 1) }
        var (si, sj, lowest) = (0, 0, Float.infinity)
        for i in 0..<n { for j in 0..<n { let s = dot(e[i], e[j]); if s < lowest { (si, sj, lowest) = (i, j, s) } } }
        var c = [e[si], e[sj]]
        func groups() -> [Int] { e.map { dot($0, c[1]) > dot($0, c[0]) ? 1 : 0 } }
        for _ in 0..<10 {
            let a = groups()
            for g in 0..<2 where a.contains(g) {
                var m = [Float](repeating: 0, count: e[0].count)
                for k in 0..<n where a[k] == g { for d in m.indices { m[d] += w[k] * e[k][d] } }
                c[g] = VoiceMatch.unit(m)
            }
        }
        return (groups(), dot(c[0], c[1]))
    }

    /// Duration-weighted average linkage on cosine similarity (unit vectors): merges the two clusters with the highest
    /// weighted mean pairwise similarity until `k` remain. Clusters start as single members, or as the groups of
    /// `initial` (one label per member). The pairwise sums are kept per cluster pair and added up on a merge, so a merge
    /// costs O(clusters). Labels are numbered by each cluster's first member.
    static func averageLinkage(_ v: [[Float]], weights w: [Double], clusters k: Int, initial: [Int]? = nil) -> [Int] {
        let n = v.count
        guard n > 0 else { return [] }
        var members: [[Int]] = []                       // per starting cluster, in order of first member
        var start: [Int: Int] = [:]
        for i in 0..<n {
            let key = initial?[i] ?? i
            if let c = start[key] { members[c].append(i) } else { start[key] = members.count; members.append([i]) }
        }
        let g = members.count
        // sum[a * g + b]: Σ similarity(i, j) · w_i · w_j over the members i of cluster a and j of cluster b.
        var sum = [Double](repeating: 0, count: g * g)
        for a in 0..<g {
            for b in a..<g {
                var s = 0.0
                for i in members[a] { for j in members[b] { s += Double(dot(v[i], v[j])) * w[i] * w[j] } }
                sum[a * g + b] = s
                sum[b * g + a] = s
            }
        }
        var weight = members.map { $0.reduce(0) { $0 + w[$1] } }   // Σ w_i per cluster
        var active = Array(0..<g)                       // ordered by first member; a merge keeps the earlier cluster
        while active.count > max(1, k) {
            var best = (link: -Double.infinity, x: 0, y: 1)
            for x in 0..<active.count {
                for y in (x + 1)..<active.count {
                    let a = active[x], b = active[y]
                    let link = weight[a] * weight[b] > 0 ? sum[a * g + b] / (weight[a] * weight[b]) : -1
                    if link > best.link { best = (link, x, y) }
                }
            }
            let a = active[best.x], b = active[best.y]
            for c in active where c != a && c != b {
                sum[a * g + c] += sum[b * g + c]
                sum[c * g + a] = sum[a * g + c]
            }
            weight[a] += weight[b]
            members[a] += members[b]
            active.remove(at: best.y)
        }
        var label = [Int](repeating: 0, count: n)
        for (cluster, id) in active.enumerated() { for i in members[id] { label[i] = cluster } }
        return label
    }

    static func centroids(_ v: [[Float]], weights: [Double], labels: [Int]) -> [[Float]] {
        let k = (labels.max() ?? -1) + 1
        var sums = [[Float]](repeating: [Float](repeating: 0, count: v.first?.count ?? 0), count: k)
        for (i, l) in labels.enumerated() { for d in 0..<v[i].count { sums[l][d] += Float(weights[i]) * v[i][d] } }
        return sums.map(VoiceMatch.unit)
    }

    static func nearest(_ x: [Float], _ centroids: [[Float]]) -> Int {
        var best = 0, bestScore = -Float.infinity
        for (c, m) in centroids.enumerated() {
            let s = dot(x, m)
            if s > bestScore { best = c; bestScore = s }
        }
        return best
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
    private static func norm(_ a: [Float]) -> Float { dot(a, a).squareRoot() }
}
