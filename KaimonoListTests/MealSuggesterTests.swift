import Testing
import Foundation
@testable import KaimonoList

/// MealSuggester の献立提案スコアリングの検証。
/// 購入履歴(好み)を多く含むレシピが上位に来ること、除外・上限が正しく効くことを確認する。
@MainActor
struct MealSuggesterTests {

    // MARK: - テスト用のレシピ生成

    private func recipe(id: String, name: String, ingredients: [String]) -> Recipe {
        Recipe(
            id: id,
            name: name,
            emoji: "🍽️",
            ingredients: ingredients.map { RecipeIngredient(name: $0, quantity: nil) },
            memo: nil,
            createdAt: nil
        )
    }

    // MARK: - 正規化

    @Test("normalize は前後空白を除去し小文字化する")
    func normalizeTrimsAndLowercases() {
        #expect(MealSuggester.normalize("  Milk  ") == "milk")
        #expect(MealSuggester.normalize("牛乳") == "牛乳")
    }

    // MARK: - スコア順

    @Test("好み食材を多く含むレシピほど上位に来る")
    func ranksByPreferenceScore() {
        let recipes = [
            recipe(id: "a", name: "肉じゃが", ingredients: ["じゃがいも", "牛肉", "玉ねぎ"]),
            recipe(id: "b", name: "冷奴", ingredients: ["豆腐"]),
        ]
        // じゃがいも・牛肉・玉ねぎをよく買う世帯
        let counts = ["じゃがいも": 5, "牛肉": 3, "玉ねぎ": 4, "豆腐": 1]

        let result = MealSuggester.suggest(
            recipes: recipes, preferenceCounts: counts, excludedRecipeIds: [], limit: 5
        )

        #expect(result.count == 2)
        #expect(result.first?.id == "a")           // 5+3+4=12 で最上位
        #expect(result.first?.score == 12)
        #expect(result.last?.id == "b")            // 1
    }

    @Test("好みに一致した材料が理由として記録される")
    func recordsMatchedIngredients() {
        let recipes = [recipe(id: "a", name: "サラダ", ingredients: ["レタス", "トマト", "謎の食材"])]
        let counts = ["レタス": 2, "トマト": 1]

        let result = MealSuggester.suggest(
            recipes: recipes, preferenceCounts: counts, excludedRecipeIds: [], limit: 5
        )

        #expect(result.first?.matchedIngredients == ["レタス", "トマト"])
    }

    @Test("双方向の部分一致でマッチする(牛乳 ⊂ 低脂肪牛乳)")
    func matchesBySubstring() {
        let recipes = [recipe(id: "a", name: "シチュー", ingredients: ["牛乳"])]
        let counts = ["低脂肪牛乳": 3]   // 履歴側が長い名前でもマッチ

        let result = MealSuggester.suggest(
            recipes: recipes, preferenceCounts: counts, excludedRecipeIds: [], limit: 5
        )

        #expect(result.first?.score == 3)
    }

    // MARK: - 除外・上限・空入力

    @Test("excludedRecipeIds のレシピは提案されない")
    func excludesGivenRecipes() {
        let recipes = [
            recipe(id: "a", name: "肉じゃが", ingredients: ["じゃがいも"]),
            recipe(id: "b", name: "カレー", ingredients: ["じゃがいも"]),
        ]
        let counts = ["じゃがいも": 5]

        let result = MealSuggester.suggest(
            recipes: recipes, preferenceCounts: counts, excludedRecipeIds: ["a"], limit: 5
        )

        #expect(result.map(\.id) == ["b"])
    }

    @Test("スコア0(好みに一致しない)のレシピは含めない")
    func excludesZeroScore() {
        let recipes = [recipe(id: "a", name: "謎料理", ingredients: ["謎の食材"])]
        let counts = ["じゃがいも": 5]

        let result = MealSuggester.suggest(
            recipes: recipes, preferenceCounts: counts, excludedRecipeIds: [], limit: 5
        )

        #expect(result.isEmpty)
    }

    @Test("limit を超えて返さない")
    func respectsLimit() {
        let recipes = (1...10).map { recipe(id: "\($0)", name: "料理\($0)", ingredients: ["米"]) }
        let counts = ["米": 1]

        let result = MealSuggester.suggest(
            recipes: recipes, preferenceCounts: counts, excludedRecipeIds: [], limit: 3
        )

        #expect(result.count == 3)
    }

