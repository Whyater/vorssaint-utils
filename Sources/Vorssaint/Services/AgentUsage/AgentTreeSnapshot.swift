// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Agent Tree, a separate app, follows which agents spawned which in a thread
/// and keeps a small summary of it in `~/.agent-tree/live.json` after every
/// scan. That file is all Vorssaint reads from it, and it never writes there.
/// The format belongs to Agent Tree, so a schema this reader does not know,
/// or a node it cannot read, is left out rather than guessed.
struct AgentTreeSnapshot: Decodable, Equatable {
    struct Node: Decodable, Equatable, Identifiable {
        let id: String
        let parentID: String?
        let depth: Int
        let label: String
        let model: String
        /// "anthropic", "openai" or another maker; empty when unknown.
        let family: String
        let status: String
        let running: Bool
        /// Tokens of the node and everything it spawned.
        let tokens: Int
        /// Estimated in US dollars; nil when no price is known.
        let cost: Double?

        enum CodingKeys: String, CodingKey {
            case id, depth, label, model, family, status, running, tokens, cost
            case parentID = "parent_id"
        }

        init(id: String, parentID: String? = nil, depth: Int = 0, label: String = "", model: String = "",
             family: String = "", status: String = "", running: Bool = false, tokens: Int = 0, cost: Double? = nil) {
            self.id = id
            self.parentID = parentID
            self.depth = depth
            self.label = label
            self.model = model
            self.family = family
            self.status = status
            self.running = running
            self.tokens = tokens
            self.cost = cost
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let id = try values.decode(String.self, forKey: .id)
            self.init(id: id,
                      parentID: (try? values.decodeIfPresent(String.self, forKey: .parentID)),
                      depth: min(AgentTreeLive.deepest, max(0, (try? values.decodeIfPresent(Int.self, forKey: .depth)) ?? 0)),
                      label: ((try? values.decodeIfPresent(String.self, forKey: .label)) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      model: (try? values.decodeIfPresent(String.self, forKey: .model)) ?? "",
                      family: (try? values.decodeIfPresent(String.self, forKey: .family)) ?? "",
                      status: (try? values.decodeIfPresent(String.self, forKey: .status)) ?? "",
                      running: (try? values.decodeIfPresent(Bool.self, forKey: .running)) ?? false,
                      tokens: AgentTreeLive.count((try? values.decodeIfPresent(Double.self, forKey: .tokens))),
                      cost: AgentTreeLive.money((try? values.decodeIfPresent(Double.self, forKey: .cost))))
        }

        var failed: Bool { ["error", "failed", "failure", "aborted", "cancelled", "canceled", "interrupted"].contains(status) }
    }

    struct Tree: Decodable, Equatable {
        let threadID: String
        let title: String
        /// Whether a thread is running now; otherwise this is the most recent one.
        let live: Bool
        let nodeCount: Int
        let maxDepth: Int
        let tokens: Int
        let cost: Double?
        /// Depth first, as Agent Tree lists them, and at most a few dozen.
        let nodes: [Node]

        enum CodingKeys: String, CodingKey {
            case title, live, tokens, cost, nodes
            case threadID = "thread_id"
            case nodeCount = "node_count"
            case maxDepth = "max_depth"
        }

        init(threadID: String = "", title: String = "", live: Bool = false, nodeCount: Int? = nil, maxDepth: Int? = nil,
             tokens: Int = 0, cost: Double? = nil, nodes: [Node]) {
            self.threadID = threadID
            self.title = title
            self.live = live
            self.nodes = nodes
            self.nodeCount = max(nodeCount ?? 0, nodes.count)
            self.maxDepth = max(maxDepth ?? 0, nodes.map(\.depth).max() ?? 0)
            self.tokens = tokens
            self.cost = cost
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // One node this reader cannot read leaves the others in place.
            let nodes = ((try? values.decodeIfPresent([Lossy<Node>].self, forKey: .nodes)) ?? [])
                .compactMap(\.value).prefix(AgentTreeLive.maximumNodes)
            self.init(threadID: (try? values.decodeIfPresent(String.self, forKey: .threadID)) ?? "",
                      title: (try? values.decodeIfPresent(String.self, forKey: .title)) ?? "",
                      live: (try? values.decodeIfPresent(Bool.self, forKey: .live)) ?? false,
                      nodeCount: AgentTreeLive.count((try? values.decodeIfPresent(Double.self, forKey: .nodeCount))),
                      maxDepth: min(AgentTreeLive.deepest,
                                    AgentTreeLive.count((try? values.decodeIfPresent(Double.self, forKey: .maxDepth)))),
                      tokens: AgentTreeLive.count((try? values.decodeIfPresent(Double.self, forKey: .tokens))),
                      cost: AgentTreeLive.money((try? values.decodeIfPresent(Double.self, forKey: .cost))),
                      nodes: Array(nodes))
        }

        /// Whether every node has a known price, so the costs are not a minimum.
        var fullyPriced: Bool { cost != nil && nodes.allSatisfy { $0.cost != nil } }
    }

