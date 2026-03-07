import Fluent
import Vapor
import Foundation

final class User: Model, Authenticatable, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "email")
    var email: String

    @Field(key: "password_hash")
    var passwordHash: String

    @OptionalField(key: "username")
    var username: String?

    @OptionalField(key: "first_name")
    var firstName: String?

    @OptionalField(key: "last_name")
    var lastName: String?

    @OptionalField(key: "bio")
    var bio: String?

    @OptionalField(key: "avatar_url")
    var avatarURLString: String?

    @OptionalField(key: "banner_avatar_url")
    var bannerAvatarURLString: String?

    @OptionalField(key: "date_of_birth")
    var dateOfBirth: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        email: String,
        passwordHash: String,
        username: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        bio: String? = nil,
        avatarURLString: String? = nil,
        bannerAvatarURLString: String? = nil,
        dateOfBirth: Date? = nil
    ) {
        self.id = id
        self.email = email
        self.passwordHash = passwordHash
        self.username = username
        self.firstName = firstName
        self.lastName = lastName
        self.bio = bio
        self.avatarURLString = avatarURLString
        self.bannerAvatarURLString = bannerAvatarURLString
        self.dateOfBirth = dateOfBirth
    }
}
