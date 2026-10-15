import StockPlanShared
import Vapor

typealias UserProfile = StockPlanShared.UserProfile
typealias GetUserProfileRequest = StockPlanShared.GetUserProfileRequest
typealias GetUserProfileResponse = StockPlanShared.GetUserProfileResponse
typealias UpdateUserProfileRequest = StockPlanShared.UpdateUserProfileRequest
typealias UpdateUserProfileResponse = StockPlanShared.UpdateUserProfileResponse
typealias DeleteUserProfileRequest = StockPlanShared.DeleteUserProfileRequest
typealias DeleteUserProfileResponse = StockPlanShared.DeleteUserProfileResponse

/// `PATCH /v1/users/email`. A backend-local superset of
/// `StockPlanShared.UpdateEmailRequest`, which is pinned by exact version and
/// has no password field. Old clients still decode here; they get
/// CURRENT_PASSWORD_REQUIRED instead of a silent email change.
struct UpdateEmailWithReauthRequest: Content {
    let email: String
    let currentPassword: String?
    /// The caller's own refresh token. Every other session is revoked on
    /// success; this one is spared so the client stays signed in.
    let refreshToken: String?
}

/// Optional `refreshToken` read alongside a shared request body (password
/// change), with the same meaning as `UpdateEmailWithReauthRequest.refreshToken`.
struct CallerRefreshToken: Content {
    let refreshToken: String?
}
