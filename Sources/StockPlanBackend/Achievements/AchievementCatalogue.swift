import Foundation
import StockPlanShared

enum AchievementCategory: String, CaseIterable, Sendable {
    case gettingStarted = "getting_started"
    case discipline, craft, planning, learning, community, performance, hidden, classic
}

enum AchievementLanguage: Sendable {
    case en, pt

    /// Portuguese when the first language tag starts with `pt`, English otherwise.
    static func from(acceptLanguage: String?) -> Self {
        guard let first = acceptLanguage?.split(separator: ",").first else { return .en }
        let tag = first.trimmingCharacters(in: .whitespaces).lowercased()
        return tag.hasPrefix("pt") ? .pt : .en
    }
}

struct AchievementTierSpec: Sendable, Equatable {
    let tier: String
    let threshold: Int
    let xp: Int
}

struct AchievementDefinition: Sendable {
    let key: String
    let category: AchievementCategory
    let iconKey: String
    /// Ascending thresholds; a single-tier achievement has one spec with tier "".
    let tiers: [AchievementTierSpec]
    /// Evaluated only by the sweep, never live.
    let sweepOnly: Bool
    let isPerformance: Bool
    let isHidden: Bool
    let copy: [AchievementLanguage: (title: String, description: String)]

    init(
        key: String, category: AchievementCategory, iconKey: String, tiers: [AchievementTierSpec],
        sweepOnly: Bool, isPerformance: Bool, isHidden: Bool,
        en: (String, String), pt: (String, String)
    ) {
        self.key = key
        self.category = category
        self.iconKey = iconKey
        self.tiers = tiers
        self.sweepOnly = sweepOnly
        self.isPerformance = isPerformance
        self.isHidden = isHidden
        copy = [.en: (en.0, en.1), .pt: (pt.0, pt.1)]
    }
}

enum AchievementCatalogue {
    private static let tierNames = ["bronze", "silver", "gold"]

    private static func tiered(_ thresholds: [Int]) -> [AchievementTierSpec] {
        let xp = [25, 50, 100]
        return thresholds.enumerated().map {
            AchievementTierSpec(tier: tierNames[$0.offset], threshold: $0.element, xp: xp[$0.offset])
        }
    }

    private static func single(_ threshold: Int, xp: Int) -> [AchievementTierSpec] {
        [AchievementTierSpec(tier: "", threshold: threshold, xp: xp)]
    }

