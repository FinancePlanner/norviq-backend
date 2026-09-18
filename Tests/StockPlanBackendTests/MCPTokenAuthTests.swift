import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("MCP Personal Access Token Auth Tests", .serialized)
struct MCPTokenAuthTests {
    // Decoding `[T].self` inline trips a type-checker failure in these expressions,
    // while `Array<T>.self` trips swiftformat's typeSugar rule. Named aliases keep
    // both happy.
    private typealias TransactionList = [TransactionResponse]
    private typealias WatchlistItemList = [WatchlistItemResponse]

    // MARK: - Harness

    private func withApp(_ test: @escaping (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func registerUser(app: Application) async throws -> (token: String, userId: UUID) {
        let identifier = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "mcp_user_\(identifier)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "mcp_\(identifier)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            token = try res.content.decode(AuthResponse.self).token
        })
        let session = try await app.jwt.keys.verify(token, as: SessionToken.self)
        return (token, session.userId)
    }

    /// Mints a PAT directly (bypasses the pro-gate that create() enforces) so
    /// auth-matrix tests don't require a Pro entitlement.
    private func mintPAT(app: Application, userId: UUID, scopes: [APIScope]) async throws -> String {
        let raw = OpaqueToken.generate(prefix: OpaqueToken.patPrefix)
        let pat = PersonalAccessToken(
            userId: userId,
            name: "test",
            tokenHash: OpaqueToken.sha256Hex(raw),
            scopes: scopes.map(\.rawValue),
            expiresAt: Date().addingTimeInterval(3600)
        )
        try await pat.save(on: app.db)
        return raw
    }

    // MARK: - Authenticator matrix