    @Test("履歴が空なら提案は空")
    func emptyHistoryReturnsEmpty() {
        let recipes = [recipe(id: "a", name: "肉じゃが", ingredients: ["じゃがいも"])]

        let result = MealSuggester.suggest(
            recipes: recipes, preferenceCounts: [:], excludedRecipeIds: [], limit: 5
        )

        #expect(result.isEmpty)
    }

    @Test("レシピが空なら提案は空")
    func emptyRecipesReturnsEmpty() {
        let result = MealSuggester.suggest(
            recipes: [], preferenceCounts: ["じゃがいも": 5], excludedRecipeIds: [], limit: 5
        )

        #expect(result.isEmpty)
    }

    // MARK: - 旬の食材

    @Test("旬の食材を含むレシピは加点され、理由に記録される")
    func addsSeasonalBonus() {
        let recipes = [recipe(id: "a", name: "焼きなす", ingredients: ["なす", "醤油"])]

        let result = MealSuggester.suggest(
            recipes: recipes,
            preferenceCounts: ["醤油": 1],
            seasonalIngredients: ["なす"],
            excludedRecipeIds: [],
            limit: 5
        )

        // 好み1 + 旬ボーナス(なす1つ)
        #expect(result.first?.score == 1 + MealSuggester.seasonalBonusPerIngredient)
        #expect(result.first?.seasonalMatches == ["なす"])
    }

    @Test("好み履歴が無くても旬の食材だけで提案できる")
    func seasonalOnlySuggestion() {
        let recipes = [recipe(id: "a", name: "冷やしトマト", ingredients: ["トマト"])]

        let result = MealSuggester.suggest(
            recipes: recipes,
            preferenceCounts: [:],
            seasonalIngredients: ["トマト"],
            excludedRecipeIds: [],
            limit: 5
        )

        #expect(result.map(\.id) == ["a"])
        #expect(result.first?.score == MealSuggester.seasonalBonusPerIngredient)
    }

    // MARK: - マンネリ回避(直近の献立履歴)

    @Test("直近に作ったレシピは減点され、作っていないレシピが上位に来る")
    func penalizesRecentlyCooked() {
        let recipes = [
            recipe(id: "a", name: "カレー", ingredients: ["じゃがいも", "牛肉"]),
            recipe(id: "b", name: "肉じゃが", ingredients: ["じゃがいも", "牛肉"]),
        ]
        let counts = ["じゃがいも": 5, "牛肉": 5]   // どちらも好みスコアは 10 で同点

        let result = MealSuggester.suggest(
            recipes: recipes,
            preferenceCounts: counts,
            recentCookCounts: ["a": 2],   // カレーは直近2回作った
            excludedRecipeIds: [],
            limit: 5
        )

        // 減点で肉じゃがが上位に
        #expect(result.map(\.id) == ["b", "a"])
        #expect(result.first?.score == 10)
        #expect(result.last?.score == 10 - 2 * MealSuggester.recencyPenaltyPerCook)
    }

    @Test("減点でスコアが0以下になったレシピは提案しない")
    func dropsRecipeWhenPenaltyExceedsScore() {
        let recipes = [recipe(id: "a", name: "味噌汁", ingredients: ["豆腐"])]
        let counts = ["豆腐": 1]

        let result = MealSuggester.suggest(
            recipes: recipes,
            preferenceCounts: counts,
            recentCookCounts: ["a": 3],   // 1 - 3*4 = -11
            excludedRecipeIds: [],
            limit: 5
        )

        #expect(result.isEmpty)
    }
}

// MARK: - 旬の食材テーブル

struct SeasonalIngredientsTests {

    @Test("指定した月の旬食材を返す")
    func returnsIngredientsForMonth() {
        #expect(SeasonalIngredients.forMonth(7).contains("なす"))
        #expect(SeasonalIngredients.forMonth(1).contains("大根"))
    }

    @Test("範囲外の月は空を返す")
    func returnsEmptyForInvalidMonth() {
        #expect(SeasonalIngredients.forMonth(0).isEmpty)
        #expect(SeasonalIngredients.forMonth(13).isEmpty)
    }

    @Test("current は指定日の月の旬食材を正規化して返す")
    func currentNormalizesForGivenDate() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 15
        let calendar = Calendar(identifier: .gregorian)
        let july = calendar.date(from: components)!

        let result = SeasonalIngredients.current(now: july, calendar: calendar)
        #expect(result.contains("なす"))
    }
}
