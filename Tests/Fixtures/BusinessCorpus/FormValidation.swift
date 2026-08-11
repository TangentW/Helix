@inline(never)
public func formMessage(_ fields: [String: String]) -> String {
    guard let name = fields["name"], !name.isEmpty else {
        return "Missing name"
    }
    guard let email = fields["email"], !email.isEmpty else {
        return "Missing email"
    }
    guard email.contains("@") else {
        return "Invalid email"
    }
    return "\(name):\(fields.count)"
}