    @Test("PAT with expenses:read can list expenses")
    func patReadListsExpenses() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead])
            try await app.testing().test(.GET, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("PAT without expenses:write is forbidden from creating an expense")
    func patMissingWriteScopeForbidden() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead])
            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
                try req.content.encode(ExpenseRequest(
                    title: "x", amount: 1, pillar: .fundamentals, occurredOn: "2026-07-02"
                ))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("PAT with market:read can read the news feed (MCP get_news, source=tracked)")
    func patMarketReadReadsNewsFeed() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.marketRead])
            try await app.testing().test(.GET, "v1/news/feed?limit=5", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("PAT without market:read is forbidden from the news feed")
    func patWithoutMarketReadForbiddenFromNewsFeed() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead])
            try await app.testing().test(.GET, "v1/news/feed", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }

    /// The public ticker pages are served by the web pod, which authenticates
    /// with a PAT. `market:read` is what the market group checks, and the two
    /// routes below need nothing more than it — but that is not the whole
    /// requirement for the page, on two counts:
    ///
    /// - `/v1/market/earnings/{symbol}` sits on this same group and also calls
    ///   `requirePremium(.earningsText)`, so the token's *owner* must be on Pro.
    /// - `/v1/insights/tickers/{symbol}/sentiment` is not on this group at all.
    ///   It needs `insights:read`, and `requirePremium(.aiInsights)` on top.
    ///
    /// Every one of those refusals is a 403 the public page swallows, so the
    /// section simply is not there at HTTP 200. The tests that follow pin each.
    @Test("PAT with market:read clears auth on the technicals and earnings-calendar routes")
    func patMarketReadClearsMarketReadRoutes() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.marketRead])

            for path in [["technicals", ":symbol"], ["earnings-calendar"]] {
                // Assert the route exists separately from calling it, so that a
                // 404 from a mistyped path can never be mistaken for the market
                // provider declining to answer.
                let expected = ["v1", "market"] + path
                #expect(app.routes.all.contains {
                    $0.method == .GET && $0.path.map(\.description) == expected
                })

                let requested = expected.map { $0 == ":symbol" ? "AAPL" : $0 }.joined(separator: "/")
                try await app.testing().test(.GET, requested, beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: pat)
                }, afterResponse: { res async in
                    // Whatever the market provider is configured to do in this
                    // run — answer, 404 an empty symbol, or 503 while
                    // unconfigured — the request got past auth and the scope
                    // check to reach it, which is the whole claim here.
                    #expect(res.status != .unauthorized)
                    #expect(res.status != .forbidden)
                })
            }
        }
    }

    /// Runs `body` with the billing bypass pinned, so a test can separate the
    /// scope check from the entitlement check instead of inheriting whatever the
    /// last suite left in the environment.
    private func withBillingBypass(_ enabled: Bool, _ body: () async throws -> Void) async throws {
        let previous = getenv("BYPASS_BILLING").map { String(cString: $0) }
        setenv("BYPASS_BILLING", enabled ? "true" : "false", 1)
        defer {
            if let previous {
                setenv("BYPASS_BILLING", previous, 1)
            } else {
                unsetenv("BYPASS_BILLING")
            }
        }
        try await body()
    }

    /// The public page's sentiment badge comes from the insights group, not the
    /// market group, so a PAT minted on the "market:read is the whole
    /// requirement" advice is refused here — and the page swallows it.
    @Test("PAT with market:read alone is forbidden from the ticker sentiment route")
    func patMarketReadAloneForbiddenFromTickerSentiment() async throws {
        try await withBillingBypass(true) {
            try await withApp { app in
                let user = try await registerUser(app: app)
                let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.marketRead])
                try await app.testing().test(.GET, "v1/insights/tickers/AAPL/sentiment", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: pat)
                }, afterResponse: { res async in
                    // Billing is bypassed for this run, so the only thing left
                    // that can refuse is the scope requirement.
                    #expect(res.status == .forbidden)
                })
            }
        }
    }

    @Test("PAT with insights:read clears auth on the ticker sentiment route")
    func patInsightsReadClearsTickerSentiment() async throws {
        try await withBillingBypass(true) {
            try await withApp { app in
                let user = try await registerUser(app: app)
                let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.marketRead, .insightsRead])
                try await app.testing().test(.GET, "v1/insights/tickers/AAPL/sentiment", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: pat)
                }, afterResponse: { res async in
                    #expect(res.status != .unauthorized)
                    #expect(res.status != .forbidden)
                })
            }
        }
    }

    /// Scopes are only half of it. A PAT is always minted for a user, and these
    /// two routes read that user's plan, so a token owned by a free account
    /// loses the public page its earnings table and its sentiment badge with no
    /// signal beyond a 403 the web pod is written to ignore.
    @Test("PAT owned by a free account is refused earnings and ticker sentiment")
    func patOnFreeAccountRefusedProMarketRoutes() async throws {
        try await withBillingBypass(false) {
            try await withApp { app in
                let user = try await registerUser(app: app)
                // Registration starts a trial, and a trial resolves as Pro. A
                // service account minted months ago is past that, which is the
                // state this pins: no entitlement row, no live trial.
                let account = try #require(try await User.find(user.userId, on: app.db))
                account.trialStartedAt = nil
                account.trialDays = nil
                account.trialTier = nil
                try await account.save(on: app.db)

                let pat = try await mintPAT(
                    app: app,
                    userId: user.userId,
                    scopes: [.marketRead, .insightsRead]
                )

                for path in ["v1/market/earnings/AAPL", "v1/insights/tickers/AAPL/sentiment"] {
                    try await app.testing().test(.GET, path, beforeRequest: { req in
                        req.headers.bearerAuthorization = .init(token: pat)
                    }, afterResponse: { res async in
                        #expect(res.status == .forbidden)
                        // Distinguishes the entitlement gate from a scope
                        // failure, which answers 403 as well.
                        #expect(res.body.string.contains("upgrade_required"))
                    })
                }
            }
        }
    }

    @Test("PAT without market:read is forbidden from the technicals route")
    func patWithoutMarketReadForbiddenFromTechnicals() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead])
            try await app.testing().test(.GET, "v1/market/technicals/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("PAT without research:write cannot write news items")
    func patCannotCreateNewsWithoutScope() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.marketRead, .expensesWrite])
            try await app.testing().test(.POST, "v1/news", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
                struct NewsWrite: Content { let symbol: String; let headline: String }
                try req.content.encode(NewsWrite(symbol: "AAPL", headline: "x"))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("PAT with expenses:write can create an expense")
    func patWriteCreatesExpense() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesWrite])
            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
                try req.content.encode(ExpenseRequest(
                    title: "coffee", amount: 4, pillar: .fundamentals, occurredOn: "2026-07-02"
                ))
            }, afterResponse: { res async in
                #expect(res.status == .created)
            })
        }
    }

    @Test("Revoked PAT is rejected")
    func revokedPATRejected() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let raw = OpaqueToken.generate(prefix: OpaqueToken.patPrefix)
            let pat = PersonalAccessToken(
                userId: user.userId, name: "revoked",
                tokenHash: OpaqueToken.sha256Hex(raw), scopes: [APIScope.expensesRead.rawValue],
                expiresAt: Date().addingTimeInterval(3600), revokedAt: Date()
            )
            try await pat.save(on: app.db)
            try await app.testing().test(.GET, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: raw)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Expired PAT is rejected")
    func expiredPATRejected() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let raw = OpaqueToken.generate(prefix: OpaqueToken.patPrefix)
            let pat = PersonalAccessToken(
                userId: user.userId, name: "expired",
                tokenHash: OpaqueToken.sha256Hex(raw), scopes: [APIScope.expensesRead.rawValue],
                expiresAt: Date().addingTimeInterval(-60)
            )
            try await pat.save(on: app.db)
            try await app.testing().test(.GET, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: raw)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    // MARK: - Security invariant: PAT must not reach non-scoped first-party routes

    @Test("PAT cannot manage tokens (first-party only)")
    func patCannotManageTokens() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead, .expensesWrite])
            try await app.testing().test(.GET, "v1/tokens", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                // Opaque token is not a JWT → SessionToken.authenticator() rejects it.
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("PAT is forbidden from first-party expense sub-resources (recurring templates)")
    func patForbiddenFromFirstPartySubresource() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead, .expensesWrite])
            try await app.testing().test(.GET, "v1/expenses/recurring", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }

    // MARK: - Portfolio summary is exposed to third-party tokens under portfolio:read

    @Test("PAT with portfolio:read alone can read the portfolio summary")
    func patPortfolioReadReadsPortfolioSummary() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.portfolioRead])
            try await app.testing().test(.GET, "v1/portfolio/summary", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("Legacy PAT with market:read still reads the portfolio summary")
    func patMarketReadReadsPortfolioSummary() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.marketRead])
            try await app.testing().test(.GET, "v1/portfolio/summary", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("PAT holding neither portfolio:read nor market:read is forbidden from the summary")
    func patMissingPortfolioScopesForbiddenFromPortfolioSummary() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead])
            try await app.testing().test(.GET, "v1/portfolio/summary", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("PAT without the portfolio domain scopes is forbidden, not unauthorized")
    func patWithoutPortfolioScopeForbidden() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            // market:read alone carries none of the portfolio/transactions domains.
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.marketRead])
            for path in ["v1/portfolio/lists", "v1/portfolio/performance", "v1/pnl", "v1/transactions"] {
                try await app.testing().test(.GET, path, beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: pat)
                }, afterResponse: { res async in
                    #expect(res.status == .forbidden)
                })
            }
        }
    }

    // MARK: - First-party session still works everywhere

    @Test("First-party JWT works on scoped routes with no scope context")
    func firstPartyJWTUnaffected() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            try await app.testing().test(.GET, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.GET, "v1/expenses/recurring", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async in
                #expect(res.status != .forbidden && res.status != .unauthorized)
            })
            try await app.testing().test(.GET, "v1/portfolio/summary", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    // MARK: - PAT lifecycle stores only hashes

    @Test("Created PAT stores only a hash, never plaintext")
    func patStoresOnlyHash() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let raw = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead])
            let stored = try await PersonalAccessToken.query(on: app.db).all()
            #expect(stored.count == 1)
            for row in stored {
                #expect(row.tokenHash != raw)
                #expect(row.tokenHash == OpaqueToken.sha256Hex(raw))
            }
        }
    }

    // MARK: - Per-domain scopes

    @Test("PAT with watchlist scopes can round-trip a watchlist row with status and note")
    func patWatchlistRoundTrip() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(
                app: app, userId: user.userId, scopes: [.watchlistRead, .watchlistWrite]
            )
            try await app.testing().test(.POST, "v1/watchlist", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
                try req.content.encode(WatchlistItemRequest(
                    symbol: "AVGO", note: "Buy at $345-$355", status: .waiting
                ))
            }, afterResponse: { res async in
                #expect(res.status == .created || res.status == .ok)
            })

            // Verify by content, not by the write reporting success.
            try await app.testing().test(.GET, "v1/watchlist", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let items = try res.content.decode(WatchlistItemList.self)
                let avgo = items.first { $0.symbol == "AVGO" }
                #expect(avgo != nil)
                #expect(avgo?.status == .waiting)
                #expect(avgo?.note == "Buy at $345-$355")
            })
        }
    }

    @Test("PAT with only watchlist:read cannot write a watchlist row")
    func patWatchlistReadCannotWrite() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.watchlistRead])
            try await app.testing().test(.POST, "v1/watchlist", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
                try req.content.encode(WatchlistItemRequest(symbol: "TSM", note: nil, status: .waiting))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("PAT with transactions:write can record a trade and read it back")
    func patRecordsTransaction() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(
                app: app, userId: user.userId, scopes: [.transactionsRead, .transactionsWrite]
            )
            let body = CreateTransactionRequest(
                symbol: "AVGO",
                type: "buy",
                quantity: 10,
                price: 350,
                currency: "USD",
                tradeDate: "2026-09-01",
                settleDate: nil,
                fees: 1.5,
                portfolioListId: nil
            )
            try await app.testing().test(.POST, "v1/transactions", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
                try req.content.encode(body)
            }, afterResponse: { res async in
                #expect(res.status == .created)
            })

            try await app.testing().test(.GET, "v1/transactions", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let rows = try res.content.decode(TransactionList.self)
                let symbols = rows.map(\.instrumentId)
                let types = rows.map(\.type)
                #expect(symbols.contains("AVGO"))
                #expect(types.contains("buy"))
            })
        }
    }

    @Test("Goals and budget no longer answer to expenses:write after the per-domain split")
    func migratedScopesNoLongerAcceptExpensesWrite() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(
                app: app, userId: user.userId, scopes: [.expensesRead, .expensesWrite]
            )
            for path in ["v1/goals", "v1/budget/snapshots"] {
                try await app.testing().test(.GET, path, beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: pat)
                }, afterResponse: { res async in
                    #expect(res.status == .forbidden)
                })
            }
        }
    }

    @Test("Goals answer to goals:read once the token carries it")
    func goalsScopeWorks() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: [.goalsRead])
            try await app.testing().test(.GET, "v1/goals", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    // MARK: - The three endpoints no scope may reach

    @Test("No scope reaches account deletion, token minting, or OAuth consent")
    func humanOnlyEndpointsStayUnreachable() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            // Every grantable scope at once — the carve-outs must still hold.
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: APIScope.grantable)

            try await app.testing().test(.DELETE, "v1/users", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized || res.status == .forbidden)
            })

            try await app.testing().test(.POST, "v1/tokens", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: pat)
                struct Mint: Content { let name: String; let scopes: [String] }
                try req.content.encode(Mint(name: "escalated", scopes: ["expenses:write"]))
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized || res.status == .forbidden)
            })

            try await app.testing().test(
                .POST, "v1/oauth/flows/\(UUID().uuidString)/approve",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: pat)
                }, afterResponse: { res async in
                    #expect(res.status == .unauthorized || res.status == .forbidden)
                }
            )
        }
    }

    @Test("Credential mutations stay out of reach of every scope")
    func credentialMutationsStayFirstParty() async throws {
        try await withApp { app in
            let user = try await registerUser(app: app)
            let pat = try await mintPAT(app: app, userId: user.userId, scopes: APIScope.grantable)
            for path in ["v1/users/email", "v1/users/password", "v1/users/username"] {
                try await app.testing().test(.PATCH, path, beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: pat)
                }, afterResponse: { res async in
                    #expect(res.status == .unauthorized || res.status == .forbidden)
                })
            }
        }
    }
}
