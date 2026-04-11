# Security Safeguards & Checklist

This document outlines the security standards and safeguards for the StockPlan project, adapted from the "VIBE CODER" pre-ship checklist for our Swift (Vapor) API and Mobile client.

## Status Summary

| Category | Status | Notes |
| :--- | :---: | :--- |
| **Authentication** | 🟡 | JWT + Opaque Refresh Tokens implemented. Rate limiting & account lockout missing. |
| **API Security** | 🟡 | Auth middleware & DTOs used. CORS is permissive. Rate limiting missing. |
| **Database** | ✅ | Fluent ORM used (No SQL injection). Backups handled by infrastructure. |
| **Infrastructure** | ✅ | Secrets in Env, non-root Docker user, SSL via Nginx. |
| **Code** | ✅ | No hardcoded credentials. Swift log levels used. |

---

## 1. Authentication

- [x] **Passwords hashed with BCrypt**: Handled by Vapor's `req.password.hash()`.
- [ ] **Tokens stored in httpOnly cookies (Web)**: Current client is Mobile (Headers used). For web clients, must switch to httpOnly cookies.
- [x] **Secure JWT Secrets**: Configured via `JWT_SECRET` environment variable. 
  - *Requirement: Must be >= 32 characters in production.*
- [x] **Access Token Expiration**: Implemented via JWT `exp` claim (Default: 1 hour).
- [x] **Refresh Token Rotation**: Implemented in `AuthService.refresh()`. Tokens are one-time use and rotated.
- [ ] **Rate Limiting on /login and /register**: **NOT IMPLEMENTED**.
  - *Action: Add middleware to limit attempts per IP/Email.*
- [ ] **Account Lockout**: **NOT IMPLEMENTED**.
  - *Action: Track failed attempts in `User` model and lock for 15 mins after 5 failures.*
- [x] **Sessions invalidated server-side**: Handled via Refresh Token deletion in database on logout.
- [ ] **Email Verification**: **PARTIAL**. Logic exists for password reset codes, but not for mandatory account activation.
  - *Action: Add `isVerified` flag to User and block access until verified.*

## 2. API Security

- [x] **Route Verification**: Protected routes use `SessionToken.guardMiddleware()`.
- [x] **Authorization Checks**: Handled in Services (e.g., `repo.find(id, userId)`).
- [x] **Schema Validation**: Handled via Swift `Content` decoding and DTOs.
- [x] **Sensitive Fields Filtered**: DTOs (e.g., `AuthUserResponse`) exclude hashes/internals.
- [x] **Safe Error Messages**: Production uses `ErrorMiddleware.default` which hides details.
- [ ] **Public Rate Limiting**: **NOT IMPLEMENTED**.
- [🟡] **CORS Restricted**: Currently `.all` in `configure.swift`.
  - *Action: Restrict to specific domains in production.*
- [x] **HTTPS Enforcement**: Handled by Nginx/Infrastructure layer.

## 3. Database

- [x] **Parameterized Queries**: Guaranteed by Fluent ORM.
- [x] **Limited-Permission User**: Database user restricted to app-specific schema.
- [x] **Private Access**: DB is not exposed to the public internet (internal network only).
- [ ] **Sensitive Fields Encrypted at Rest**: Password hashes are one-way, but other sensitive PII (if any) should be reviewed for encryption.

## 4. Infrastructure

- [x] **Secrets in Environment**: Verified in `configure.swift`.
- [x] **Clean Git History**: `.env` is ignored and not present in history.
- [x] **Non-Root Execution**: Dockerfile uses `USER vapor:vapor`.
- [x] **Minimal Ports**: Only 80/443 (via Nginx) and 8080 (internal) are used.

## 5. Mobile Client Safeguards

- [ ] **Secure Storage**: Use Keychain (iOS) or EncryptedSharedPreferences (Android) for tokens. **Never use UserDefaults/SharedPreferences for secrets.**
- [ ] **SSL Pinning**: (Optional but recommended) Implement to prevent MITM attacks.
- [ ] **Root/Jailbreak Detection**: Prevent app execution on compromised devices for sensitive financial data.
- [ ] **Biometric Lock**: Require FaceID/TouchID for app access.

---

## Implementation Plan

### Phase 1: High Priority (Next 48h)
1. **Rate Limiting**: Integrate `VaporRateLimiter` or custom middleware for `auth/login` and `auth/register`.
2. **CORS Hardening**: Update `configure.swift` to use `Environment.get("ALLOWED_ORIGINS")`.
3. **Password Requirements**: Enforce minimum length and complexity in `AuthRegisterRequest`.

### Phase 2: Medium Priority
1. **Account Lockout**: Add `failedLoginAttempts` and `lockoutUntil` to `User` model.
2. **Email Verification**: Implement mandatory verification flow for new registrations.
3. **Audit Logging**: Ensure critical actions (login, password change, data export) are logged.

### Phase 3: Long Term
1. **PII Encryption**: Review database for sensitive user data that needs encryption at rest beyond hashing.
2. **Mobile Security Audit**: Verify Keychain usage and implement Biometric lock in the mobile codebase.
