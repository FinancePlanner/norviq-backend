import Foundation

/// Heatmap grouping for the larger coins, keyed by CoinGecko id. CoinGecko's
/// own categories overlap heavily (one coin sits in a dozen), so a single
/// hand-picked sector reads better than any of them. Coins not listed fall
/// into "Other"; extend as the top of the market changes.
enum CryptoSectorMap {
    static let otherSector = "Other"

    static func sector(for id: String) -> String {
        sectors[id] ?? otherSector
    }

    /// Ids that must never reach a list even if the category call fails.
    /// The peg check in the service catches the rest.
    static let fallbackExcludedIds: Set<String> = [
        "tether", "usd-coin", "dai", "usds", "ethena-usde", "usd1-wlfi", "paypal-usd",
        "ripple-usd", "first-digital-usd", "true-usd", "usdd", "usual-usd", "usdtb",
        "global-dollar", "falcon-finance", "bfusd", "usdgo", "gho", "euro-coin",
        "blackrock-usd-institutional-digital-liquidity-fund", "hashnote-usyc",
        "ondo-us-dollar-yield", "frax", "crvusd", "agora-dollar",
    ]

    private static let sectors: [String: String] = [
        // Layer 1
        "bitcoin": "Layer 1", "ethereum": "Layer 1", "solana": "Layer 1", "cardano": "Layer 1",
        "tron": "Layer 1", "avalanche-2": "Layer 1", "near": "Layer 1", "sui": "Layer 1",
        "aptos": "Layer 1", "hedera-hashgraph": "Layer 1", "the-open-network": "Layer 1",
        "polkadot": "Layer 1", "internet-computer": "Layer 1", "kaspa": "Layer 1",
        "algorand": "Layer 1", "cosmos": "Layer 1", "sei-network": "Layer 1",
        "ethereum-classic": "Layer 1", "flare-networks": "Layer 1", "monad": "Layer 1",
        "vechain": "Layer 1", "celestia": "Layer 1", "hyperliquid": "Layer 1",
        "canton-network": "Layer 1", "pi-network": "Layer 1",
        // Payments
        "ripple": "Payments", "stellar": "Payments", "litecoin": "Payments",
        "bitcoin-cash": "Payments", "bitcoin-cash-sv": "Payments", "dash": "Payments",
        // Privacy
        "zcash": "Privacy", "monero": "Privacy", "beldex": "Privacy",
        // Layer 2 / scaling
        "arbitrum": "Layer 2", "mantle": "Layer 2", "polygon-ecosystem-token": "Layer 2",
        "blockstack": "Layer 2", "plasma": "Layer 2",
        // Exchange tokens
        "binancecoin": "Exchange", "leo-token": "Exchange", "okb": "Exchange",
        "crypto-com-chain": "Exchange", "bitget-token": "Exchange", "gatechain-token": "Exchange",
        "kucoin-shares": "Exchange", "htx-dao": "Exchange", "whitebit": "Exchange",
        // DeFi
        "uniswap": "DeFi", "aave": "DeFi", "ethena": "DeFi", "sky": "DeFi", "morpho": "DeFi",
        "jupiter-exchange-solana": "DeFi", "pancakeswap-token": "DeFi", "aerodrome-finance": "DeFi",
        "curve-dao-token": "DeFi", "raydium": "DeFi", "pendle": "DeFi", "ether-fi": "DeFi",
        "ondo-finance": "DeFi", "injective-protocol": "DeFi", "aster-2": "DeFi", "lighter": "DeFi",
        "derive": "DeFi", "just": "DeFi", "nexo": "DeFi",
        // Infrastructure / oracles / storage
        "chainlink": "Infra", "quant-network": "Infra", "filecoin": "Infra",
        "pyth-network": "Infra", "layerzero": "Infra",
        // AI
        "bittensor": "AI", "render-token": "AI", "fetch-ai": "AI", "virtual-protocol": "AI",
        "worldcoin-wld": "AI", "venice-token": "AI", "grass": "AI",
        // Meme
        "dogecoin": "Meme", "shiba-inu": "Meme", "pepe": "Meme", "official-trump": "Meme",
        "pudgy-penguins": "Meme", "spx6900": "Meme", "pump-fun": "Meme", "memecore": "Meme",
        "world-liberty-financial": "Meme",
        // Real-world assets / commodities
        "tether-gold": "RWA", "pax-gold": "RWA", "kinesis-gold": "RWA", "figure-heloc": "RWA",
    ]
}
