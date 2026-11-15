// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// Greedy decoding of an RNN transducer (spec 7), the way GigaAM's reference
/// does it: for every frame of the encoder ask the model for the likeliest
/// token given the last one; a blank moves on to the next frame, anything else
/// is taken and asked about again, at most `maxSymbolsPerFrame` times.
public struct TransducerGreedyDecoder: Sendable {
    public var blank: Int
    public var maxSymbolsPerFrame: Int

    public init(blank: Int, maxSymbolsPerFrame: Int = 10) {
        self.blank = blank
        self.maxSymbolsPerFrame = maxSymbolsPerFrame
    }

    /// - Parameters:
    ///   - frames: number of encoder frames.
    ///   - start: the state of the prediction network before the first token.
    ///   - step: for a frame, the last token and the state gives the likeliest
    ///     token and the state after it. The state is kept only if the token is taken.
    public func decode<State>(
        frames: Int,
        start: State,
        step: (_ frame: Int, _ lastToken: Int, _ state: State) throws -> (token: Int, state: State)
    ) rethrows -> [Int] {
        var tokens: [Int] = []
        var state = start
        var last = blank
        for frame in 0..<max(frames, 0) {
            for _ in 0..<maxSymbolsPerFrame {
                let next = try step(frame, last, state)
                if next.token == blank { break }
                tokens.append(next.token)
                state = next.state
                last = next.token
            }
        }
        return tokens
    }

    /// Index of the largest value; the first one if several are equal.
    public static func argmax(_ values: [Float]) -> Int {
        var best = 0
        for index in values.indices where values[index] > values[best] {
            best = index
        }
        return best
    }
}

/// Turns SentencePiece pieces back into text: "▁" opens a word.
public enum PieceText {
    public static func join(_ tokens: [Int], pieces: [String]) -> String {
        tokens.filter { pieces.indices.contains($0) }
            .map { pieces[$0] }
            .joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Cuts long speech into windows the model can take (30 s for GigaAM), at the
/// quietest moment it can find near the end of each window, so that a word is
/// not cut in half (spec 7).
public struct SpeechChunker: Sendable {
    /// Longest window, in samples.
    public var maxLength: Int
    /// How far back from the end of a window a quiet moment is looked for.
    public var searchLength: Int
    /// Loudness is measured over stretches of this many samples.
    public var stride: Int

    public init(maxLength: Int = 30 * 16000, searchLength: Int = 8 * 16000, stride: Int = 320) {
        self.maxLength = maxLength
        self.searchLength = searchLength
        self.stride = stride
    }

    public func split(_ samples: [Float]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxLength {
            let limit = start + maxLength
            var cut = limit
            var quietest = Float.greatestFiniteMagnitude
            var position = max(limit - searchLength, start + stride)
            while position + stride <= limit {
                var energy: Float = 0
                for index in position..<(position + stride) {
                    energy += samples[index] * samples[index]
                }
                // Later is better when it is equally quiet: the window is used more fully.
                if energy <= quietest {
                    quietest = energy
                    cut = position + stride / 2
                }
                position += stride
            }
            ranges.append(start..<cut)
            start = cut
        }
        if start < samples.count {
            ranges.append(start..<samples.count)
        }
        return ranges
    }
}
