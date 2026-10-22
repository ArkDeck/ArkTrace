enum SliceAggregateSort: String, CaseIterable {
    case total
    case average
    case occurrences
    case name

    var title: String {
        switch self {
        case .total: "Total"
        case .average: "Avg"
        case .occurrences: "Count"
        case .name: "Name"
        }
    }
}
