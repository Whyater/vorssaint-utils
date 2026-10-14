// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Agent Tree's snapshot: only the schema it knows, only while recent, and a
/// short tree that keeps working agents and the branch above them.
enum AgentTreeLiveTests {
    static func run(_ suite: TestSuite) {
        decoding(suite)
        freshness(suite)
        truncation(suite)
        branches(suite)
        cards(suite)
    }

    private static func node(_ id: String, parent: String? = nil, depth: Int, running: Bool = false) -> String {
        let parentText = parent.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(id)","parent_id":\(parentText),"depth":\(depth),"label":" \(id) ","model":"claude-opus-5-5",\
        "family":"anthropic","status":"\(running ? "running" : "done")","running":\(running),\
        "tokens":1200,"cost":0.5}
        """
    }

    private static func file(schema: Int = 1, generated: String = "2026-10-13T17:44:34.000Z", nodes: [String]) -> Data {
        Data("""
        {"schema":\(schema),"generated_at":"\(generated)","totals":{},"flags":{},"running":[],\
        "tree":{"thread_id":"t1","title":"Build","project_name":"app","live":true,"node_count":40,\
        "max_depth":2,"tokens":5000,"cost":null,"nodes":[\(nodes.joined(separator: ","))]}}
        """.utf8)
    }

    private static func decoding(_ suite: TestSuite) {
        let snapshot = AgentTreeLive.decode(file(nodes: [node("root", depth: 0), node("child", parent: "root", depth: 1)]))
        let tree = snapshot?.tree
        suite.expect(tree?.nodes.map(\.id) == ["root", "child"] && tree?.nodes[1].parentID == "root"
                        && tree?.nodes[0].label == "root" && tree?.nodeCount == 40 && tree?.live == true
                        && tree?.cost == nil && tree?.fullyPriced == false,
                     "a snapshot reads its tree in Agent Tree's order, with an unknown cost left unknown")
        suite.expect(AgentTreeLive.decode(file(schema: 2, nodes: [node("root", depth: 0)])) == nil,
                     "a schema this reader does not know is left out")
        suite.expect(AgentTreeLive.decode(Data("not json".utf8)) == nil
                        && AgentTreeLive.decode(file(generated: "yesterday", nodes: [])) == nil,
                     "an unreadable file or time is left out")
        let odd = AgentTreeLive.decode(file(nodes: [node("root", depth: 0), "{\"label\":\"no id\"}", "7",
                                                    #"{"id":"deep","parent_id":"root","depth":-3,"tokens":-5,"cost":-1,"surprise":[1]}"#]))
        suite.expect(odd?.tree?.nodes.map(\.id) == ["root", "deep"] && odd?.tree?.nodes[1].depth == 0
                        && odd?.tree?.nodes[1].tokens == 0 && odd?.tree?.nodes[1].cost == nil,
                     "a node it cannot read is skipped and odd numbers are kept in range")
        var large = file(nodes: [node("root", depth: 0)])
        large.append(Data(repeating: 0x20, count: AgentTreeLive.maximumSize))
        suite.expect(AgentTreeLive.decode(large) == nil, "a file over the size limit is not decoded")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "vorss-agent-tree-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = AgentTreeLive.url(home: directory)
        suite.expect(AgentTreeLive.load(from: url) == nil, "a missing file reads as no snapshot")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? file(nodes: [node("root", depth: 0)]).write(to: url)
        suite.expect(AgentTreeLive.load(from: url)?.tree?.nodes.count == 1
                        && url.path.hasSuffix("/.agent-tree/live.json"),
                     "the snapshot is read from Agent Tree's folder")
    }

    private static func freshness(_ suite: TestSuite) {
        let generated = Date(timeIntervalSince1970: 1_800_000_000)
        let tree = AgentTreeSnapshot.Tree(nodes: [AgentTreeSnapshot.Node(id: "root")])
        let snapshot = AgentTreeSnapshot(generatedAt: generated, tree: tree)
        suite.expect(AgentTreeLive.current(snapshot, now: generated.addingTimeInterval(3600)) == tree
                        && AgentTreeLive.current(snapshot, now: generated.addingTimeInterval(86_400)) == nil,
                     "a snapshot a day old no longer shows a card")
        suite.expect(AgentTreeLive.current(AgentTreeSnapshot(generatedAt: generated, tree: nil), now: generated) == nil
                        && AgentTreeLive.current(AgentTreeSnapshot(generatedAt: generated, tree: .init(nodes: [])),
                                                 now: generated) == nil,
                     "a snapshot without agents shows no card")
        let live = AgentTreeSnapshot.Tree(live: true, nodes: [AgentTreeSnapshot.Node(id: "root", running: true)])
        let working = AgentTreeSnapshot(generatedAt: generated, tree: live)
        suite.expect(AgentTreeLive.current(working, now: generated.addingTimeInterval(60)) == live,
                     "a fresh snapshot keeps its working agents")
        let stale = AgentTreeLive.current(working, now: generated.addingTimeInterval(600 + AgentTreeLive.liveFreshness))
        suite.expect(stale?.live == false && stale?.nodes.contains(where: \.running) == false,
                     "a snapshot too old to vouch for work shows its tree as finished")
        suite.expect(AgentTreeLive.current(working, now: generated.addingTimeInterval(-7200)) != nil,
                     "a clock a little behind the file still shows the card")
    }

    private static func truncation(_ suite: TestSuite) {
        typealias Node = AgentTreeSnapshot.Node
        let nodes = [Node(id: "root", depth: 0), Node(id: "a", parentID: "root", depth: 1),
                     Node(id: "a1", parentID: "a", depth: 2), Node(id: "a2", parentID: "a", depth: 2),
                     Node(id: "b", parentID: "root", depth: 1), Node(id: "b1", parentID: "b", depth: 2),
                     Node(id: "b1x", parentID: "b1", depth: 3, running: true), Node(id: "c", parentID: "root", depth: 1)]
        let short = AgentTreeLive.rows(Array(nodes.prefix(3)), limit: 5)
        suite.expect(short.rows.map(\.id) == ["root", "a", "a1"] && short.hidden == 0, "a tree that fits is shown whole")
        let working = AgentTreeLive.rows(nodes, limit: 5)
        suite.expect(working.rows.map(\.id) == ["root", "b", "b1", "b1x", "c"] && working.hidden == 3,
                     "a working agent keeps the branch above it, and the latest nodes fill the rest")
        suite.expect(AgentTreeLive.rows(nodes, limit: 6).rows.map(\.id) == ["root", "a", "b", "b1", "b1x", "c"],
                     "a node fills in only under one already shown, never hanging from a hidden parent")
        let tight = AgentTreeLive.rows(nodes, limit: 2)
        suite.expect(tight.rows.map(\.id) == ["root", "b"] && tight.hidden == 6,
                     "a branch longer than the room keeps its top")
        let finished = nodes.map { Node(id: $0.id, parentID: $0.parentID, depth: $0.depth) }
        suite.expect(AgentTreeLive.rows(finished, limit: 4).rows.map(\.id) == ["root", "a", "a1", "a2"],
                     "once all have finished the tree is shown from the top")
        suite.expect(AgentTreeLive.rows(nodes, limit: 0).rows.isEmpty, "no room shows no rows")
    }

    private static func branches(_ suite: TestSuite) {
        // root, a, a1, a2, b, b1
        let lines = AgentTreeLive.branches([0, 1, 2, 2, 1, 2])
        suite.expect(lines[0] == .init(through: [], more: false, children: true)
                        && lines[1] == .init(through: [], more: true, children: true)
                        && lines[2] == .init(through: [true], more: true, children: false)
                        && lines[3] == .init(through: [true], more: false, children: false)
                        && lines[4] == .init(through: [], more: false, children: true)
                        && lines[5] == .init(through: [false], more: false, children: false),
                     "each row joins its parent and carries on the lines of later siblings")
    }

    private static func cards(_ suite: TestSuite) {
        let tree = NotchAgentTile(card: .agentTree, provider: nil)
        let spend = NotchAgentTile(card: .spend, provider: nil)
        suite.expect(NotchAgentSupport.tiles(cards: [.agentTree, .spend], providers: [.claude]) == [spend]
                        && NotchAgentSupport.tiles(cards: [.agentTree, .spend], providers: [.claude], agentTree: true)
                        == [tree, spend],
                     "the tree card shows only while Agent Tree keeps a recent snapshot")
        suite.expect(NotchAgentSupport.tiles(cards: [.agentTree, .spend], providers: [], agentTree: true) == [tree]
                        && NotchAgentSupport.tiles(cards: [.agentTree, .spend], providers: []).isEmpty,
                     "with no agent logs the tree card still shows, and nothing else does")
        suite.expect(NotchAgentSupport.rows([spend, tree], width: 424) == [[spend], [tree]]
                        && NotchAgentSupport.contentHeight([[tree]]) == NotchAgentSupport.treeHeight,
                     "the tree takes the whole row and its own height")
        suite.expect(NotchAgentCard.allCases.firstIndex(of: .agentTree) == NotchAgentCard.allCases.firstIndex(of: .live).map { $0 + 1 },
                     "by default the tree follows the card about work in progress")
    }
}
