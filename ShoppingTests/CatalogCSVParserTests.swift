import XCTest
@testable import Shopping

final class CatalogCSVParserTests: XCTestCase {
    func testParsesQuotedFieldsOptionalMappingsAndMultilineNotes() throws {
        let csv = """
        source_id,item_id,name,notes,category,stores
        export,1,"Bread, sliced","Line one
        Line two",Bakery,"Publix;Costco;publix;Ｐｕｂｌｉｘ"
        export,2,Milk,,,
        """

        let rows = try CatalogCSVParser.parse(Data(csv.utf8))

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].line, 2)
        XCTAssertEqual(rows[0].name, "Bread, sliced")
        XCTAssertEqual(rows[0].notes, "Line one\nLine two")
        XCTAssertEqual(rows[0].categoryName, "Bakery")
        XCTAssertEqual(rows[0].storeNames, ["Publix", "Costco"])
        XCTAssertEqual(rows[1].line, 4)
        XCTAssertNil(rows[1].categoryName)
        XCTAssertTrue(rows[1].storeNames.isEmpty)
    }

    func testRejectsFileLevelStructureButPreservesInvalidRowsForPreview() throws {
        XCTAssertThrowsError(try CatalogCSVParser.parse(Data("item_id,name\n1,Milk".utf8))) {
            XCTAssertEqual($0 as? CatalogCSVError, .missingColumns(["source_id"]))
        }
        XCTAssertThrowsError(try CatalogCSVParser.parse(Data("source_id,item_id,name\na,1,\"Milk".utf8))) {
            XCTAssertEqual($0 as? CatalogCSVError, .malformedQuote(line: 2))
        }

        let rows = try CatalogCSVParser.parse(Data(
            "source_id,item_id,name\na,1,Milk\na,1,Bread\na,,Eggs\na,3,Cheese,extra".utf8
        ))
        XCTAssertNil(rows[0].parseError)
        XCTAssertEqual(rows[1].parseError, "This source_id and item_id repeat an earlier row.")
        XCTAssertEqual(rows[2].parseError, "item_id is required.")
        XCTAssertEqual(rows[3].parseError, "Too many columns.")
    }
}