    static let all: [AchievementDefinition] = [
        AchievementDefinition(
            key: "start.first_holding", category: .gettingStarted, iconKey: "chart.pie.fill", tiers: single(1, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("First Holding", "Add your first holding."), pt: ("Primeira posição", "Adiciona a tua primeira posição.")
        ),
        AchievementDefinition(
            key: "start.first_budget", category: .gettingStarted, iconKey: "wallet.pass.fill", tiers: single(1, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Budget Set", "Set up your first budget."), pt: ("Orçamento definido", "Define o teu primeiro orçamento.")
        ),
        AchievementDefinition(
            key: "start.first_goal", category: .gettingStarted, iconKey: "target", tiers: single(1, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Goal Setter", "Create your first goal."), pt: ("Com objetivos", "Cria o teu primeiro objetivo.")
        ),
        AchievementDefinition(
            key: "start.onboarded", category: .gettingStarted, iconKey: "checkmark.seal.fill", tiers: single(1, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("All Set Up", "Finish setting up your account."), pt: ("Tudo a postos", "Conclui a configuração da tua conta.")
        ),
        AchievementDefinition(
            key: "start.bank_linked", category: .gettingStarted, iconKey: "building.columns.fill", tiers: single(1, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Connected", "Link a bank account."), pt: ("Ligado", "Liga uma conta bancária.")
        ),
        AchievementDefinition(
            key: "start.broker_linked", category: .gettingStarted, iconKey: "link", tiers: single(1, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Broker Linked", "Link a broker account."), pt: ("Corretora ligada", "Liga uma conta de corretora.")
        ),
        AchievementDefinition(
            key: "discipline.check_in", category: .discipline, iconKey: "flame.fill", tiers: tiered([7, 30, 100]),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Showing Up", "Check in on consecutive days."), pt: ("Presença", "Faz check-in em dias seguidos.")
        ),
        AchievementDefinition(
            key: "discipline.check_in_year", category: .discipline, iconKey: "calendar", tiers: single(365, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Year of Presence", "Keep a 365-day check-in streak."), pt: ("Um ano de presença", "Mantém uma sequência de 365 dias de check-in.")
        ),
        AchievementDefinition(
            key: "discipline.budget_streak", category: .discipline, iconKey: "chart.bar.fill", tiers: tiered([3, 6, 12]),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("On Budget", "Stay on budget for months in a row."), pt: ("Dentro do orçamento", "Cumpre o orçamento durante meses seguidos.")
        ),
        AchievementDefinition(
            key: "discipline.expense_days", category: .discipline, iconKey: "list.bullet.clipboard.fill", tiers: tiered([30, 100, 365]),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Tracker", "Log expenses on different days."), pt: ("Registo diário", "Regista despesas em dias diferentes.")
        ),
        AchievementDefinition(
            key: "discipline.recap_regular", category: .discipline, iconKey: "doc.text.fill", tiers: single(3, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Reflective", "Open your monthly recap three months in a row."), pt: ("Reflexivo", "Abre o teu resumo mensal três meses seguidos.")
        ),
        AchievementDefinition(
            key: "craft.thesis", category: .craft, iconKey: "pencil.and.outline", tiers: tiered([1, 10, 50]),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Thesis Writer", "Write down your investment thesis."), pt: ("Autor de teses", "Escreve a tua tese de investimento.")
        ),
        AchievementDefinition(
            key: "craft.memo_saved", category: .craft, iconKey: "bookmark.fill", tiers: single(1, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Memo Keeper", "Bookmark a position memo."), pt: ("Guardião de notas", "Guarda uma nota de posição nos favoritos.")
        ),
        AchievementDefinition(
            key: "craft.watchlist_review", category: .craft, iconKey: "eye.fill", tiers: tiered([1, 10, 50]),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Reviewer", "Review items on your watchlist."), pt: ("Revisor", "Revê itens da tua lista de observação.")
        ),
        AchievementDefinition(
            key: "craft.target_hit", category: .craft, iconKey: "scope", tiers: tiered([1, 5, 20]),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("On Target", "Have a price target alert trigger."), pt: ("Na mouche", "Vê um alerta de preço-alvo ser ativado.")
        ),
        AchievementDefinition(
            key: "craft.position_sizing", category: .craft, iconKey: "ruler.fill", tiers: single(1, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Sized Right", "Size a position with the terminal."), pt: ("Dimensão certa", "Dimensiona uma posição com o terminal.")
        ),
        AchievementDefinition(
            key: "craft.diversified", category: .craft, iconKey: "square.grid.2x2.fill", tiers: single(5, xp: 25),
            sweepOnly: true, isPerformance: false, isHidden: false,
            en: ("Diversified", "Hold stocks in five different sectors."), pt: ("Diversificado", "Tem ações em cinco setores diferentes.")
        ),
        AchievementDefinition(
            key: "craft.rebalanced", category: .craft, iconKey: "arrow.triangle.2.circlepath", tiers: single(1, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Rebalancer", "Complete a rebalance plan."), pt: ("Reequilibrador", "Conclui um plano de reequilíbrio.")
        ),
        AchievementDefinition(
            key: "craft.patient_capital", category: .craft, iconKey: "hourglass", tiers: single(1, xp: 25),
            sweepOnly: true, isPerformance: false, isHidden: false,
            en: ("Patient Capital", "Hold a stock for over a year."), pt: ("Capital paciente", "Mantém uma ação durante mais de um ano.")
        ),
        AchievementDefinition(
            key: "plan.retirement", category: .planning, iconKey: "sunset.fill", tiers: single(1, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Long View", "Create a retirement plan."), pt: ("Visão de longo prazo", "Cria um plano de reforma.")
        ),
        AchievementDefinition(
            key: "plan.scenario", category: .planning, iconKey: "slider.horizontal.3", tiers: tiered([1, 10, 50]),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("What If", "Run what-if scenarios."), pt: ("E se...", "Corre cenários hipotéticos.")
        ),
        AchievementDefinition(
            key: "plan.goal_done", category: .planning, iconKey: "flag.checkered", tiers: tiered([1, 3, 10]),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Goal Getter", "Complete your goals."), pt: ("Cumpridor", "Conclui os teus objetivos.")
        ),
        AchievementDefinition(
            key: "plan.contributions", category: .planning, iconKey: "plus.circle.fill", tiers: tiered([10, 50, 100]),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Steady Saver", "Add contributions to your goals."), pt: ("Poupador constante", "Faz contribuições para os teus objetivos.")
        ),
        AchievementDefinition(
            key: "learn.articles", category: .learning, iconKey: "book.fill", tiers: tiered([5, 25, 100]),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Reader", "Read articles."), pt: ("Leitor", "Lê artigos.")
        ),
        AchievementDefinition(
            key: "learn.muse", category: .learning, iconKey: "sparkles", tiers: tiered([1, 10, 50]),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Curious", "Chat with the AI assistant."), pt: ("Curioso", "Conversa com o assistente de IA.")
        ),
        AchievementDefinition(
            key: "learn.mcp", category: .learning, iconKey: "terminal.fill", tiers: single(1, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Power User", "Connect an access token or app."), pt: ("Utilizador avançado", "Liga um token de acesso ou uma aplicação.")
        ),
        AchievementDefinition(
            key: "learn.pilot", category: .learning, iconKey: "airplane", tiers: single(1, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Co-Pilot", "Follow a pilot."), pt: ("Copiloto", "Segue um piloto.")
        ),
        AchievementDefinition(
            key: "social.friends", category: .community, iconKey: "person.2.fill", tiers: tiered([1, 5, 20]),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Friendly", "Make friends on Norviq."), pt: ("Amigável", "Faz amigos no Norviq.")
        ),
        AchievementDefinition(
            key: "social.first_post", category: .community, iconKey: "text.bubble.fill", tiers: single(1, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("First Words", "Write your first board post."), pt: ("Primeiras palavras", "Escreve a tua primeira publicação.")
        ),
        AchievementDefinition(
            key: "social.popular_post", category: .community, iconKey: "hand.thumbsup.fill", tiers: single(10, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Crowd Favourite", "Get a post to a score of 10."), pt: ("Favorito da comunidade", "Leva uma publicação a uma pontuação de 10.")
        ),
        AchievementDefinition(
            key: "social.group", category: .community, iconKey: "person.3.fill", tiers: single(1, xp: 25),
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: ("Part of Something", "Join a group."), pt: ("Parte de algo", "Junta-te a um grupo.")
        ),
        AchievementDefinition(
            key: "perf.positive_year", category: .performance, iconKey: "arrow.up.right.circle.fill", tiers: single(1, xp: 100),
            sweepOnly: true, isPerformance: true, isHidden: false,
            en: ("Green Year", "Finish a calendar year in the green."), pt: ("Ano no verde", "Termina um ano civil com ganhos.")
        ),
        AchievementDefinition(
            key: "perf.beat_benchmark", category: .performance, iconKey: "trophy.fill", tiers: single(1, xp: 100),
            sweepOnly: true, isPerformance: true, isHidden: false,
            en: ("Market Beater", "Beat the benchmark over a year."), pt: ("Acima do mercado", "Supera o índice de referência ao longo de um ano.")
        ),
        AchievementDefinition(
            key: "perf.comeback", category: .performance, iconKey: "arrow.uturn.up.circle.fill", tiers: single(1, xp: 100),
            sweepOnly: true, isPerformance: true, isHidden: false,
            en: ("Comeback", "Recover from a drawdown."), pt: ("Recuperação", "Recupera de uma queda.")
        ),
        AchievementDefinition(
            key: "hidden.founding_member", category: .hidden, iconKey: "star.circle.fill", tiers: single(1, xp: 50),
            sweepOnly: false, isPerformance: false, isHidden: true,
            en: ("Founding Member", "You were one of the first 1,000 members."), pt: ("Membro fundador", "Foste um dos primeiros 1000 membros.")
        ),
    ]

    private static let byKey: [String: AchievementDefinition] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    static func definition(_ key: String) -> AchievementDefinition? {
        byKey[key]
    }

    private static let legacyPT: [BadgeType: (String, String)] = [
        .firstPurchase: ("Primeira compra", "Compra a tua primeira ação"),
        .newsReader: ("Leitor de notícias", "Mantém-te informado lendo notícias de ações"),
        .investor: ("Investidor", "Constrói a tua carteira com investimentos regulares"),
        .saver: ("Poupador", "Mantém uma taxa de poupança positiva todos os meses"),
        .frugalFun: ("Diversão frugal", "Fica abaixo do orçamento de lazer"),
        .spendingDetox: ("Detox de gastos", "Passa dias seguidos sem gastar"),
        .growthMindset: ("Mentalidade de crescimento", "Poupa mais dinheiro de mês para mês"),
    ]

    static func legacyDefinition(for badge: BadgeType) -> AchievementDefinition {
        let legacy = BadgeDefinitions.definition(for: badge)
        let xp = [XPRules.badge(.bronze), XPRules.badge(.silver), XPRules.badge(.gold)]
        let thresholds = [legacy.bronzeThreshold, legacy.silverThreshold, legacy.goldThreshold]
        let specs = (0 ..< 3).map {
            AchievementTierSpec(tier: tierNames[$0], threshold: thresholds[$0], xp: xp[$0])
        }
        let pt = legacyPT[badge] ?? (legacy.title, legacy.description)
        return AchievementDefinition(
            key: "legacy.\(badge.rawValue)", category: .classic, iconKey: legacy.iconName, tiers: specs,
            sweepOnly: false, isPerformance: false, isHidden: false,
            en: (legacy.title, legacy.description), pt: pt
        )
    }
}

extension AchievementCategory {
    /// Localized category heading.
    func title(_ language: AchievementLanguage) -> String {
        let pt = language == .pt
        switch self {
        case .gettingStarted: return pt ? "Primeiros passos" : "Getting started"
        case .discipline: return pt ? "Disciplina" : "Discipline"
        case .craft: return pt ? "Ofício" : "Craft"
        case .planning: return pt ? "Planeamento" : "Planning"
        case .learning: return pt ? "Aprendizagem" : "Learning"
        case .community: return pt ? "Comunidade" : "Community"
        case .performance: return pt ? "Desempenho" : "Performance"
        case .hidden: return pt ? "Segredos" : "Secrets"
        case .classic: return pt ? "Clássicos" : "Classic"
        }
    }
}
