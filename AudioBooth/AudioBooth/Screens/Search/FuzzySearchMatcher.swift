import Foundation

struct FuzzySearchMatcher {
  static func matches<Value>(
    query: String,
    candidates: [Value],
    limit: Int = 5,
    name: (Value) -> String
  ) -> [Value] {
    let queryVariants = variants(for: query)
    guard queryVariants.contains(where: { $0.count >= 3 }) else { return [] }

    return
      candidates
      .compactMap { candidate -> RankedMatch<Value>? in
        let candidateName = name(candidate)
        let candidateVariants = variants(for: candidateName)
        guard let score = bestScore(queryVariants: queryVariants, candidateVariants: candidateVariants) else {
          return nil
        }
        return RankedMatch(value: candidate, name: candidateName, score: score)
      }
      .sorted {
        if $0.score != $1.score { return $0.score < $1.score }
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      .prefix(limit)
      .map(\.value)
  }
}

private extension FuzzySearchMatcher {
  struct Score: Comparable, Equatable {
    let normalizedDistance: Double
    let distance: Int

    static func < (lhs: Score, rhs: Score) -> Bool {
      if lhs.normalizedDistance != rhs.normalizedDistance {
        return lhs.normalizedDistance < rhs.normalizedDistance
      }
      return lhs.distance < rhs.distance
    }
  }

  struct RankedMatch<Value> {
    let value: Value
    let name: String
    let score: Score
  }

  static func variants(for value: String) -> [String] {
    let folded = value.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: .current
    )
    let words =
      folded
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    guard !words.isEmpty else { return [] }

    var values = [words.joined(separator: " "), words.joined()]
    if words.count > 1 {
      values.append(contentsOf: words)
    }
    return Array(Set(values))
  }

  static func bestScore(queryVariants: [String], candidateVariants: [String]) -> Score? {
    var best: Score?

    for query in queryVariants where query.count >= 3 {
      for candidate in candidateVariants {
        if query == candidate {
          return Score(normalizedDistance: 0, distance: 0)
        }

        let distance = damerauLevenshteinDistance(query, candidate)
        let comparisonLength = max(query.count, candidate.count)
        guard distance <= allowedDistance(for: comparisonLength) else { continue }

        let normalizedDistance = Double(distance) / Double(comparisonLength)
        guard normalizedDistance <= 0.34 else { continue }

        let score = Score(normalizedDistance: normalizedDistance, distance: distance)
        if best == nil || score < best! {
          best = score
        }
      }
    }

    return best
  }

  static func allowedDistance(for length: Int) -> Int {
    switch length {
    case ...4: 1
    case 5...8: 2
    default: min(4, max(2, length / 4))
    }
  }

  static func damerauLevenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
    let source = Array(lhs)
    let target = Array(rhs)
    guard !source.isEmpty else { return target.count }
    guard !target.isEmpty else { return source.count }

    var previousPrevious = Array(0...target.count)
    var previous = previousPrevious

    for sourceIndex in source.indices {
      var current = Array(repeating: 0, count: target.count + 1)
      current[0] = sourceIndex + 1

      for targetIndex in target.indices {
        let substitutionCost = source[sourceIndex] == target[targetIndex] ? 0 : 1
        current[targetIndex + 1] = min(
          current[targetIndex] + 1,
          previous[targetIndex + 1] + 1,
          previous[targetIndex] + substitutionCost
        )

        if sourceIndex > 0, targetIndex > 0,
          source[sourceIndex] == target[targetIndex - 1],
          source[sourceIndex - 1] == target[targetIndex]
        {
          current[targetIndex + 1] = min(
            current[targetIndex + 1],
            previousPrevious[targetIndex - 1] + 1
          )
        }
      }

      previousPrevious = previous
      previous = current
    }

    return previous[target.count]
  }
}
