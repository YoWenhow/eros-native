import Testing
import ErosCore
import ErosServices

struct ReaderPrefetchViewportTests {
    @Test func usesAllVisibleShortPagesAndExcludesRetainedTiles() throws {
        let ratios = Dictionary(uniqueKeysWithValues: (0..<24).map { ($0, 0.25) })
        let geometry = VerticalReaderGeometry(count: 24, width: 200, ratios: ratios)
        let top = geometry.offset(index: 7, fraction: 0.5)
        let bottom = geometry.offset(index: 13, fraction: 0.5)
        let visible = try #require(geometry.visible(from: top, to: bottom))
        let focus = geometry.anchor(at: top + min(80, (bottom - top) / 4)).index
        let retained = geometry.retained(around: focus)

        #expect(visible == 7...13)
        #expect(retained == [6, 7, 8, 9, 10])
        #expect(ReaderPrefetchWindow.pages(after: visible, pageCount: geometry.count, limit: 2) == [14, 15])
        #expect(ReaderPrefetchWindow.pages(after: visible, pageCount: geometry.count, limit: 5) == [14, 15, 16, 17, 18])
        #expect(ReaderPrefetchWindow.pages(after: visible, pageCount: geometry.count, limit: 0).isEmpty)
    }

    @Test func tileGapsAndTouchingEdgesAreExcluded() {
        let geometry = VerticalReaderGeometry(count: 4, width: 120, ratios: [0: 1, 1: 1, 2: 1, 3: 1])
        #expect(geometry.visible(from: -40, to: 0) == nil)
        #expect(geometry.visible(from: 0, to: 128) == 0...0)
        #expect(geometry.visible(from: 120, to: 128) == nil)
        #expect(geometry.visible(from: 119, to: 129) == 0...1)
        #expect(geometry.visible(from: 120, to: 129) == 1...1)
        #expect(geometry.visible(from: 128, to: 256) == 1...1)
        #expect(geometry.visible(from: geometry.totalHeight, to: geometry.totalHeight + 12) == nil)
        #expect(geometry.visible(from: 128, to: 128) == nil)
        #expect(geometry.visible(from: 1, to: .infinity) == nil)
    }

    @Test func mixedTileSizesMatchPositiveRectangleIntersections() {
        let geometry = VerticalReaderGeometry(count: 6, width: 200,
            ratios: [0: 0.3, 1: 1.2, 2: 0.9, 3: 8, 4: 0.3, 5: 2])
        let edges = geometry.offsets.indices.flatMap { index in
            [geometry.offsets[index], geometry.offsets[index] + geometry.heights[index]]
        }
        let positions = edges.flatMap { [$0 - 0.25, $0, $0 + 0.25] }
        for from in positions {
            for to in positions where from < to {
                let expected = geometry.offsets.indices.filter { index in
                    geometry.offsets[index] < to && geometry.offsets[index] + geometry.heights[index] > from
                }
                #expect((geometry.visible(from: from, to: to).map(Array.init) ?? []) == expected)
            }
        }
    }
}