    let schema: Int
    let generatedAt: Date
    let tree: Tree?

    enum CodingKeys: String, CodingKey {
        case schema, tree
        case generatedAt = "generated_at"
    }

    init(schema: Int = AgentTreeLive.schema, generatedAt: Date, tree: Tree?) {
        self.schema = schema
        self.generatedAt = generatedAt
        self.tree = tree
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try values.decode(Int.self, forKey: .schema)
        let text = try values.decode(String.self, forKey: .generatedAt)
        guard let date = AgentTimestamp.parse(text) else {
            throw DecodingError.dataCorruptedError(forKey: .generatedAt, in: values, debugDescription: "Unknown time")
        }
        self.init(schema: schema, generatedAt: date,
                  tree: (try? values.decodeIfPresent(Tree.self, forKey: .tree)))
    }

    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }
}

enum AgentTreeLive {
    static let bundleIdentifier = "io.github.whyater.agent-tree"
    static let schema = 1
    /// Agent Tree writes after every scan; a snapshot older than a day
    /// belongs to an app no longer running.
    static let freshness: TimeInterval = 86_400
    static let maximumSize = 1 << 20
    static let maximumNodes = 200
    static let deepest = 32

    static func url(home: URL) -> URL {
        home.appending(path: ".agent-tree/live.json", directoryHint: .notDirectory)
    }

    /// The file's snapshot; nil for a missing, oversized or unknown file.
    static func load(from url: URL) -> AgentTreeSnapshot? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maximumSize,
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> AgentTreeSnapshot? {
        guard data.count <= maximumSize,
              let snapshot = try? JSONDecoder().decode(AgentTreeSnapshot.self, from: data),
              snapshot.schema == schema else { return nil }
        return snapshot
    }

    /// The tree worth a card: from a recent snapshot, with at least one node.
    static func current(_ snapshot: AgentTreeSnapshot?, now: Date) -> AgentTreeSnapshot.Tree? {
        guard let snapshot, abs(now.timeIntervalSince(snapshot.generatedAt)) < freshness,
              let tree = snapshot.tree, !tree.nodes.isEmpty else { return nil }
        return tree
    }

    /// Up to `limit` nodes in their own order, and how many were left out.
    /// Working nodes come first, with every node above them so the branch
    /// still reads; the rest fill in under nodes already shown, from the
    /// latest while some work and from the top once all have finished.
    static func rows(_ nodes: [AgentTreeSnapshot.Node], limit: Int) -> (rows: [AgentTreeSnapshot.Node], hidden: Int) {
        guard nodes.count > limit else { return (nodes, 0) }
        guard limit > 0 else { return ([], nodes.count) }
        let index = Dictionary(nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: [Int] = []
        var chosen = Set<Int>()
        for (position, node) in nodes.enumerated() where node.running {
            // The branch from the top down, so a deep node never pushes out its parents.
            var branch = [position]
            var parent = node.parentID
            while let id = parent, let above = index[id], !branch.contains(above) {
                branch.append(above)
                parent = nodes[above].parentID
            }
            for position in branch.reversed() where kept.count < limit && chosen.insert(position).inserted {
                kept.append(position)
            }
        }
        let rest = nodes.indices.filter { !chosen.contains($0) }
        let order = kept.isEmpty ? rest : Array(rest.reversed())
        // Only under a node already shown, so no row hangs from nothing;
        // each pass can open the way for the children of the last.
        var grew = true
        while grew, kept.count < limit {
            grew = false
            for position in order where kept.count < limit && !chosen.contains(position) {
                let parent = nodes[position].parentID.flatMap { index[$0] }
                guard parent.map(chosen.contains) ?? true else { continue }
                chosen.insert(position)
                kept.append(position)
                grew = true
            }
        }
        return (kept.sorted().map { nodes[$0] }, nodes.count - kept.count)
    }

    /// The lines a row draws to join its node to the rest, from the depths
    /// of the rows shown: a column for each level above the node.
    struct Branch: Equatable {
        /// Columns the line of an earlier level crosses on its way down.
        var through: [Bool]
        /// Another node at the same level follows, so the elbow continues down.
        var more: Bool
        /// The next row hangs from this one.
        var children: Bool
    }

    static func branches(_ depths: [Int]) -> [Branch] {
        depths.indices.map { row in
            let depth = depths[row]
            // A column's line goes on while a later row returns to its level
            // before anything shallower.
            func continues(_ level: Int) -> Bool {
                depths[(row + 1)...].first { $0 <= level } == level
            }
            return Branch(through: (0..<max(0, depth - 1)).map { continues($0 + 1) },
                          more: depth > 0 && continues(depth),
                          children: row + 1 < depths.count && depths[row + 1] > depth)
        }
    }

    static func count(_ value: Double?) -> Int {
        guard let value, value.isFinite, value > 0 else { return 0 }
        return Int(min(value, Double(Int.max / 2)))
    }

    static func money(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
