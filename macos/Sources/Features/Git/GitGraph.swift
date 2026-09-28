import AppKit
import SwiftUI

/// Places commits on the lanes of the History page's graph.
///
/// Commits come children first, as `git log --topo-order` lists them. Each lane waits for one
/// commit: a commit takes the lane that waits for it (or a new one if nothing does, which makes it
/// a branch tip) and then makes the lane wait for its first parent. Its other parents get lanes of
/// their own. Two children of the same parent each keep their lane until the parent's row, so a
/// fork is drawn where it happened. A parent that isn't loaded yet keeps its lane open to the
/// bottom of the list.
enum GitGraph {
    /// A line through a row, on a lane, in a lane's color.
    struct Edge: Equatable {
        let lane: Int
        let color: Int
    }

    struct Row: Equatable {
        /// The commit's own lane and color.
        let lane: Int
        let color: Int

        /// Lanes that pass by the commit.
        let through: [Edge]

        /// Lanes that end at the commit, from its children above.
        let incoming: [Edge]

        /// Lanes that leave the commit for its parents below.
        let outgoing: [Edge]

        /// The number of lanes the row uses.
        let width: Int
    }

    static func layout(_ commits: [(hash: String, parents: [String])]) -> [Row] {
        var lanes: [String?] = []
        var laneColors: [Int] = []
        var nextColor = 0

        func allocate(_ hash: String) -> Int {
            let lane = lanes.firstIndex { $0 == nil } ?? {
                lanes.append(nil)
                laneColors.append(0)
                return lanes.count - 1
            }()
            lanes[lane] = hash
            laneColors[lane] = nextColor % ChromePalette.graphLanes.count
            nextColor += 1
            return lane
        }

        var rows: [Row] = []
        rows.reserveCapacity(commits.count)

        for commit in commits {
            let waiting = lanes.firstIndex { $0 == commit.hash }
            let lane = waiting ?? allocate(commit.hash)
            let color = laneColors[lane]

            var through: [Edge] = []
            var incoming: [Edge] = []
            for index in lanes.indices {
                guard let hash = lanes[index] else { continue }
                guard hash == commit.hash else {
                    through.append(.init(lane: index, color: laneColors[index]))
                    continue
                }

                // A branch tip has nothing coming in from above.
                if waiting != nil || index != lane {
                    incoming.append(.init(lane: index, color: laneColors[index]))
                }

                // Children on other lanes merge into this commit's lane here.
                if index != lane {
                    lanes[index] = nil
                }
            }

            var outgoing: [Edge] = []
            if let first = commit.parents.first {
                lanes[lane] = first
                outgoing.append(.init(lane: lane, color: color))
                for parent in commit.parents.dropFirst() {
                    let parentLane = lanes.firstIndex { $0 == parent } ?? allocate(parent)
                    outgoing.append(.init(lane: parentLane, color: laneColors[parentLane]))
                }
            } else {
                lanes[lane] = nil
            }

            while let last = lanes.last, last == nil {
                lanes.removeLast()
                laneColors.removeLast()
            }

            let width = ([lane] + (through + incoming + outgoing).map(\.lane)).max().map { $0 + 1 } ?? 1
            rows.append(.init(
                lane: lane,
                color: color,
                through: through,
                incoming: incoming,
                outgoing: outgoing,
                width: width))
        }
        return rows
    }
}

/// The graph cell at the start of a commit row.
struct GitGraphCell: View {
    static let laneWidth: CGFloat = 14

    /// Lanes past this are cut off so a wide history doesn't push the subjects away.
    static let maxLanes = 16

    let row: GitGraph.Row

    /// The number of lanes the whole visible history uses, so every row's cell is as wide.
    let lanes: Int

    /// Whether the commit is HEAD, drawn as a ring.
    var isHead: Bool = false

    /// Whether this is the uncommitted changes pseudo-commit, drawn dashed.
    var isWorktree: Bool = false

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2

            func x(_ lane: Int) -> CGFloat {
                CGFloat(lane) * Self.laneWidth + Self.laneWidth / 2
            }

            func stroke(_ path: Path, _ color: Int, dashed: Bool = false) {
                context.stroke(
                    path,
                    with: .color(Self.color(color)),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: dashed ? [3, 3] : []))
            }

            // A lane changing column bends halfway, like a subway map.
            func connect(from start: CGPoint, to end: CGPoint) -> Path {
                var path = Path()
                path.move(to: start)
                if start.x == end.x {
                    path.addLine(to: end)
                } else {
                    let control = (start.y + end.y) / 2
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x, y: control),
                        control2: CGPoint(x: end.x, y: control))
                }
                return path
            }

            for edge in row.through {
                stroke(connect(from: CGPoint(x: x(edge.lane), y: 0), to: CGPoint(x: x(edge.lane), y: size.height)), edge.color)
            }

            let node = CGPoint(x: x(row.lane), y: mid)
            for edge in row.incoming {
                stroke(connect(from: CGPoint(x: x(edge.lane), y: 0), to: node), edge.color)
            }
            for edge in row.outgoing {
                stroke(connect(from: node, to: CGPoint(x: x(edge.lane), y: size.height)), edge.color, dashed: isWorktree)
            }

            let radius: CGFloat = 4
            let dot = Path(ellipseIn: CGRect(x: node.x - radius, y: node.y - radius, width: radius * 2, height: radius * 2))
            if isWorktree {
                stroke(dot, row.color, dashed: true)
            } else if isHead {
                context.fill(dot, with: .color(Color(nsColor: ChromePalette.panel)))
                context.stroke(dot, with: .color(Self.color(row.color)), lineWidth: 2)
            } else {
                context.fill(dot, with: .color(Self.color(row.color)))
            }
        }
        .frame(width: CGFloat(min(max(lanes, 1), Self.maxLanes)) * Self.laneWidth)
        .clipped()
        .accessibilityHidden(true)
    }

    private static func color(_ index: Int) -> Color {
        let palette = ChromePalette.graphLanes
        return Color(nsColor: palette[index % palette.count])
    }
}
