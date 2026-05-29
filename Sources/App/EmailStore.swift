import Foundation

struct RememberedEmail: Codable {
    let clientId: String
    let serviceName: String
    let email: String
}

final class EmailStore {

    private static let key = "remembered_emails"
    private static let defaults = UserDefaults.standard

    static func getRemembered(clientId: String) -> String? {
        all().first { $0.clientId == clientId }?.email
    }

    static func remember(clientId: String, serviceName: String, email: String) {
        var list = all().filter { $0.clientId != clientId }
        list.append(RememberedEmail(clientId: clientId, serviceName: serviceName, email: email))
        save(list)
    }

    static func forget(clientId: String) {
        save(all().filter { $0.clientId != clientId })
    }

    static func all() -> [RememberedEmail] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([RememberedEmail].self, from: data)
        else { return [] }
        return list
    }

    private static func save(_ list: [RememberedEmail]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: key)
        }
    }
}
