enum CartedNeedOrdering {
    static func ordered(
        _ needs: [Need],
        categories: [Category],
        household: Household?
    ) -> [Need] {
        CategoryGrouping.orderedNeeds(needs, categories: categories, household: household)
    }
}
