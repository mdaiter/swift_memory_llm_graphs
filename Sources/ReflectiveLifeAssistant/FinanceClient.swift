import Foundation

struct Transaction: Equatable {
    let id: String
    let date: Date
    let amount: Double
    let description: String
    let category: String
}

protocol FinanceClient {
    func recentTransactions(days: Int) async throws -> [Transaction]
}

final class MockFinanceClient: FinanceClient {
    var transactions: [Transaction]

    init(transactions: [Transaction]) {
        self.transactions = transactions
    }

    func recentTransactions(days: Int) async throws -> [Transaction] {
        return transactions
    }
}
