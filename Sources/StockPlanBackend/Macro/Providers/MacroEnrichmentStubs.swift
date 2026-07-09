import Foundation
import Vapor

/// Seeking Alpha and Investing.com were requested as additional macro
/// enrichment sources. Neither publishes an official public API, and scraping
/// their sites violates their terms of service, so these ship as permanently
/// disabled stubs behind env flags (`MACRO_ENRICHMENT_SEEKING_ALPHA_ENABLED`,
/// `MACRO_ENRICHMENT_INVESTING_ENABLED`). Enabling them is a product/legal
/// decision, not a code change — see docs/POST-MVP.md "Risks".
struct SeekingAlphaEnrichment: MacroEnrichmentProviding {
    let name = "seeking-alpha"
    let flagEnabled: Bool

    var isEnabled: Bool {
        false
    } // Hard-disabled regardless of flag; see above.

    func enrich(_ result: MacroProviderResult, country _: MacroCountry, on req: Request) async -> MacroProviderResult {
        if flagEnabled {
            req.logger.warning("seeking_alpha enrichment flag is set but the provider is not implemented (no public API / ToS risk)")
        }
        return result
    }
}

struct InvestingComEnrichment: MacroEnrichmentProviding {
    let name = "investing-com"
    let flagEnabled: Bool

    var isEnabled: Bool {
        false
    } // Hard-disabled regardless of flag; see above.

    func enrich(_ result: MacroProviderResult, country _: MacroCountry, on req: Request) async -> MacroProviderResult {
        if flagEnabled {
            req.logger.warning("investing_com enrichment flag is set but the provider is not implemented (no public API / ToS risk)")
        }
        return result
    }
}
