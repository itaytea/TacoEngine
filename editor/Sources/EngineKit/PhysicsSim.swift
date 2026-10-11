import Foundation

/// Mirrors the engine's vertical jump code (game/src/player.c) so the editor's graphs show
/// the real arc, and solves designer-friendly targets ("this high, this fast") back into parameters.
public enum PhysicsSim {
    public struct Arc {
        public var heights: [Double]   // px above the floor, one per frame (index 0 = takeoff)
        public var apexTime: Double    // frames, interpolated
        public var apexHeight: Double  // px
        public var landTime: Double    // frames, interpolated
        public var fallTime: Double { landTime - apexTime }
    }

    /// Simulate a jump from flat ground. holdFrames: how long jump is held (nil = until landing).
    public static func arc(_ p: PlatformerSettings, holdFrames: Int? = nil, canCut: Bool = true) -> Arc {
        var vy = -p.jumpVelocity
        var y = 0.0
        var cuttable = canCut
        var sustain = p.jumpSustainFrames
        var heights: [Double] = [0]
        var land = 0.0
        for frame in 0..<600 {
            let held = holdFrames.map { frame < $0 } ?? true
            if cuttable && vy < 0 && !held { vy *= p.jumpCut; cuttable = false }
            if vy >= 0 { cuttable = false }
            var g = p.gravity
            if held && abs(vy) < p.apexThreshold { g *= p.apexGravity }
            else if vy > 0 { g *= p.fallGravity }
            vy = vy + g
            if sustain > 0 {       // Celeste-style: full jump speed while held
                if held { vy = -p.jumpVelocity; sustain -= 1 } else { sustain = 0 }
            }
            vy = min(vy, p.maxFall)
            let prev = y
            y += vy
            if y >= 0 {
                // crossed the floor during this frame
                let frac = prev < 0 ? -prev / (y - prev) : 1
                land = Double(frame) + frac
                heights.append(0)
                break
            }
            heights.append(-y)
        }
        if land == 0 { land = Double(heights.count - 1) }
        // Apex with parabolic interpolation around the highest sample
        let k = heights.indices.max { heights[$0] < heights[$1] } ?? 0
        var t = Double(k), h = heights[k]
        if k > 0 && k + 1 < heights.count {
            let a = heights[k - 1], b = heights[k], c = heights[k + 1]
            let denom = a - 2 * b + c
            if denom < 0 {
                let off = 0.5 * (a - c) / denom
                t += off
                h = b - 0.25 * (a - c) * off
            }
        }
        return Arc(heights: heights, apexTime: t, apexHeight: h, landTime: land)
    }

    /// Adjust jump velocity and gravity so the held jump peaks at `height` px after `time` frames.
    public static func solveApex(_ p: PlatformerSettings, time: Double, height: Double) -> PlatformerSettings {
        var q = p
        let t = max(4, time), h = max(4, height)
        // Closed form ignoring apex hang, then refine against the real simulation
        q.gravity = 2 * h / (t * t)
        q.jumpVelocity = 2 * h / t
        for _ in 0..<12 {
            let a = arc(q)
            guard a.apexHeight > 0.1, a.apexTime > 0.1 else { break }
            let rh = h / a.apexHeight, rt = t / a.apexTime
            q.jumpVelocity *= rh / rt
            q.gravity *= rh / (rt * rt)
            q.jumpVelocity = min(max(q.jumpVelocity, 0.5), 14)
            q.gravity = min(max(q.gravity, 0.01), 2)
        }
        return q
    }

    /// Adjust fall gravity so the fall from the apex back to the floor takes `time` frames.
    public static func solveFall(_ p: PlatformerSettings, time: Double) -> PlatformerSettings {
        var q = p
        let target = max(2, time)
        for _ in 0..<12 {
            let f = arc(q).fallTime
            guard f > 0.1 else { break }
            q.fallGravity *= (f / target) * (f / target)
            q.fallGravity = min(max(q.fallGravity, 0.25), 6)
        }
        return q
    }

    /// Frames to reach top speed from standing (ground)
    public static func accelFrames(_ p: PlatformerSettings) -> Double { p.runSpeed / max(p.groundAccel, 0.0001) }
    public static func decelFrames(_ p: PlatformerSettings) -> Double { p.runSpeed / max(p.groundDecel, 0.0001) }

    /// Horizontal distance (px) of a full held jump at top speed
    public static func jumpDistance(_ p: PlatformerSettings) -> Double { arc(p).landTime * p.runSpeed }
}
